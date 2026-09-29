import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers

/// 화면 없이 가짜 창 배치로 시뮬레이션을 돌리고 실제 셰이더로 PNG를 렌더링한다.
/// 모양을 눈으로 확인하며 다듬기 위한 개발용 도구.
///   RAINPANE_SNAPSHOT=/tmp/shots build/Rainpane.app/Contents/MacOS/Rainpane
/// 선택: RAINPANE_SNAPSHOT_TIMES="4,10,16" (초),
///       RAINPANE_SNAPSHOT_LIGHT=1 (밝은 배경), RAINPANE_SNAPSHOT_CLOSE=12 (그 시각에 앞 창을 닫아 수막 확인),
///       RAINPANE_SNAPSHOT_STRIP=1 (각 촬영 시각에서 연속 6프레임을 크롭해 가로로 이어 붙임: 깜빡임 확인용)
///       RAINPANE_SNAPSHOT_PRESS="x,y,누름,뗌[,dx,dy[,끌기시간]]" (마우스 누르기 재현: 그 자리를 누르고(끌고) 뗀다.
///         일반 촬영 대신 누르기 전후를 _PRESS_STEP(기본 0.1)초 간격으로 크롭해 격자로 저장.
///         _PRESS_END=1이면 끌기가 끝난 자리만 크롭, _PRESS_WINDOW="시작,끝"이면 그 구간만)
enum SnapshotHarness {
    static let screen = CGRect(x: 0, y: 0, width: 900, height: 820)
    static let scale: CGFloat = 2
    // 뒤에서 앞 순서가 아닌, 앞(0)부터
    static let windows: [TrackedWindow] = [
        TrackedWindow(id: 1, pid: 1, frame: CGRect(x: 90, y: 150, width: 400, height: 250), rank: 0),
        TrackedWindow(id: 2, pid: 1, frame: CGRect(x: 420, y: 80, width: 380, height: 300), rank: 1),
        TrackedWindow(id: 3, pid: 1, frame: CGRect(x: 40, y: 690, width: 800, height: 90), rank: 2),
    ]
    /// RAINPANE_SNAPSHOT_WIDGET=1이면 바탕화면 위젯도 하나 (창보다 모서리가 둥글고 작다)
    static let widget = TrackedWindow(id: 4, pid: 2, frame: CGRect(x: 560, y: 450, width: 170, height: 170), rank: 3, kind: .widget)

    static func run(outputDir: String) -> Never {
        guard let gpu = GPU.shared else { print("GPU init failed"); exit(1) }
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        var s = RainSettings.load()
        let env = ProcessInfo.processInfo.environment
        if let v = env["RAINPANE_SNAPSHOT_INTENSITY"].flatMap(Double.init) { s.intensity = v }   // 물줄기를 빨리 보고 싶을 때
        if env["RAINPANE_SNAPSHOT_NO_DROPLETS"] != nil { s.windowDroplets = false }   // 창 유리 물방울 없이 (비교용)
        let times = (env["RAINPANE_SNAPSHOT_TIMES"] ?? "4,10,16").split(separator: ",").compactMap { Double($0) }

        WaterSimulation.seedOverride = env["RAINPANE_SNAPSHOT_SEED"].flatMap(UInt64.init)
        let sim = WaterSimulation()
        sim.screens = [screen]
        let renderer = ScreenRenderer(gpu: gpu, layer: CAMetalLayer(), quartzFrame: screen)
        renderer.configure(quartzFrame: screen, backingScale: scale, renderScale: 1)
        let pw = Int(screen.width * scale), ph = Int(screen.height * scale)

        let scene = env["RAINPANE_SNAPSHOT_WIDGET"] != nil ? windows + [widget] : windows
        var bgImage = makeBackground(scene, width: pw, height: ph, settings: s)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = gpu.device.makeTexture(descriptor: td)!

        let dt = 1.0 / 60
        var t = 0.0
        var index = 0
        let closeAt = env["RAINPANE_SNAPSHOT_CLOSE"].flatMap(Double.init)
        let moveAt = env["RAINPANE_SNAPSHOT_MOVE"].flatMap(Double.init)   // 그 시각부터 0.15초 동안 앞 창을 빠르게 끌기
        let moveSpeed = env["RAINPANE_SNAPSHOT_MOVE_SPEED"].flatMap(Double.init) ?? 1500   // pt/s, 음수면 위로
        let strip = env["RAINPANE_SNAPSHOT_STRIP"] != nil
        let pressSpec = env["RAINPANE_SNAPSHOT_PRESS"]?.split(separator: ",").compactMap { Float($0) }
        let press = PressEffect()
        var pressDown = false
        // RAINPANE_SNAPSHOT_SCROLL="x,y,시작,끝,dx,dy": 그 구간 동안 프레임마다 (dx, dy)만큼 스크롤 (스크롤 먼지 확인)
        let scrollSpec = env["RAINPANE_SNAPSHOT_SCROLL"]?.split(separator: ",").compactMap { Float($0) }
        // RAINPANE_SNAPSHOT_POP="x,y,w,h,시각": 그 시각에 입력칸 모양 방울을 터뜨림 (Enter로 채팅 보냄)
        let popSpec = env["RAINPANE_SNAPSHOT_POP"]?.split(separator: ",").compactMap { Double($0) }
        var popped = false
        var current = scene
        var version = 1
        func step() {
            if let p = pressSpec, p.count >= 4 {
                let tf = Float(t)
                let drag = p.count >= 6 ? SIMD2(p[4], p[5]) : .zero
                let dragDur = p.count >= 7 ? p[6] : p[3] - p[2]
                let at = SIMD2(p[0], p[1]) + drag * min(1, max(0, (tf - p[2]) / max(dragDur, 0.01)))
                if !pressDown && tf >= p[2] && tf < p[3] { press.begin(at: at); pressDown = true }
                else if pressDown && tf >= p[3] { press.move(to: at); press.end(); pressDown = false }
                else if pressDown { press.move(to: at) }
            }
            if let q = scrollSpec, q.count >= 6, Float(t) >= q[2], Float(t) < q[3] {
                press.scroll(at: SIMD2(q[0], q[1]), delta: SIMD2(q[4], q[5]), now: t)
            }
            if let q = popSpec, q.count >= 5, !popped, t >= q[4] {
                press.pop(rect: CGRect(x: q[0], y: q[1], width: q[2], height: q[3]))
                popped = true
            }
            press.update(dt: Float(dt), settings: s)
            if let c = closeAt, t >= c, current.count == scene.count {
                // 앞 창을 닫는다: 나머지 창의 순위가 하나씩 당겨진다
                current = scene.dropFirst().enumerated().map { i, w in
                    TrackedWindow(id: w.id, pid: w.pid, frame: w.frame, rank: i, kind: w.kind)
                }
                version += 1
                bgImage = makeBackground(current, width: pw, height: ph, settings: s)
            }
            if let m = moveAt, t >= m, t < m + 0.15, !current.isEmpty {
                current[0].frame.origin.y += moveSpeed * dt
                version += 1
                bgImage = makeBackground(current, width: pw, height: ph, settings: s)
            }
            let now = 1000 + t
            sim.sync(windows: current, version: version, overview: false, now: now, dt: Float(dt))
            sim.update(dt: Float(dt), now: now, settings: s, windSpeed: Float(s.wind))
            t += dt
        }
        func render() -> CGImage {
            let u = RainController.uniforms(settings: s, time: t, wind: Float(s.wind))
            let snap = sim.snapshot
            let cb = gpu.queue.makeCommandBuffer()!
            renderer.encode(cb: cb, target: target, snapshot: snap, presses: press.data, pressGroups: press.groupCount,
                            pressShadowOnly: env["RAINPANE_SNAPSHOT_PRESS_SHADOW_ONLY"] != nil, base: u,
                            rainCount: RainController.rainCount(settings: s, screen: screen),
                            splashCount: RainController.splashCount(settings: s, snapshot: snap))
            cb.commit()
            cb.waitUntilCompleted()
            return composite(overlay: target, background: bgImage)
        }
        // RAINPANE_SNAPSHOT_SERIES="x,y,w,h,시작,끝,간격": 한 영역을 시간에 따라 격자로 (예: 물줄기가 모서리를 도는 모습)
        if let q = env["RAINPANE_SNAPSHOT_SERIES"]?.split(separator: ",").compactMap({ Double($0) }), q.count == 7 {
            let px = CGRect(x: q[0] * scale, y: q[1] * scale, width: q[2] * scale, height: q[3] * scale)
            var frames: [CGImage] = []
            var ft = q[4]
            while ft <= q[5] + 1e-6 {
                while t < ft { step() }
                if let c = render().cropping(to: px) { frames.append(c) }
                ft += q[6]
            }
            write(grid(frames, cols: 8), to: outputDir + "/series_grid.png")
            print("wrote \(outputDir)/series_grid.png (\(frames.count) frames)")
            exit(0)
        }
        if let p = pressSpec, p.count >= 4 {
            // 누르기 전후 연속 프레임 격자
            let stepT = env["RAINPANE_SNAPSHOT_PRESS_STEP"].flatMap(Double.init) ?? 0.1
            let drag = p.count >= 6 ? CGPoint(x: CGFloat(p[4]), y: CGFloat(p[5])) : .zero
            let half = CGFloat(s.pressMaxRadius) * 1.6 + 30
            var region = CGRect(x: CGFloat(p[0]) + min(0, drag.x) - half, y: CGFloat(p[1]) + min(0, drag.y) - half,
                                width: half * 2 + abs(drag.x), height: half * 2 + abs(drag.y))
            if env["RAINPANE_SNAPSHOT_PRESS_END"] != nil {
                // 끌기가 끝난 자리만 크롭 (멈춘 뒤 모양 변화 확인용)
                region = CGRect(x: CGFloat(p[0]) + drag.x - half, y: CGFloat(p[1]) + drag.y - half, width: half * 2, height: half * 2)
            }
            let px = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale)
            var frames: [CGImage] = []
            // _PRESS_WINDOW="시작,끝": 그 구간만 촬영
            let win = env["RAINPANE_SNAPSHOT_PRESS_WINDOW"]?.split(separator: ",").compactMap { Double($0) }
            var ft = win?.first ?? Double(p[2]) - stepT
            let endT = win.flatMap { $0.count > 1 ? $0[1] : nil } ?? Double(p[3]) + 1.3
            while ft <= endT + 1e-6 {
                while t < ft { step() }
                if let c = render().cropping(to: px) { frames.append(c) }
                ft += stepT
            }
            let name = outputDir + "/press"
            write(grid(frames, cols: 6), to: name + "_grid.png")
            print("wrote \(name)_grid.png (\(frames.count) frames, step \(stepT)s)")
            exit(0)
        }
        for shot in times.sorted() {
            while t < shot { step() }
            let out = render()
            let name = String(format: "%@/shot%d_t%02.0f", outputDir, index, shot)
            write(out, to: name + ".png")
            // 확대 크롭: 앞 창 왼쪽 위 모서리, 뒤 창 오른쪽 위 모서리, 앞 창 왼쪽 아래 모서리
            let a = windows[0].frame, b = windows[1].frame
            crop(out, CGRect(x: a.minX - 25, y: a.minY - 22, width: 80, height: 80), zoom: 4, to: name + "_A_topleft.png")
            crop(out, CGRect(x: b.maxX - 55, y: b.minY - 22, width: 80, height: 80), zoom: 4, to: name + "_B_topright.png")
            crop(out, CGRect(x: a.minX - 30, y: a.maxY - 50, width: 80, height: 110), zoom: 4, to: name + "_A_bottomleft.png")
            crop(out, CGRect(x: a.minX + 100, y: a.minY - 16, width: 120, height: 30), zoom: 5, to: name + "_A_top.png")
            if let c = env["RAINPANE_SNAPSHOT_CROP"]?.split(separator: ",").compactMap({ Double($0) }), c.count == 4 {
                crop(out, CGRect(x: c[0], y: c[1], width: c[2], height: c[3]), zoom: 3, to: name + "_crop.png")
            }
            if strip {
                // 연속 프레임: 옆 물줄기 중간, 아래 모서리 낙수
                var sideFrames: [CGImage] = [], dripFrames: [CGImage] = []
                for _ in 0..<6 {
                    step()
                    let f = render()
                    let r1 = CGRect(x: (b.maxX - 12) * scale, y: (b.minY + 120) * scale, width: 28 * scale, height: 90 * scale)
                    let r2 = CGRect(x: (a.minX + 10) * scale, y: (a.maxY - 10) * scale, width: 50 * scale, height: 300 * scale)
                    if let c = f.cropping(to: r1) { sideFrames.append(c) }
                    if let c = f.cropping(to: r2) { dripFrames.append(c) }
                }
                write(hstack(sideFrames, zoom: 3), to: name + "_strip_side.png")
                write(hstack(dripFrames, zoom: 2), to: name + "_strip_drip.png")
            }
            if env["RAINPANE_SNAPSHOT_POOLS"] != nil {
                for (id, p) in sim.pools.sorted(by: { $0.key < $1.key }) {
                    print(String(format: "  pool %d: width %.0f  평균 높이 %.2f  최대 %.2f", id, p.frame.width, p.averageHeight, p.h.max() ?? 0))
                }
            }
            print("wrote \(name)")
            index += 1
        }
        exit(0)
    }

    // MARK: 성능 측정 (RAINPANE_BENCH=1)

    /// 창이 많이 한꺼번에 움직일 때(미션 컨트롤 드나들기 등) 단계별 비용을 잰다. 화면 없이 실제 코드로.
    static func bench() -> Never {
        guard let gpu = GPU.shared else { print("GPU init failed"); exit(1) }
        func ms(_ block: () -> Void) -> Double {
            let t0 = CACurrentMediaTime(); block(); return (CACurrentMediaTime() - t0) * 1000
        }
        // 1) 실제 창 목록 읽기
        var count = 0
        let fetch = ms { for _ in 0..<200 { count = WindowTracker.fetch(excluding: 0).windows.count } } / 200
        print(String(format: "fetch: %.3f ms (창 %d개)", fetch, count))

        // 2) 가짜 창 40개가 매 프레임 움직이고 크기가 바뀜
        let scr = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var s = RainSettings.load()
        s.intensity = max(s.intensity, 0.3)
        // 매번 같은 장면으로 (전후 비교가 되게)
        WaterSimulation.seedOverride = 42
        let sim = WaterSimulation()
        sim.screens = [scr]
        let renderer = ScreenRenderer(gpu: gpu, layer: CAMetalLayer(), quartzFrame: scr)
        renderer.configure(quartzFrame: scr, backingScale: 2, renderScale: 1)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 3024, height: 1964, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let target = gpu.device.makeTexture(descriptor: td)!
        var rng = FastRandom(seed: 1)
        let base: [CGRect] = (0..<40).map { _ in
            CGRect(x: CGFloat(rng.range(0, 900)), y: CGFloat(rng.range(30, 500)),
                   width: CGFloat(rng.range(400, 1000)), height: CGFloat(rng.range(300, 700)))
        }
        var version = 1
        var t = 1000.0
        let dt: Float = 1.0 / 60
        func windows(_ k: Double) -> [TrackedWindow] {
            base.enumerated().map { i, r in
                // 가운데로 모였다 퍼지는 미션 컨트롤 비슷한 움직임 (크기도 바뀜)
                let sc = 1 - 0.45 * k
                let f = CGRect(x: r.midX * (1 - k) + (Double(i % 8) * 180 + 60) * k - r.width * sc / 2,
                               y: r.midY * (1 - k) + (Double(i / 8) * 180 + 100) * k - r.height * sc / 2,
                               width: r.width * sc, height: r.height * sc)
                return TrackedWindow(id: CGWindowID(i + 1), pid: 1, frame: f, rank: i)
            }
        }
        var tSync = 0.0, tUpdate = 0.0, tEncode = 0.0, tGPU = 0.0
        func frame(_ ws: [TrackedWindow], measure: Bool) {
            version += 1
            let a = ms { sim.sync(windows: ws, version: version, overview: false, now: t, dt: dt) }
            let b = ms { sim.update(dt: dt, now: t, settings: s, windSpeed: Float(s.wind)) }
            let u = RainController.uniforms(settings: s, time: t, wind: Float(s.wind))
            let snap = sim.snapshot
            let cb = gpu.queue.makeCommandBuffer()!
            let c = ms {
                renderer.encode(cb: cb, target: target, snapshot: snap, presses: [], base: u,
                                rainCount: RainController.rainCount(settings: s, screen: scr),
                                splashCount: RainController.splashCount(settings: s, snapshot: snap))
            }
            cb.commit(); cb.waitUntilCompleted()
            if measure { tSync += a; tUpdate += b; tEncode += c; tGPU += (cb.gpuEndTime - cb.gpuStartTime) * 1000 }
            t += Double(dt)
        }
        // 물이 고이도록 가만히 5초
        let still = windows(0)
        for _ in 0..<300 { frame(still, measure: false) }
        // 움직임 120프레임
        for k in 0..<120 { frame(windows(Double(k % 60) / 60), measure: true) }
        print(String(format: "moving 40 windows: sync %.3f  update %.3f  encode %.3f  (CPU ms/frame)  gpu %.3f ms",
                     tSync / 120, tUpdate / 120, tEncode / 120, tGPU / 120))
        // 3) 가만히
        tSync = 0; tUpdate = 0; tEncode = 0; tGPU = 0
        for _ in 0..<120 { frame(still, measure: true) }
        print(String(format: "still 40 windows:  sync %.3f  update %.3f  encode %.3f  (CPU ms/frame)  gpu %.3f ms",
                     tSync / 120, tUpdate / 120, tEncode / 120, tGPU / 120))
        // 3-1) GPU 성분별: 비만 / 물만 / 튀김만
        func gpuOnly(rain: Bool, water: Bool, splash: Bool) -> Double {
            var total = 0.0
            for _ in 0..<60 {
                let u = RainController.uniforms(settings: s, time: t, wind: Float(s.wind))
                var snap = sim.snapshot
                if !water { snap.pools = []; snap.rivulets = []; snap.drops = []; snap.curtains = [] }
                let cb = gpu.queue.makeCommandBuffer()!
                renderer.encode(cb: cb, target: target, snapshot: snap, presses: [], base: u,
                                rainCount: rain ? RainController.rainCount(settings: s, screen: scr) : 0,
                                splashCount: splash ? RainController.splashCount(settings: s, snapshot: snap) : 0)
                cb.commit(); cb.waitUntilCompleted()
                total += (cb.gpuEndTime - cb.gpuStartTime) * 1000
            }
            return total / 60
        }
        print(String(format: "gpu parts (still): rain %.3f  water %.3f  splash %.3f  none %.3f  (rainCount %d, splashCount %d)",
                     gpuOnly(rain: true, water: false, splash: false), gpuOnly(rain: false, water: true, splash: false),
                     gpuOnly(rain: false, water: false, splash: true), gpuOnly(rain: false, water: false, splash: false),
                     RainController.rainCount(settings: s, screen: scr), RainController.splashCount(settings: s, snapshot: sim.snapshot)))
        // 4) 한꺼번에 닫힘 (미션 컨트롤 들어갈 때처럼) → 수막 폭주
        version += 1
        sim.sync(windows: [], version: version, overview: true, now: t, dt: dt)
        tSync = 0; tUpdate = 0; tEncode = 0; tGPU = 0
        for _ in 0..<90 { frame([], measure: true) }
        print(String(format: "all closed (curtains): update %.3f  encode %.3f  (CPU ms/frame)  gpu %.3f ms  curtains %d",
                     tUpdate / 90, tEncode / 90, tGPU / 90, sim.snapshot.curtains.count / 3))
        exit(0)
    }

    /// 프레임을 cols개씩 줄지어 격자로 (원래 pt 크기, 사이 간격은 자홍색)
    static func grid(_ images: [CGImage], cols: Int) -> CGImage {
        let w = images.first?.width ?? 1, h = images.first?.height ?? 1
        let gap = 6
        let rows = (images.count + cols - 1) / cols
        let zw = w * cols + gap * (cols - 1), zh = h * rows + gap * (rows - 1)
        let ctx = CGContext(data: nil, width: zw, height: zh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: zw, height: zh))
        for (i, img) in images.enumerated() {
            let x = (i % cols) * (w + gap), y = zh - h - (i / cols) * (h + gap)
            ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
        }
        return ctx.makeImage()!
    }

    static func hstack(_ images: [CGImage], zoom: Int) -> CGImage {
        let w = images.first?.width ?? 1, h = images.first?.height ?? 1
        let gap = 4
        let zw = (w * images.count + gap * (images.count - 1)) * zoom / Int(scale), zh = h * zoom / Int(scale)
        let ctx = CGContext(data: nil, width: zw, height: zh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: zw, height: zh))
        ctx.interpolationQuality = .none
        for (i, img) in images.enumerated() {
            let x = (i * (w + gap)) * zoom / Int(scale)
            ctx.draw(img, in: CGRect(x: x, y: 0, width: w * zoom / Int(scale), height: zh))
        }
        return ctx.makeImage()!
    }

    // MARK: 배경 (가짜 바탕화면과 창)

    static func makeBackground(_ windows: [TrackedWindow], width: Int, height: Int, settings s: RainSettings) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Quartz 좌표(y 아래)로 그리기 위해 뒤집는다
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let light = ProcessInfo.processInfo.environment["RAINPANE_SNAPSHOT_LIGHT"] != nil
        let grad = light
            ? CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1),
                                                   CGColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1)] as CFArray, locations: [0, 1])!
            : CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.27, blue: 0.38, alpha: 1),
                                                   CGColor(red: 0.42, green: 0.36, blue: 0.45, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: screen.height), options: [])
        for w in windows.reversed() {
            let r = CGFloat(w.isWidget ? s.widgetCornerRadius : s.cornerRadius)
            let path = CGPath(roundedRect: w.frame, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: CGColor(gray: 0, alpha: 0.45))
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: w.rank == 0 ? 0.96 : 0.9, alpha: 1)); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            // 제목 표시줄과 본문 줄무늬
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1)); ctx.fill(CGRect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: 28))
            ctx.setFillColor(CGColor(red: 0.3, green: 0.45, blue: 0.8, alpha: 0.6))
            var y = w.frame.minY + 44
            while y < w.frame.maxY - 10 { ctx.fill(CGRect(x: w.frame.minX + 16, y: y, width: w.frame.width * 0.6, height: 6)); y += 16 }
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    /// 프리멀티플라이드 오버레이를 배경 위에 합성
    static func composite(overlay: MTLTexture, background: CGImage) -> CGImage {
        let w = overlay.width, h = overlay.height
        var over = [UInt8](repeating: 0, count: w * h * 4)
        overlay.getBytes(&over, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let bgData = background.dataProvider!.data! as Data
        let bpr = background.bytesPerRow
        var out = [UInt8](repeating: 255, count: w * h * 4)
        bgData.withUnsafeBytes { (bg: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4, b = y * bpr + x * 4
                    let a = Int(over[o + 3])
                    for c in 0..<3 { out[o + c] = UInt8(min(255, Int(over[o + c]) + Int(bg[b + c]) * (255 - a) / 255)) }
                    out[o + 3] = 255
                }
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(out) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func crop(_ image: CGImage, _ rectPt: CGRect, zoom: Int, to path: String) {
        let r = CGRect(x: rectPt.minX * scale, y: rectPt.minY * scale, width: rectPt.width * scale, height: rectPt.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let c = image.cropping(to: r) else { return }
        let zw = c.width * zoom / Int(scale), zh = c.height * zoom / Int(scale)
        let ctx = CGContext(data: nil, width: zw, height: zh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: zw, height: zh))
        write(ctx.makeImage()!, to: path)
    }

    static func write(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
