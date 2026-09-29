import AppKit
import simd

/// 마우스로 누른 물방울만 그리는 화면별 맨 앞 창 (Dock·메뉴바보다 위).
/// 비·물 오버레이는 일반 창 바로 위라 Dock에 가려지지만, 누른 물방울은 화면 표면의 일이라 무엇보다 앞에 둔다.
/// 누르는 동안만 띄워서 평소에는 WindowServer 합성 비용이 없다.
final class PressOverlay {
    private let window: OverlayWindow
    private let renderer: ScreenRenderer
    private let glass: GlassPress?
    private var shown = false
    private var idleFrames = 0
    private static let empty = SimSnapshot()

    init(frame f: NSRect, quartz: CGRect, backingScale: CGFloat, gpu: GPU) {
        window = OverlayWindow(frame: f, level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow))))
        let root = NSView(frame: NSRect(origin: .zero, size: f.size))
        root.wantsLayer = true
        let view = MetalHostView(frame: root.bounds)
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        glass = GlassPress(attachingTo: root)       // Metal 위에 리퀴드 글래스 레이어
        window.contentView = root
        window.setFrame(f, display: false)
        renderer = ScreenRenderer(gpu: gpu, layer: view.metalLayer, quartzFrame: quartz)
        renderer.configure(quartzFrame: quartz, backingScale: backingScale, renderScale: 1)
    }

    /// presses·groups: Metal 물방울 데이터와 무리 수, glassItems: 유리 모드에서 이 화면에 걸친 방울
    /// (유리 모드면 Metal로는 밑에 깔 그림자만 그린다)
    func update(presses: [SIMD4<Float>], groups: Int, glassItems: [GlassPressModel.Item], glass glassOn: Bool,
                glassTuning: GlassTuning, base: Uniforms) {
        if groups > 0 || !glassItems.isEmpty {
            if !shown { window.orderFrontRegardless(); shown = true }
            idleFrames = 0
        } else {
            guard shown else { return }
            // 빈 프레임이 화면에 올라간 뒤에 숨긴다 (다시 띄울 때 옛 방울이 번쩍이지 않게)
            idleFrames += 1
            if idleFrames > 3 { window.orderOut(nil); shown = false; return }
        }
        glass?.update(glassItems, tuning: glassTuning)
        if groups == 0 {
            renderer.clearOnce()
        } else {
            renderer.draw(snapshot: Self.empty, presses: presses, pressGroups: groups, pressShadowOnly: glassOn,
                          base: base, rainCount: 0, splashCount: 0)
        }
    }

    func close() { window.orderOut(nil) }
}
