import AppKit
import CoreGraphics

/// 물이 고이는 표면 하나(일반 창 또는 바탕화면 위젯). 좌표는 전역 Quartz 좌표(주 화면 좌상단 원점, y 아래 방향, pt).
struct TrackedWindow: Equatable {
    enum Kind: Equatable {
        case normal     // 일반 앱 창 (레이어 0)
        case widget     // 바탕화면 위젯
    }

    let id: CGWindowID
    let pid: pid_t
    var frame: CGRect
    var rank: Int          // 0 = 맨 앞
    var alpha: Float = 1   // 닫기 애니메이션은 투명도가 1 → 0으로 빠지는 것으로 알아챈다
    var kind: Kind = .normal

    var isWidget: Bool { kind == .widget }
}

/// CGWindowList를 적응형 주기로 폴링한다.
/// 창이 움직이는 동안은 매 프레임, 조용할 때는 느리게 폴링해 CPU를 아낀다.
final class WindowTracker {
    private(set) var windows: [TrackedWindow] = []
    private(set) var version = 0
    /// 미션 컨트롤·데스크톱 보기 중이면 true. 이때는 창이 하나도 없는 것으로 취급한다.
    private(set) var overview = false
    /// 스크린샷 도구가 화면 크기 선택 창을 띄운 중 (⌘⇧4·⌘⇧5 영역·창 고르기). 이 동안 비 창을 숨겨야
    /// "창 선택"이 비 창 대신 그 아래 앱 창을 고르고, 누른 물방울도 찍히지 않는다
    private(set) var capturing = false
    /// 화면을 녹화하는 중: 시스템이 모니터마다 오른쪽 위 구석에 작은 녹화 표시 창을 띄운다
    private(set) var recording = false
    var pollCount = 0

    private var lastPoll: CFTimeInterval = 0
    private var hotUntil: CFTimeInterval = 0
    private let myPid = ProcessInfo.processInfo.processIdentifier

    /// 필요하면 폴링한다. 창 목록이 바뀌면 true.
    @discardableResult
    func pollIfNeeded(now: CFTimeInterval, force: Bool = false) -> Bool {
        let hot = now < hotUntil
        let interval: CFTimeInterval = hot ? 0 : 1.0 / 12.0
        guard force || now - lastPoll >= interval else { return false }
        lastPoll = now
        pollCount &+= 1

        let f = Self.fetch(excluding: myPid)
        let fresh = f.overview ? [] : f.windows
        guard fresh != windows || f.overview != overview || f.capturing != capturing || f.recording != recording else { return false }
        overview = f.overview
        capturing = f.capturing
        recording = f.recording
        windows = fresh
        version &+= 1
        hotUntil = now + 0.6
        return true
    }

    /// 최근에 창이 움직였는지 (매 프레임 폴링 중)
    func isHot(_ now: CFTimeInterval) -> Bool { now < hotUntil }

    /// 위젯 창의 투명 여백 (보이는 위젯은 창보다 사방으로 이만큼 작다)
    static let widgetInset: CGFloat = 10

    private static let screenshotOwner = "screencapture" as CFString
    private static let windowServer = "Window Server" as CFString

    static func fetch(excluding pid: pid_t) -> (windows: [TrackedWindow], overview: Bool, capturing: Bool, recording: Bool) {
        // 바탕화면 위젯까지 받으려고 excludeDesktopElements는 쓰지 않고 아래에서 직접 거른다.
        // 창이 움직이는 동안 매 프레임 부르므로, 목록 전체(메뉴바·Dock 등 시스템 창 포함)를 Swift 사전으로 바꾸지 않고
        // CF 값에서 필요한 것만 바로 읽는다
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) else { return ([], false, false, false) }
        var result: [TrackedWindow] = []
        result.reserveCapacity(24)
        var overview = false
        var capturing = false
        var recording = false
        var corners: [CGPoint]?   // 모니터 오른쪽 위 구석 (녹화 표시 창을 볼 때만 구한다)
        for i in 0..<CFArrayGetCount(raw) {
            let info = unsafeBitCast(CFArrayGetValueAtIndex(raw, i), to: CFDictionary.self)
            let layer = Int(cfNumber(info, kCGWindowLayer) ?? -1)
            if layer != 0, let o = cfValue(info, kCGWindowOwnerName) {
                let owner = unsafeBitCast(o, to: CFString.self)
                // 스크린샷 도구의 선택 창 (찍은 뒤 모서리에 뜨는 작은 미리보기·도구 막대는 크기로 거른다)
                // 스크린샷 도구가 영역·창을 고르는 동안 띄우는 선택 화면(⌘⇧4·⌘⇧5 모두 screencapture, 레이어 1498).
                // ⌘⇧5 도구 막대 쪽 창(Screenshot, 레이어 24)과 녹화용 창(screencapture, 레이어 1000)은 녹화 내내,
                // 끝난 뒤에도 몇 초 떠 있어서 보지 않는다(보면 녹화 중에 비가 숨고 늦게 돌아왔다)
                if CFEqual(owner, screenshotOwner) {
                    if layer > 1000, let r = cfRect(info, kCGWindowBounds), r.width >= 600, r.height >= 400 { capturing = true }
                    continue
                }
                // 녹화 표시: 시스템(Window Server)이 모니터 오른쪽 위 구석에 띄우는 28×28 창.
                // 같은 레이어의 마우스 커서 창(42×60 등)은 크기와 자리로 거른다
                if !recording, layer > 2_000_000_000, CFEqual(owner, windowServer),
                   let r = cfRect(info, kCGWindowBounds), r.width <= 40, r.height <= 40 {
                    if corners == nil { corners = displayTopRightCorners() }
                    if corners!.contains(where: { abs(r.maxX - $0.x) < 40 && abs(r.minY - $0.y) < 12 }) { recording = true }
                }
            }
            // 미션 컨트롤(레이어 19)과 데스크톱 보기(레이어 18)는 WindowManager가 화면 크기 창을 띄운다
            if layer == 18 || layer == 19 {
                if cfString(info, kCGWindowOwnerName) == "WindowManager",
                   let r = cfRect(info, kCGWindowBounds), r.width >= 600, r.height >= 400 { overview = true }
                continue
            }
            // 바탕화면 위젯: 알림 센터 프로세스가 바탕화면 레벨에 띄우는 작은 창들
            var isWidget = false
            if layer < -1_000_000 {
                let owner = cfString(info, kCGWindowOwnerName)
                isWidget = owner == "Notification Center" || owner == "NotificationCenter"
            }
            guard layer == 0 || isWidget,
                  let ownerNum = cfNumber(info, kCGWindowOwnerPID), Int32(ownerNum) != pid,
                  let number = cfNumber(info, kCGWindowNumber),
                  let rect = cfRect(info, kCGWindowBounds)
            else { continue }
            let owner = Int32(ownerNum)
            let alpha = cfNumber(info, kCGWindowAlpha) ?? 1
            if alpha < 0.05 { continue }
            if rect.width < 60 || rect.height < 40 { continue }
            // 애플 인텔리전스 쓰기 도구: 입력창 옆에 뜨는 280×168 투명 창을 그 앱이 직접 띄운다. 보이는 건 작은 아이콘뿐이라
            // 물이 엉뚱한 사각형을 두른다. 앱·속성으로는 드롭다운과 구분이 안 돼서(제목은 화면 기록 권한이 있어야 보임) 크기로 거른다
            if abs(rect.width - 280) <= 3 && abs(rect.height - 168) <= 3 { continue }
            if isWidget && (rect.width > 900 || rect.height > 900) { continue }   // 화면 전체 크기의 투명 창은 제외
            // 위젯 창은 눈에 보이는 위젯보다 사방으로 투명 여백이 있다. 실제 모양에 맞춰 줄인다
            let frame = isWidget ? rect.insetBy(dx: widgetInset, dy: widgetInset) : rect
            result.append(TrackedWindow(id: CGWindowID(number), pid: owner, frame: frame, rank: result.count, alpha: Float(alpha),
                                        kind: isWidget ? .widget : .normal))
            if result.count >= 64 { break }
        }
        return (result, overview, capturing, recording)
    }

    /// 모니터마다 오른쪽 위 구석 (전역 Quartz 좌표)
    private static func displayTopRightCorners() -> [CGPoint] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map { let b = CGDisplayBounds($0); return CGPoint(x: b.maxX, y: b.minY) }
    }

    private static func cfValue(_ d: CFDictionary, _ key: CFString) -> UnsafeRawPointer? {
        CFDictionaryGetValue(d, Unmanaged.passUnretained(key).toOpaque())
    }
    private static func cfNumber(_ d: CFDictionary, _ key: CFString) -> Double? {
        guard let v = cfValue(d, key) else { return nil }
        var x: Double = 0
        return CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .doubleType, &x) ? x : nil
    }
    private static func cfString(_ d: CFDictionary, _ key: CFString) -> String? {
        guard let v = cfValue(d, key) else { return nil }
        return unsafeBitCast(v, to: CFString.self) as String
    }
    private static func cfRect(_ d: CFDictionary, _ key: CFString) -> CGRect? {
        guard let v = cfValue(d, key) else { return nil }
        return CGRect(dictionaryRepresentation: unsafeBitCast(v, to: CFDictionary.self))
    }
}
