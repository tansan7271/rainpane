import AppKit
import CoreText

/// 메뉴바 아이콘 스타일. 켜져 있으면 똥, 꺼져 있으면 해골.
enum StatusIconStyle: String, CaseIterable, Identifiable, Codable {
    case fontAwesome, fluent, emoji
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fontAwesome: return "Font Awesome"
        case .fluent: return "Fluent"
        case .emoji: return L("컬러 이모지", "Color emoji")
        }
    }
}

/// 흑백 스타일은 템플릿 이미지라서 메뉴바가 라이트 모드면 검정, 다크 모드면 흰색으로 알아서 칠해진다.
/// - Font Awesome Free Solid 폰트의 poo(U+F2FE)·skull(U+F54C) 글리프 (폰트 OFL, 아이콘 CC BY 4.0)
/// - Microsoft Fluent Emoji 고대비 SVG (MIT)
enum StatusIcon {
    private static var cache: [String: NSImage] = [:]
    static let size = NSSize(width: 18, height: 18)

    private static let awesome: NSFont? = {
        guard let url = Bundle.main.url(forResource: "FontAwesome-Solid", withExtension: "otf"),
              let desc = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else { return nil }
        return CTFontCreateWithFontDescriptor(desc, 14, nil) as NSFont
    }()

    /// 흑백 템플릿 이미지. 리소스가 없으면 nil (컬러 이모지로 대체)
    static func image(enabled: Bool, style: StatusIconStyle) -> NSImage? {
        let key = "\(style.rawValue)-\(enabled)"
        if let img = cache[key] { return img }
        var result: NSImage?
        switch style {
        case .fontAwesome:
            guard let font = awesome else { return nil }
            let glyph = enabled ? "\u{f2fe}" : "\u{f54c}"
            result = NSImage(size: size, flipped: false) { rect in
                let str = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.black])
                let s = str.size()
                str.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
                return true
            }
        case .fluent:
            guard let url = Bundle.main.url(forResource: enabled ? "fluent-poo" : "fluent-skull", withExtension: "svg"),
                  let svg = NSImage(contentsOf: url) else { return nil }
            result = NSImage(size: size, flipped: false) { rect in
                svg.draw(in: rect)
                return true
            }
        case .emoji:
            return nil
        }
        result?.isTemplate = true
        cache[key] = result
        return result
    }
}
