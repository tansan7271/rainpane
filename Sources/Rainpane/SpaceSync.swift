import AppKit
import ApplicationServices

/// 모니터마다 따로인 macOS 데스크톱(Space)을 Windows 가상 데스크톱처럼 함께 넘긴다.
/// 한 모니터가 N번째 데스크톱으로 넘어가면 다른 모니터도 자기 N번째 데스크톱으로 넘긴다.
/// - 어느 모니터가 몇 번째 데스크톱인지는 공개 API가 없어서 SkyLight의 `SLSCopyManagedDisplaySpaces`로 읽는다(읽기만 한다).
/// - 넘기기는 macOS의 "데스크톱 N으로 전환" 단축키(기본 Ctrl+숫자)를 대신 누른다. 손쉬운 사용 권한이 필요하고,
///   시스템 설정에서 그 단축키가 켜져 있어야 한다. 비공개 함수로 바로 바꾸면 Dock이 아는 상태와 어긋나서 쓰지 않는다.
/// - 단축키로 넘기면 포커스가 그 모니터로 옮겨 가므로, 다 넘긴 뒤 원래 창으로 되돌린다.
/// - 전체 화면 앱이 떠 있는 모니터, 그 번호의 데스크톱이 없는 모니터는 그대로 둔다.
/// 비 효과와는 따로 켜고 끈다.
final class SpaceSync: ObservableObject {
    /// 모니터별 데스크톱 수 (설정 창 표시용. 비었으면 읽지 못함)
    @Published private(set) var counts: [Int] = []
    enum Problem: Equatable {
        case accessibility
        case hotkeyOff(Int)     // 이 번호의 전환 단축키가 꺼져 있다
        case failed(Int)        // 눌렀는데 넘어가지 않았다
    }
    @Published private(set) var problem: Problem?
    /// 있는 데스크톱 중 전환 단축키가 꺼진 번호
    @Published private(set) var missingHotkeys: [Int] = []

    private var enabled = false
    private var observers: [NSObjectProtocol] = []

    /// 모니터 하나의 데스크톱 구성. current는 일반 데스크톱 중 몇 번째인지(0부터), 전체 화면 앱이면 −1
    private struct Display {
        let id: String
        let desktops: [Int]
        let current: Int
    }
    private var last: [String: Int] = [:]
    /// 우리가 넘기고 있는 모니터 → 넘어가야 할 순번과 누른 시각. 이 모니터의 변화는 사용자가 넘긴 게 아니다
    private var pending: [String: (index: Int, at: CFTimeInterval, desktop: Int)] = [:]
    /// 넘기는 동안 도착을 확인한다. 빈 데스크톱으로 넘어가면 포커스가 옮겨 가지 않아 알림이 오지 않는다
    private var poll: Timer?
    /// 마지막으로 사용자가 넘긴 모니터 (넘기는 도중 또 넘겼으면, 다 넘긴 뒤 다시 맞춘다)
    private var leaderID: String?
    private var focus: (app: NSRunningApplication, window: AXUIElement)?
    /// 눌렀는데 넘어가지 않은 번호. 시스템이 그 단축키를 받지 않으면 Ctrl+숫자가 앞 앱에 그대로 입력되므로,
    /// 구성을 다시 읽거나 단축키를 켤 때까지 다시 누르지 않는다
    private var failedDesktops: Set<Int> = []

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            // 권한은 이 기능을 켤 때만 묻는다 (시스템 대화 상자. 허용하기 전까지는 넘기지 않고 설정 창에 알린다)
            if !AXIsProcessTrusted() {
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(prompt)
            }
            let wnc = NSWorkspace.shared.notificationCenter
            observers.append(wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
            refresh()
        } else {
            for o in observers {
                NSWorkspace.shared.notificationCenter.removeObserver(o)
                NotificationCenter.default.removeObserver(o)
            }
            observers.removeAll()
            stopPolling()
            pending.removeAll(); focus = nil; problem = nil
        }
    }

    /// 구성만 다시 읽는다 (넘기지 않음). 설정 창을 열 때도 부른다: 데스크톱을 새로 만들어도 알림이 오지 않는다
    func refresh() {
        // 모니터가 빠지는 등 구성이 바뀌면 넘기던 것은 버린다 (그 모니터가 목록에 없으면 도착도 시간 초과도 판정되지 않는다)
        pending.removeAll(); stopPolling(); focus = nil
        failedDesktops.removeAll()
        let displays = Self.readDisplays()
        last = Dictionary(displays.map { ($0.id, $0.current) }, uniquingKeysWith: { a, _ in a })
        updateSummary(displays)
    }

    private func update() {
        let displays = Self.readDisplays()
        let now = CACurrentMediaTime()
        defer {
            last = Dictionary(displays.map { ($0.id, $0.current) }, uniquingKeysWith: { a, _ in a })
            // 넘기는 동안 0.05초마다 불리므로 구성(데스크톱 수)이 바뀔 때만 다시 쓴다
            if displays.map(\.desktops.count) != summaryCounts { updateSummary(displays) }
        }
        var moved: [Display] = []
        var arrived = false
        for d in displays {
            if let e = pending[d.id] {
                // 넘기는 중인 모니터의 변화는 우리 것이다 (도착했으면 끝)
                if d.current == e.index { pending[d.id] = nil; arrived = true }
                else if now - e.at > 1.2 {
                    pending[d.id] = nil
                    focus = nil
                    problem = .failed(e.desktop)
                    failedDesktops.insert(e.desktop)
                }
                continue
            }
            if let prev = last[d.id], prev != d.current { moved.append(d) }
        }
        // 목록에서 사라진 모니터를 넘기던 중이면 버린다
        let present = Set(displays.map(\.id))
        pending = pending.filter { present.contains($0.key) && now - $0.value.at <= 1.2 }
        // 사용자가 넘긴 모니터가 하나일 때만 따라간다 (여럿이 한꺼번에 바뀌면 누가 먼저인지 모른다: 건드리지 않는다)
        if moved.count == 1 { leaderID = moved[0].id }
        guard pending.isEmpty else { return }   // 넘기는 중: 다 넘긴 뒤 다시 맞춘다
        stopPolling()
        guard moved.count == 1 || arrived else { return }
        follow(displays, now: now)
        if pending.isEmpty {
            restoreFocus()
        } else if poll == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.update() }
            RunLoop.main.add(t, forMode: .common)
            poll = t
        }
    }

    private func stopPolling() { poll?.invalidate(); poll = nil }

    /// 사용자가 넘긴 모니터와 번호가 다른 모니터를 같은 번호로 넘긴다
    private func follow(_ displays: [Display], now: CFTimeInterval) {
        guard let leader = displays.first(where: { $0.id == leaderID }), leader.current >= 0 else { return }
        let idx = leader.current
        var before = 0   // 앞 모니터들의 데스크톱 수. "데스크톱 N" 번호는 모든 모니터에 걸쳐 이어진다
        for d in displays {
            defer { before += d.desktops.count }
            guard d.id != leader.id, d.current >= 0, d.current != idx, idx < d.desktops.count else { continue }
            guard AXIsProcessTrusted() else {
                problem = .accessibility
                return
            }
            let n = before + idx + 1
            guard !failedDesktops.contains(n) else { continue }
            guard let (key, flags) = Self.hotkey(forDesktop: n) else {
                problem = .hotkeyOff(n)
                continue
            }
            if focus == nil { focus = Self.focusedWindow() }
            pending[d.id] = (idx, now, n)
            Self.press(key, flags)
            problem = nil
        }
    }

    /// 단축키로 넘긴 모니터로 포커스가 옮겨 갔으니 원래 창으로 되돌린다.
    /// 그 창이 지금 화면에 없으면(사용자가 빈 데스크톱으로 넘겨서 앞 앱의 창이 숨은 경우) 건드리지 않는다:
    /// 숨은 창을 올리면 macOS가 그 창이 있는 데스크톱으로 되돌아간다
    private func restoreFocus() {
        guard let f = focus else { return }
        focus = nil
        guard Self.isOnScreen(f.window, pid: f.app.processIdentifier) else { return }
        AXUIElementSetAttributeValue(f.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(f.window, kAXRaiseAction as CFString)
        f.app.activate()
    }

    private var summaryCounts: [Int] = []

    private func updateSummary(_ displays: [Display]) {
        summaryCounts = displays.map(\.desktops.count)
        if counts != summaryCounts { counts = summaryCounts }
        let total = displays.count > 1 ? displays.reduce(0) { $0 + $1.desktops.count } : 0
        let missing = total > 0 ? (1...total).filter { Self.hotkey(forDesktop: $0) == nil } : []
        if missing != missingHotkeys { missingHotkeys = missing }
    }

    /// 설정 창 문구 (언어를 바꾸면 바로 따라가게 그릴 때마다 만든다)
    var summaryText: String {
        switch counts.count {
        case 0: return L("데스크톱 구성을 읽지 못했어요", "Could not read the desktop layout")
        case 1: return L("모니터 1대 (또는 \"디스플레이마다 별도의 Spaces\"가 꺼져 있음)",
                         "One display (or \"Displays have separate Spaces\" is off)")
        default:
            let list = counts.map(String.init).joined(separator: " / ")
            return L("모니터 \(counts.count)대 · 데스크톱 \(list)개", "\(counts.count) displays · \(list) desktops")
        }
    }

    var problemText: String? {
        switch problem {
        case .accessibility?:
            return L("시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 Rainpane을 허용해 주세요",
                     "Allow Rainpane in System Settings → Privacy & Security → Accessibility")
        case .hotkeyOff(let n)?:
            return L("\"데스크톱 \(n)(으)로 전환\" 단축키가 꺼져 있어요. 아래 버튼으로 켤 수 있어요",
                     "The \"Switch to Desktop \(n)\" shortcut is off. Use the button below to turn it on")
        case .failed(let n)?:
            return L("데스크톱 \(n)(으)로 넘기지 못했어요. 시스템 설정의 \"데스크톱 \(n)(으)로 전환\" 단축키를 확인해 주세요",
                     "Could not switch to Desktop \(n). Check the \"Switch to Desktop \(n)\" shortcut in System Settings")
        case nil:
            return nil
        }
    }

    /// 꺼진 "데스크톱 N으로 전환" 단축키를 기본값 Ctrl+숫자로 켠다 (설정 창 버튼으로만).
    /// 시스템 설정 → 키보드 단축키에서 직접 켜는 것과 같다. 10번까지만 기본 키가 있다
    func enableMissingHotkeys() {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        // 다른 단축키 설정을 그대로 두고 데스크톱 전환 항목만 바꾼다. 읽은 값이 예상한 모양이 아니면 덮어쓰지 않는다
        let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain)
        guard raw == nil || raw is [String: Any] else { return }
        var all = raw as? [String: Any] ?? [:]
        for n in missingHotkeys where n <= 10 {
            var e = all[String(117 + n)] as? [String: Any]
                ?? ["value": ["parameters": [65535, Int(Self.digitKeys[n - 1]), 262144], "type": "standard"] as [String: Any]]
            e["enabled"] = true
            all[String(117 + n)] = e
        }
        CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // 설정을 바꾼 뒤 시스템에 다시 읽게 한다 (시스템 설정 앱이 하는 것과 같다)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        p.arguments = ["-u"]
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.problem = nil; self?.refresh() } }   // refresh가 실패 기록도 지운다
        try? p.run()
    }

    // MARK: 시스템

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let sky: (conn: ConnFn, copy: CopySpacesFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(h, "SLSMainConnectionID"), let f = dlsym(h, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(c, to: ConnFn.self), unsafeBitCast(f, to: CopySpacesFn.self))
    }()

    /// 모니터 순서는 미션 컨트롤의 데스크톱 번호 순서와 같다. type 0이 일반 데스크톱, 4가 전체 화면 앱
    private static func readDisplays() -> [Display] {
        guard let sky, let arr = sky.copy(sky.conn())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["Display Identifier"] as? String else { return nil }
            let spaces = d["Spaces"] as? [[String: Any]] ?? []
            let desktops = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { $0["ManagedSpaceID"] as? Int }
            let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            return Display(id: id, desktops: desktops, current: cur.flatMap { desktops.firstIndex(of: $0) } ?? -1)
        }
    }

    private static let digitKeys: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]   // 1…9, 0

    /// "데스크톱 N으로 전환" 단축키 (시스템 설정 값). 꺼 두었거나 켠 적이 없으면 nil (켠 적 없는 번호는 기본으로 꺼져 있다)
    private static func hotkey(forDesktop n: Int) -> (CGKeyCode, CGEventFlags)? {
        guard (1...16).contains(n) else { return nil }
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any],
              let e = all[String(117 + n)] as? [String: Any],   // 118 = 데스크톱 1
              (e["enabled"] as? Bool) == true,
              let p = (e["value"] as? [String: Any])?["parameters"] as? [Int], p.count == 3,
              p[1] >= 0, p[1] < 128, let key = CGKeyCode(exactly: p[1]),   // 65535는 "키 없음"
              let mods = UInt64(exactly: p[2]) else { return nil }
        return (key, CGEventFlags(rawValue: mods))
    }

    private static func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// 지금 포커스된 창 (다 넘긴 뒤 되돌리려고). 창 제목이나 내용은 읽지 않는다
    private static func focusedWindow() -> (app: NSRunningApplication, window: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &w) == .success,
              let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (app, w as! AXUIElement)
    }

    /// 그 창이 지금 보이는 데스크톱에 떠 있나: 같은 앱의 화면 위 창 중 위치·크기가 같은 게 있나
    private static func isOnScreen(_ window: AXUIElement, pid: pid_t) -> Bool {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let b = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { return false }
            return abs(r.minX - p.x) < 2 && abs(r.minY - p.y) < 2 && abs(r.width - s.width) < 2 && abs(r.height - s.height) < 2
        }
    }
}
