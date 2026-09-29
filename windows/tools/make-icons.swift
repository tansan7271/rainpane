// 맥판 아이콘 리소스(Font Awesome 글리프, Fluent 고대비 SVG)를 128×128 알파 마스크로 굽는다.
// 윈도우판은 이 마스크에 작업 표시줄 테마에 맞는 색을 입히고 크기를 줄여 아이콘을 만든다.
// 실행 (windows/에서): swift tools/make-icons.swift ../Resources assets
import AppKit
import CoreText

let args = CommandLine.arguments
let res = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let N = 128, pad: CGFloat = 6

func render(_ name: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    NSGraphicsContext.current = nil
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    // 위에서 아래 순서로 알파만
    var a = [UInt8](repeating: 0, count: N * N)
    for y in 0..<N { for x in 0..<N { a[y * N + x] = px[(y * N + x) * 4 + 3] } }
    try! Data(a).write(to: out.appendingPathComponent(name + ".a8"))
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "/tmp/icon-" + name + ".png"), options: [])
}

let desc = (CTFontManagerCreateFontDescriptorsFromURL(res.appendingPathComponent("FontAwesome-Solid.otf") as CFURL) as! [CTFontDescriptor])[0]
let font = CTFontCreateWithFontDescriptor(desc, 100, nil)
for (name, ch) in [("fa-poo", 0xf2fe), ("fa-skull", 0xf54c)] {
    render(name) { ctx in
        var u = UniChar(ch), g = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font, &u, &g, 1)
        let b = CTFontGetBoundingRectsForGlyphs(font, .default, &g, nil, 1)
        let k = (CGFloat(N) - pad * 2) / max(b.width, b.height)
        ctx.translateBy(x: CGFloat(N) / 2, y: CGFloat(N) / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -b.midX, y: -b.midY)
        ctx.setFillColor(NSColor.black.cgColor)
        var pos = CGPoint.zero
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
    }
}
for (name, file) in [("fluent-poo", "fluent-poo.svg"), ("fluent-skull", "fluent-skull.svg")] {
    let img = NSImage(contentsOf: res.appendingPathComponent(file))!
    render(name) { _ in img.draw(in: NSRect(x: pad, y: pad, width: CGFloat(N) - pad * 2, height: CGFloat(N) - pad * 2)) }
}
print("ok")
