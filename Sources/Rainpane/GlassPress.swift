import SwiftUI

/// 마우스로 누른 물을 macOS 리퀴드 글래스 재질로 그린다 (선택 기능, macOS 26+).
/// 뒤 화면을 휘어 보이게 하는 건 WindowServer가 합성하므로 앱은 픽셀을 보지 않고, 화면 기록 권한도 필요 없다.
/// 모양·움직임은 Metal 물방울과 같은 `PressEffect` 물리를 그대로 쓴다.
final class GlassPressModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: Int
        var center: CGPoint     // 화면 로컬 pt (좌상단 원점, y 아래)
        var a: CGFloat          // 늘어난 축 반지름
        var b: CGFloat          // 수직 축 반지름
        var angle: CGFloat      // 늘어난 축 방향 (라디안)
    }
    @Published var items: [Item] = []
    @Published var spacing: CGFloat = 20
}

/// 유리 손잡이 (설정 탭 "물방울")
struct GlassTuning: Equatable {
    var refraction: CGFloat = 1     // 렌즈 세기 배율
    var blur: CGFloat = 0           // pt
    var spacing: CGFloat = 20       // 이 거리 안이면 유리끼리 액체처럼 합쳐진다
    // 뒤 화면 밝기 범위를 좁혀 민무늬 배경에서도 보이게
    var lightBG: CGFloat = 0        // 밝은 배경을 어둡게 (1이면 흰색 → 80%)
    var darkBG: CGFloat = 0         // 어두운 배경을 밝게 (1이면 검은색 → 10%)
}

/// 경계 상자 가운데에 angle만큼 돌린 타원
struct TiltedEllipse: Shape {
    var a: CGFloat, b: CGFloat, angle: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: -a, y: -b, width: a * 2, height: b * 2))
            .applying(CGAffineTransform(rotationAngle: angle)
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
}

@available(macOS 26.0, *)
struct GlassPressView: View {
    @ObservedObject var model: GlassPressModel
    var body: some View {
        // 컨테이너 안의 유리끼리는 가까워지면 액체처럼 합쳐진다 (더블클릭 등)
        GlassEffectContainer(spacing: model.spacing) {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(model.items) { it in
                    Color.clear
                        .frame(width: it.a * 2, height: it.a * 2)
                        .glassEffect(.clear, in: TiltedEllipse(a: it.a, b: it.b, angle: it.angle))
                        .position(it.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// 오버레이 창 하나에 얹는 유리 레이어
final class GlassPress {
    private let model = GlassPressModel()
    private let host: NSView

    static var available: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// macOS 26 미만이면 nil
    init?(attachingTo root: NSView) {
        guard #available(macOS 26.0, *) else { return nil }
        let host = NSHostingView(rootView: GlassPressView(model: model))
        host.sizingOptions = []
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        self.host = host
    }

    private var tuning = GlassTuning()

    func update(_ items: [GlassPressModel.Item], tuning t: GlassTuning) {
        guard items != model.items || t != tuning else { return }
        tuning = t
        if model.spacing != t.spacing { model.spacing = t.spacing }
        model.items = items
        guard !items.isEmpty, let layer = host.layer else { return }
        // SwiftUI는 모양이 바뀔 때마다 유리 필터 값을 다시 넣는다. 지금 바로 레이아웃을 돌린 뒤 덮어써야 이번 프레임에 남는다
        host.layoutSubtreeIfNeeded()
        // 유리 여러 개가 한 컨테이너에 있으면 시스템이 가장 작은 모양 기준으로 렌즈 세기를 정해서(잔 물방울 5pt면
        // 굴절 높이 3.6pt) 본 방울이 얇은 윤곽선만 남은 채 투명해진다. 가장 큰 방울 기준으로 다시 맞춘다
        let lens = items.map { sqrt($0.a * $0.b) }.max() ?? 0
        Self.makeClear(layer, lensRadius: lens, tuning: t)
    }

    /// 완전히 맑은 유리: 흐림과 흰 막을 끄고, 밝기 범위 압축은 "밝은·어두운 배경에서 보이기"만큼만 남긴다. 가장자리 굴절과 하이라이트는 그대로.
    /// 공개 API에는 흐림 조절이 없어서(regular / clear뿐) 시스템 유리 필터(glassBackground)의 값을 직접 바꾼다.
    /// 비공개 구현이라 macOS가 바뀌면 효과가 없어질 수 있다 (그래도 기본 유리로 보일 뿐 깨지지는 않는다).
    private static func makeClear(_ root: CALayer, lensRadius: CGFloat, tuning: GlassTuning) {
        var top = root
        while let s = top.superlayer { top = s }
        for l in top.sublayers ?? [] where l.name?.contains("capture backdrop") == true
            && (l.filters ?? []).contains(where: { ($0 as AnyObject).value(forKey: "name") as? String == "gaussianBlur" }) {
            l.setValue(0, forKeyPath: "filters.gaussianBlur.inputRadius")
        }
        patchGlass(root, lensRadius: lensRadius, tuning: tuning)
    }

    private static let clearFill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)

    private static func patchGlass(_ l: CALayer, lensRadius r: CGFloat, tuning t: GlassTuning) {
        if let fs = l.filters, fs.contains(where: { ($0 as AnyObject).value(forKey: "name") as? String == "glassBackground" }) {
            let k = "filters.glassBackground."
            l.setValue(t.blur, forKeyPath: k + "inputBlurRadius")
            for i in 0..<4 { l.setValue(t.blur > 0.05 ? 1 : 0, forKeyPath: k + "inputBlurOpacity\(i)") }
            // 유리 속 뒤 화면의 밝기 범위 (흰색 → White, 검은색 → Black). 좁히면 흰 배경은 회색으로, 검은 배경은 들떠 보여서
            // 민무늬 위에서도 방울이 보인다. 고정 색 틴트는 어두운 배경이나 밝은 배경 한쪽에서 묻힌다.
            // 시스템 기본 clear 유리는 0.8 / 0.05 (뿌옇게 보였다). 밝은 쪽은 조금만, 어두운 쪽은 더 들어야 둘 다 보인다
            l.setValue(1 - 0.2 * t.lightBG, forKeyPath: k + "inputFaceColorMatrixWhite")
            l.setValue(0.1 * t.darkBG, forKeyPath: k + "inputFaceColorMatrixBlack")
            l.setValue(clearFill, forKeyPath: k + "inputFaceColorMatrixFillColor")
            // 유리 뒤 화면을 절반 해상도로 캡처한다(흐림을 전제로 한 최적화). 흐림을 껐으니 원래 해상도로
            l.setValue(1.0, forKey: "scale")
            // 모양 하나일 때 시스템이 쓰는 값과 같은 식 (반경 40 → −52 / 20, 반경 20 → −26 / 14.4)
            l.setValue(-1.3 * r * t.refraction, forKeyPath: k + "inputInnerRefractionAmount")
            l.setValue(min(0.72 * r, 20), forKeyPath: k + "inputInnerRefractionHeight")
            // 렌즈를 가장 큰 방울 기준으로 맞췄더니, 아주 작은 잔 물방울은 제 크기보다 멀리 휘어 읽다가 캡처 밖(빈 곳)을 읽어
            // 검은 체커보드가 비쳤다. 렌즈가 닿는 거리만큼 둘레를 더 캡처한다 (기본 0.5pt)
            l.setValue(1.3 * r * t.refraction + 4, forKey: "marginWidth")
        }
        for c in l.sublayers ?? [] { patchGlass(c, lensRadius: r, tuning: t) }
    }
}
