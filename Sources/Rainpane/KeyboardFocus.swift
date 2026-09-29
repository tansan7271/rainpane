import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 키보드로 포커스를 옮기면(Tab) 그 자리(텍스트 커서, 없으면 포커스된 요소 가운데)를,
/// Enter로 무언가를 보내거나 누르면 그 칸의 사각형을 알려준다.
/// 선택 기능. 다른 앱의 키 입력과 포커스 위치는 손쉬운 사용 권한으로만 알 수 있다.
/// 입력칸의 글은 읽지 않는다(칸 종류·위치·크기·텍스트 커서 위치만). Enter·Tab 말고 다른 키는 무슨 키인지 보지 않는다.
/// 비밀번호 칸과 보안 입력 중(`secure`)에는 텍스트 커서 위치도 묻지 않는다.
/// (예전엔 "Enter 전 글이 사라지면 보냄"으로 여러 줄 칸의 줄바꿈을 걸렀는데, 잠깐이라도 입력 내용을 읽는 게 찜찜해서 뺐다.
///  지금은 여러 줄 칸에서 Shift·Option 없는 Enter는 늘 보냄으로 본다. 메모·메일 본문의 줄바꿈에도 튄다)
final class KeyboardFocus {
    var onPoint: ((SIMD2<Float>) -> Void)?
    var onPop: ((CGRect) -> Void)?
    var onStatus: ((String?) -> Void)?
    private var monitor: Any?
    private var trustTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// 접근성 조회는 다른 앱에 묻는 IPC라 느릴 수 있어서 메인 스레드 밖에서
    private let queue = DispatchQueue(label: "local.rainpane.keyboard-focus")

    /// 포커스된 칸 (글은 읽지 않는다)
    struct Field {
        let pid: pid_t
        let frame: CGRect
        let isText: Bool
        /// 비밀번호 칸이거나 시스템이 보안 입력 중
        let secure: Bool
        /// 한 줄짜리 칸(주소창·검색창·입력 필드): Enter가 줄바꿈일 수 없다
        let singleLine: Bool
        /// 코드 편집기(칸 종류 설명이 "editor", 예: VSCode 편집기): Enter는 줄바꿈이다
        let codeEditor: Bool
        /// 같은 칸, 같은 자리 (Tab이 포커스를 옮겼는지 볼 때)
        func sameSpot(_ o: Field) -> Bool {
            pid == o.pid && abs(frame.minX - o.frame.minX) < 6 && abs(frame.width - o.frame.width) < 6
                && abs(frame.minY - o.frame.minY) < 6 && abs(frame.height - o.frame.height) < 6
        }
    }
    /// 마지막으로 본 칸 (타이핑 중 가끔, Tab 뒤). Tab이 포커스를 옮겼는지 알기 위해
    /// (곧바로 포커스를 옮기는 앱은 Tab 순간에 물어도 이미 옮겨 간 뒤라). queue에서만 읽고 쓴다
    private var lastField: (field: Field, at: CFTimeInterval)?
    private var recentField: Field? {
        guard let l = lastField, CACurrentMediaTime() - l.at < 30 else { return nil }
        return l.field
    }
    private var lastTypedCheck: CFTimeInterval = 0     // 메인 스레드

    func start() {
        guard monitor == nil, trustTimer == nil else { return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            install()
            return
        }
        onStatus?(L("키보드 물방울: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 Rainpane을 허용해 주세요",
                     "Keyboard drops: allow Rainpane in System Settings → Privacy & Security → Accessibility"))
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.trustTimer = nil
            self?.onStatus?(nil)
            self?.install()
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        trustTimer?.invalidate(); trustTimer = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        restoreAccessibility()
    }

    private func install() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard !e.isARepeat else { return }
            switch e.keyCode {
            case 36, 76:                                // Return, 키패드 Enter
                // Shift·Option+Enter는 채팅 앱들의 줄바꿈
                self?.locateSubmit(newlineKey: !e.modifierFlags.intersection([.shift, .option]).isEmpty)
            case 48: self?.locateTab()
            default: self?.noteTyping()
            }
        }
        // Electron 앱(VSCode·Slack)과 Chrome은 접근성 트리를 기본으로 만들지 않는다. 앞으로 온 앱에 켜 달라고 알린다
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.enableAccessibility(app.processIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication { enableAccessibility(app.processIdentifier) }
    }

    /// 우리가 AXManualAccessibility를 켠 앱 (queue에서만). 끌 때 되돌린다: 켜 둔 채면 Electron 앱이 계속 접근성 트리를 만든다
    private var manualAX: Set<pid_t> = []

    private func enableAccessibility(_ pid: pid_t) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var cur: CFTypeRef?
            // 이미 켜져 있으면(보이스오버 등 다른 도구가 켬) 건드리지 않는다
            if AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &cur) == .success,
               (cur as? Bool) == true { return }
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                self.manualAX.insert(pid)
            }
        }
    }

    private func restoreAccessibility() {
        queue.async {
            for pid in self.manualAX where NSRunningApplication(processIdentifier: pid) != nil {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            }
            self.manualAX.removeAll()
        }
    }

    /// 타이핑 중엔 0.3초에 한 번만 지금 칸(위치·크기)을 적어 둔다
    private func noteTyping() {
        let now = CACurrentMediaTime()
        guard now - lastTypedCheck > 0.3 else { return }
        lastTypedCheck = now
        queue.async { [weak self] in
            if let f = Self.focusedField() { self?.lastField = (f, CACurrentMediaTime()) }
        }
    }

    /// Enter: 버튼·링크, 비밀번호 칸, 한 줄짜리 칸(주소창·검색창)에서는 늘 누름·제출.
    /// 여러 줄 칸은 Shift·Option+Enter(줄바꿈), 코드 편집기, 폭 80pt 미만의 숨은 입력칸만 빼고 늘 보냄으로 본다
    private func locateSubmit(newlineKey: Bool) {
        queue.async { [weak self] in
            guard let self, let f = Self.focusedField(), Self.poppable(f.frame) else { return }
            if f.isText && !f.secure && !f.singleLine && (newlineKey || f.codeEditor || f.frame.width < 80) { return }
            DispatchQueue.main.async { self.onPop?(f.frame) }
        }
    }

    /// Tab: 포커스가 다른 칸으로 옮겨 갔을 때만 (편집기 들여쓰기처럼 칸 안에서 처리된 Tab은 같은 칸·같은 자리에 그대로 있다)
    private func locateTab() {
        queue.async { [weak self] in
            guard let self else { return }
            let before = self.recentField ?? Self.focusedField()
            self.queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, let f = Self.focusedField() else { return }
                self.lastField = (f, CACurrentMediaTime())
                if let before, before.sameSpot(f) { return }
                guard let p = Self.focusPoint() else { return }
                DispatchQueue.main.async { self.onPoint?(p) }
            }
        }
    }

    private static func poppable(_ r: CGRect) -> Bool {
        r.width >= 24 && r.height >= 12 && r.width <= 1600 && r.height <= 500
    }

    // MARK: 접근성 조회 (좌표는 전역 Quartz와 같은 좌상단 원점)

    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.2)
        return el
    }

    static func focusPoint() -> SIMD2<Float>? {
        guard let el = focusedElement() else { return nil }
        // 비밀번호 칸의 커서 위치는 비밀번호 길이를 드러내니 묻지 않고 칸 가운데로
        if !isSecure(el), let r = caretRect(el) { return SIMD2(Float(r.midX), Float(r.midY)) }
        guard let pos: CGPoint = axValue(el, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(el, kAXSizeAttribute, .cgSize) else { return nil }
        // 편집기 전체·웹 페이지 본문처럼 큰 요소의 가운데는 의미가 없다
        guard size.width < 700, size.height < 300, size.width > 0 else { return nil }
        return SIMD2(Float(pos.x + size.width / 2), Float(pos.y + size.height / 2))
    }

    static func focusedField() -> Field? {
        guard let el = focusedElement(),
              let pos: CGPoint = axValue(el, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(el, kAXSizeAttribute, .cgSize) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let frame = CGRect(origin: pos, size: size)
        if isSecure(el) {
            return Field(pid: pid, frame: frame, isText: true, secure: true, singleLine: true, codeEditor: false)
        }
        // 텍스트 칸인지는 "텍스트 커서 범위 속성이 있나"로만 본다 (값은 묻지 않음)
        var range: CFTypeRef?
        let isText = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        var role: CFTypeRef?, subrole: CFTypeRef?, roleDesc: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
        AXUIElementCopyAttributeValue(el, kAXRoleDescriptionAttribute as CFString, &roleDesc)
        let r = role as? String
        let singleLine = r == kAXTextFieldRole || r == kAXComboBoxRole || (subrole as? String) == kAXSearchFieldSubrole
        let codeEditor = (roleDesc as? String)?.lowercased().contains("editor") ?? false
        return Field(pid: pid, frame: frame, isText: isText, secure: false, singleLine: singleLine, codeEditor: codeEditor)
    }

    /// 비밀번호 칸이거나, 시스템이 보안 입력 중(어디선가 비밀번호를 치는 중)이면 true
    private static func isSecure(_ el: AXUIElement) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == kAXSecureTextFieldSubrole || (role as? String) == "AXSecureTextField"
    }

    /// 텍스트 커서 자리. 길이 0 범위로 먼저 묻고, 빈 사각형을 주는 앱이면 커서 앞 글자의 오른쪽 끝으로 (글자 자체는 읽지 않음)
    private static func caretRect(_ el: AXUIElement) -> CGRect? {
        guard let range: CFRange = axValue(el, kAXSelectedTextRangeAttribute, .cfRange) else { return nil }
        if let r = bounds(el, CFRange(location: range.location, length: 0)), r.height > 1 { return r }
        if range.location > 0, let r = bounds(el, CFRange(location: range.location - 1, length: 1)), r.height > 1 {
            return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        if let r = bounds(el, CFRange(location: range.location, length: 1)), r.height > 1 {
            return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
        }
        return nil
    }

    private static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        return rect
    }

    private static func axValue<T>(_ el: AXUIElement, _ name: String, _ type: AXValueType) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AXValueGetValue(v as! AXValue, type, ptr) else { return nil }
        return ptr.pointee
    }
}
