import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private let stats = RuntimeStats()
    private var controller: RainController!
    private let spaces = SpaceSync()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = RainController(store: store, stats: stats)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SettingsView(store: store, stats: stats, spaces: spaces))
        spaces.setEnabled(store.settings.spaceSync)

        let prevOnChange = store.onChange
        store.onChange = { [weak self] new, old in
            prevOnChange?(new, old)
            if new.enabled != old.enabled || new.iconStyle != old.iconStyle || new.language != old.language { self?.updateIcon(enabled: new.enabled) }
            if new.spaceSync != old.spaceSync { self?.spaces.setEnabled(new.spaceSync) }
        }
        updateIcon(enabled: store.settings.enabled)
    }

    /// 메뉴바 아이콘: 켜져 있으면 똥, 꺼져 있으면 해골 (스타일은 설정에서)
    private func updateIcon(enabled: Bool) {
        guard let button = statusItem.button else { return }
        let emoji = enabled ? "💩" : "💀"
        if let img = StatusIcon.image(enabled: enabled, style: store.settings.iconStyle) {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = img
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        }
        button.toolTip = enabled ? L("Rainpane: 비 내리는 중", "Rainpane: raining") : L("Rainpane: 꺼짐", "Rainpane: off")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        // 오른쪽 클릭: 비 켜기/끄기
        if NSApp.currentEvent?.type == .rightMouseUp {
            store.settings.enabled.toggle()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

if ProcessInfo.processInfo.environment["RAINPANE_BENCH"] != nil {
    SnapshotHarness.bench()
}
if let dir = ProcessInfo.processInfo.environment["RAINPANE_SNAPSHOT"] {
    SnapshotHarness.run(outputDir: dir)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
