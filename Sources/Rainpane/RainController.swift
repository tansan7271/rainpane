import AppKit
import IOKit.ps
import QuartzCore
import ServiceManagement
import simd

/// 클릭이 통과하는 투명 전체 화면 창
final class OverlayWindow: NSWindow {
    /// 기본 레벨은 일반 창들 바로 위. 떠 있는 패널·Dock·알림·메뉴는 이 위에 있어서 자연히 비와 물을 가린다.
    /// (Dock·알림 배너에 물을 올리려고 오버레이를 그 위로 올려 봤지만, 손쉬운 사용 권한이 필요하고
    ///  Dock 모양을 정확히 따라가기 어려워 되돌렸다)
    init(frame: NSRect, level: NSWindow.Level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MetalHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

/// 오버레이 창, 창 추적, 시뮬레이션, 렌더 루프를 묶는 중심 객체
final class RainController {
    private let store: SettingsStore
    private let stats: RuntimeStats
    private let tracker = WindowTracker()
    private let sim = WaterSimulation()
    private let press = PressEffect()
    private let keyboard = KeyboardFocus()

    private struct Overlay {
        let window: OverlayWindow
        let view: MetalHostView
        let renderer: ScreenRenderer
        let press: PressOverlay       // 누른 물방울 전용 맨 앞 창
        let screen: NSScreen
        var quartz: CGRect
    }
    private var overlays: [Overlay] = []
    private var displayLink: CADisplayLink?
    private var idleTimer: Timer?
    private let startTime = CACurrentMediaTime()
    private var lastTick: CFTimeInterval = 0
    private var quietFrames = 0
    private var idle = false
    private var running = false
    private var screensAsleep = false

    private var onBattery = false
    private var motionBoost = false
    private var boostUntil: CFTimeInterval = 0
    private var appliedFPS = 0
    private var lastPowerCheck: CFTimeInterval = 0
    private var frameCount = 0
    private var frameTimeAcc: Double = 0
    private var lastStats: CFTimeInterval = 0
    private var lastCPUTime: Double = 0

    /// 이 프로세스가 지금까지 쓴 CPU 시간 (초, 모든 스레드)
    private static func processCPUTime() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    }

    init(store: SettingsStore, stats: RuntimeStats) {
        self.store = store
        self.stats = stats
        store.onChange = { [weak self] new, old in self?.settingsChanged(new, old) }
        press.onActivity = { [weak self] in self?.wake() }
        keyboard.onPoint = { [weak self] p in
            self?.press.tap(at: p)
            self?.wake()
        }
        keyboard.onPop = { [weak self] rect in
            self?.press.pop(rect: rect)
            self?.wake()
        }
        keyboard.onStatus = { [weak self] msg in self?.store.statusMessage = msg }
        press.suppress = { [weak self] in
            guard let self else { return false }
            let hideRec = self.store.settings.hideWhileRecording
            if self.store.settings.rainEnabled { return self.tracker.capturing || (hideRec && self.tracker.recording) }
            // 비를 끈 동안엔 창 목록을 읽지 않으므로 누를 때 한 번 확인한다
            let f = WindowTracker.fetch(excluding: getpid())
            return f.capturing || (hideRec && f.recording)
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlays()
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sim.lastSpaceChange = CACurrentMediaTime()
            self?.wake()
        }
        // 가리기(⌘H): 그 앱 창이 한꺼번에 사라져도 Space 전환이 아니라 닫힘처럼 수막을 흘린다
        wnc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.sim.appHidden(pid: app.processIdentifier, now: CACurrentMediaTime())
            self?.wake()
        }
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.displayLink?.isPaused = true
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.lastTick = 0
            self?.wake()
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateFrameRate()
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateFrameRate()
        }

        if store.settings.enabled { start() }
    }

    // MARK: 시작/정지

    func start() {
        guard !running else { return }
        guard GPU.shared != nil else {
            store.statusMessage = L("Metal 초기화 실패", "Could not initialize Metal")
            return
        }
        running = true
        // 켜 둔 로그인 항목이 등록돼 있지 않으면 (앱을 옮기거나 이름을 바꾼 뒤) 다시 등록한다
        if store.settings.launchAtLogin && SMAppService.mainApp.status != .enabled { updateLoginItem(true) }
        if store.settings.pressEffect { press.startMonitoring() }
        updateKeyboard()
        rebuildOverlays()
    }

    func stop() {
        running = false
        displayLink?.invalidate(); displayLink = nil
        idleTimer?.invalidate(); idleTimer = nil
        for o in overlays { o.window.orderOut(nil); o.press.close() }
        overlays.removeAll()
        sim.clearAll()
        press.stopMonitoring()
        keyboard.stop()
    }

    private func updateKeyboard() {
        let s = store.settings
        if running && s.pressEffect && s.keyboardPress { keyboard.start() } else { keyboard.stop(); store.statusMessage = nil }
    }

    private func rebuildOverlays() {
        guard running, let gpu = GPU.shared else { return }
        displayLink?.invalidate(); displayLink = nil
        for o in overlays { o.window.orderOut(nil); o.press.close() }
        overlays.removeAll()
        overlaysLowered = false

        let screens = NSScreen.screens
        guard let mainHeight = screens.first?.frame.height else { return }
        for screen in screens {
            let f = screen.frame
            let quartz = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
            let window = OverlayWindow(frame: f)
            let view = MetalHostView(frame: NSRect(origin: .zero, size: f.size))
            window.contentView = view
            window.setFrame(f, display: false)
            let renderer = ScreenRenderer(gpu: gpu, layer: view.metalLayer, quartzFrame: quartz)
            renderer.configure(quartzFrame: quartz, backingScale: screen.backingScaleFactor,
                               renderScale: CGFloat(store.settings.renderScale))
            renderer.screenIndex = overlays.count
            window.orderFrontRegardless()
            let press = PressOverlay(frame: f, quartz: quartz, backingScale: screen.backingScaleFactor, gpu: gpu)
            overlays.append(Overlay(window: window, view: view, renderer: renderer, press: press, screen: screen, quartz: quartz))
        }
        sim.screens = overlays.map(\.quartz)

        if let first = overlays.first {
            let link = first.view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            updateFrameRate()
        }
        tracker.pollIfNeeded(now: CACurrentMediaTime(), force: true)
        lastTick = 0
        wake()
    }

    // MARK: 설정 반영

    private func settingsChanged(_ new: RainSettings, _ old: RainSettings) {
        if new.enabled != old.enabled { new.enabled ? start() : stop() }
        guard running else { return }
        if new.renderScale != old.renderScale {
            for o in overlays {
                o.renderer.configure(quartzFrame: o.quartz, backingScale: o.screen.backingScaleFactor, renderScale: CGFloat(new.renderScale))
            }
        }
        if new.pressEffect != old.pressEffect { new.pressEffect ? press.startMonitoring() : press.stopMonitoring() }
        if new.pressEffect != old.pressEffect || new.keyboardPress != old.keyboardPress { updateKeyboard() }
        if new.maxFPS != old.maxFPS || new.batterySaver != old.batterySaver || new.adaptiveFPS != old.adaptiveFPS {
            appliedFPS = 0; updateFrameRate()
        }
        if new.launchAtLogin != old.launchAtLogin { updateLoginItem(new.launchAtLogin) }
        if !new.pooling && old.pooling { sim.clearAll(); tracker.pollIfNeeded(now: CACurrentMediaTime(), force: true) }
        if new.rainEnabled != old.rainEnabled {
            sim.clearAll()
            if new.rainEnabled { tracker.pollIfNeeded(now: CACurrentMediaTime(), force: true) }
        }
        wake()
    }

    private func updateLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.statusMessage = L("로그인 항목 설정 실패: ", "Could not update the login item: ") + error.localizedDescription
        }
    }

    /// 투명 전체 화면 레이어는 내용과 무관하게 "갱신 횟수"만큼 WindowServer 합성 비용이 든다.
    /// 그래서 평소엔 30fps, 창이 움직이거나 수막·공중 물처럼 빠른 움직임이 있을 때만 최대 FPS로 올린다.
    private func targetFPS() -> Int {
        let s = store.settings
        var fps = s.maxFPS
        if s.adaptiveFPS && !motionBoost { fps = min(fps, 30) }
        // 배터리·저전력 모드·발열 스로틀 중에만 30fps로 낮춘다
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if s.batterySaver && (onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled || hot) {
            fps = min(fps, 30)
        }
        return fps
    }

    private func updateFrameRate() {
        let fps = targetFPS()
        guard fps != appliedFPS || displayLink?.preferredFrameRateRange.preferred == nil else { return }
        appliedFPS = fps
        let f = Float(fps)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(f, 24), maximum: f, preferred: f)
    }

    private func checkPower(_ now: CFTimeInterval) {
        guard now - lastPowerCheck > 10 else { return }
        lastPowerCheck = now
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let battery = type == kIOPSBatteryPowerValue
        if battery != onBattery { onBattery = battery; updateFrameRate() }
    }

    // MARK: 유휴 관리

    /// 비가 멈추고 물도 잠잠하면 렌더 루프를 멈추고, 창 변화만 저주기로 감시한다.
    private func enterIdle() {
        guard !idle else { return }
        idle = true
        displayLink?.isPaused = true
        stats.paused = true
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 비를 끈 동안에는 창 변화로 깨어날 필요가 없다 (마우스 물방울은 이벤트로 깨운다)
            if self.store.settings.rainEnabled && self.tracker.pollIfNeeded(now: CACurrentMediaTime(), force: true) { self.wake() }
        }
    }

    func wake() {
        guard running, !screensAsleep else { return }
        quietFrames = 0
        if idle {
            idle = false
            idleTimer?.invalidate(); idleTimer = nil
            stats.paused = false
            lastTick = 0
        }
        displayLink?.isPaused = false
    }

    // MARK: 프레임

    /// 비를 끈 동안과 스크린샷 도구로 영역·창을 고르는 동안: 비 창을 일반 창들 아래로 내리고 아무것도 그리지 않는다.
    /// 투명한 비 창이 맨 위에 있으면 스크린샷 "창 선택"이 앱 창 대신 비 창을 골랐다.
    /// 창을 숨기지(orderOut) 않고 내리기만 해야 이 창에 붙은 디스플레이 링크가 계속 돈다
    private var overlaysLowered = false
    private func setOverlaysLowered(_ low: Bool) {
        overlaysLowered = low
        let level = low ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                        : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
        for o in overlays { o.window.level = level }
    }

    /// 리퀴드 글래스로 그릴 누른 물방울 (그 화면에 걸친 것만, 화면 로컬 좌표로)
    private func glassItems(for o: Overlay) -> [GlassPressModel.Item] {
        var items: [GlassPressModel.Item] = []
        for b in press.blobs where b.r > 2 {
            let e = CGFloat(simd_length(b.stretch))
            let r = CGFloat(b.r)
            let a = r * (1 + e)
            let c = CGPoint(x: CGFloat(b.pos.x) - o.quartz.minX, y: CGFloat(b.pos.y) - o.quartz.minY)
            guard CGRect(origin: .zero, size: o.quartz.size).insetBy(dx: -a, dy: -a).contains(c) else { continue }
            items.append(.init(id: b.id, center: c, a: a, b: r / (1 + e), angle: CGFloat(atan2(b.stretch.y, b.stretch.x) / 2)))
        }
        // 잔 물방울: 같은 유리 컨테이너 안이라 본 방울에 가까우면 액체처럼 이어졌다가 멀어지며 끊긴다
        for m in press.satellites where m.r > 1 {
            let r = CGFloat(m.r)
            let c = CGPoint(x: CGFloat(m.pos.x) - o.quartz.minX, y: CGFloat(m.pos.y) - o.quartz.minY)
            guard CGRect(origin: .zero, size: o.quartz.size).insetBy(dx: -r, dy: -r).contains(c) else { continue }
            items.append(.init(id: m.id, center: c, a: r, b: r, angle: 0))
        }
        return items
    }

    /// 개발용 셰이딩 디버그 모드 (RAINPANE_DEBUG_SHADE). 환경 변수 읽기는 매 프레임 하기엔 비싸서(샘플링하면 메인 스레드의 7%) 한 번만
    private static let debugShade = Float(ProcessInfo.processInfo.environment["RAINPANE_DEBUG_SHADE"] ?? "") ?? 0
    private static let debugLog = ProcessInfo.processInfo.environment["RAINPANE_DEBUG"] != nil

    static func uniforms(settings s: RainSettings, time t: Double, wind: Float) -> Uniforms {
        var u = Uniforms()
        u.timeInfo = SIMD4(Float(fmod(t, 3600)), 2, Float(s.cornerRadius), Float(s.poolCapacity))
        u.rain = SIMD4(Float(s.intensity), wind, Float(s.fallSpeed), Float(s.streakLength))
        u.rain2 = SIMD4(Float(s.streakWidth), Float(s.rainOpacity), Float(s.depthStep), Float(s.depthOfField))
        u.rainColor = SIMD4(Float(s.rainR), Float(s.rainG), Float(s.rainB), Float(s.desktopRain))
        let a = s.lightAngle * .pi / 180
        u.light = SIMD4(Float(sin(a)), Float(-cos(a)), Float(s.specular), Float(s.rimDarkness))
        // water.w: 개발용 셰이딩 디버그 모드 (기본 0)
        u.water = SIMD4(0, 0, Float(s.waterTint), debugShade)
        u.counts.w = WaterSimulation.cornerExponent(s)
        return u
    }

    static func splashCount(settings s: RainSettings, snapshot: SimSnapshot) -> Int {
        s.splashes ? min(5000, Int(s.splashAmount * (0.15 + s.intensity) * Double(snapshot.edgeLength) / 9)) : 0
    }

    static func rainCount(settings s: RainSettings, screen: CGRect) -> Int {
        let area = Double(screen.width * screen.height) / (1512.0 * 982.0)
        return s.intensity > 0.001 ? Int(4200 * pow(s.intensity, 1.2) * area) : 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        let now = t0
        let dt = Float(lastTick == 0 ? 1.0 / 60 : min(0.1, now - lastTick))
        lastTick = now
        let s = store.settings
        checkPower(now)

        // 비를 끄면 창 추적과 물 시뮬레이션을 통째로 쉬고 마우스 물방울만 그린다
        let rainOn = s.rainEnabled
        if rainOn { tracker.pollIfNeeded(now: now) }
        let lowered = !rainOn || tracker.capturing || (s.hideWhileRecording && tracker.recording)
        if lowered != overlaysLowered { setOverlaysLowered(lowered) }
        if (rainOn && (tracker.isHot(now) || sim.needsSmoothMotion)) || press.isActive { boostUntil = now + 0.5 }
        let boost = now < boostUntil
        if boost != motionBoost { motionBoost = boost; updateFrameRate() }
        let t = now - startTime
        let gust = sin(t * 0.37) * 0.5 + sin(t * 0.91 + 1.3) * 0.3 + sin(t * 2.3 + 0.7) * 0.2
        let wind = Float(s.wind + s.gustiness * 0.12 * gust)
        if rainOn {
            sim.sync(windows: tracker.windows, version: tracker.version, overview: tracker.overview, now: now, dt: dt)
            sim.update(dt: dt, now: now, settings: s, windSpeed: wind)
        }
        press.update(dt: dt, settings: s)

        let u = Self.uniforms(settings: s, time: t, wind: wind)
        let snapshot = sim.snapshot
        let glassOn = s.pressGlass && GlassPress.available
        let glassTuning = GlassTuning(refraction: CGFloat(s.pressGlassRefraction), blur: CGFloat(s.pressGlassBlur),
                                      spacing: 20 * CGFloat(s.pressNeck),
                                      lightBG: CGFloat(s.pressGlassLightBG), darkBG: CGFloat(s.pressGlassDarkBG))
        for o in overlays {
            o.press.update(presses: press.data, groups: press.groupCount,
                           glassItems: glassOn ? glassItems(for: o) : [], glass: glassOn, glassTuning: glassTuning, base: u)
        }
        let intensity = s.intensity
        let splashTotal = Self.splashCount(settings: s, snapshot: snapshot)
        for o in overlays {
            if lowered || (s.pauseWhenCovered && sim.screenIsCovered(o.quartz)) {
                o.renderer.clearOnce()
                continue
            }
            let rainCount = Self.rainCount(settings: s, screen: o.quartz)
            o.renderer.draw(snapshot: snapshot, presses: [], base: u, rainCount: rainCount, splashCount: splashTotal)
        }

        // 유휴 판정
        if (!rainOn || (intensity < 0.005 && !sim.isActive)) && !press.isActive {
            quietFrames += 1
            if quietFrames > 20 { enterIdle() }
        } else {
            quietFrames = 0
        }

        // 통계
        frameCount += 1
        frameTimeAcc += CACurrentMediaTime() - t0
        if now - lastStats >= 1 {
            let elapsed = now - lastStats
            stats.fps = Double(frameCount) / elapsed
            stats.frameMs = frameTimeAcc / Double(max(frameCount, 1)) * 1000
            let cpu = Self.processCPUTime()
            if lastCPUTime > 0 { stats.cpuPercent = (cpu - lastCPUTime) / elapsed * 100 }
            lastCPUTime = cpu
            stats.windows = tracker.windows.count
            stats.gpuMs = GPUTiming.drain()
            if Self.debugLog {
                NSLog("fps %.1f cpu %.0f%% tick %.3fms gpu %.3fms windows %d (widgets %d) polls %d", stats.fps, stats.cpuPercent, stats.frameMs, stats.gpuMs, stats.windows,
                      tracker.windows.filter(\.isWidget).count, tracker.pollCount)
            }
            tracker.pollCount = 0
            frameCount = 0; frameTimeAcc = 0; lastStats = now
        }
    }
}
