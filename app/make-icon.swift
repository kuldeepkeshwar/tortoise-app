// make-icon — render the menu-bar glyph (tortoise.fill) into an .iconset for the app icon,
// so Finder/Dock match the menu bar. Best-effort: build.sh ignores failure.
//
//   ./make-icon <output.iconset-dir>

import AppKit

_ = NSApplication.shared   // initialise AppKit so symbol/image drawing works headless

let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }
let outDir = args[1]

func renderPNG(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    let s = CGFloat(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // rounded teal background (macOS app-icon proportions)
    let inset = s * 0.08
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset),
                          xRadius: s * 0.225, yRadius: s * 0.225)
    NSColor(srgbRed: 0.07, green: 0.62, blue: 0.58, alpha: 1).setFill()
    bg.fill()

    // white tortoise centered
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .bold)
    if let base = NSImage(systemSymbolName: "tortoise.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = base.size
        let tinted = NSImage(size: sz)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: sz))
        NSColor.white.set()
        NSRect(origin: .zero, size: sz).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: (s - sz.width)/2, y: (s - sz.height)/2, width: sz.width, height: sz.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (base, scale) in variants {
    guard let data = renderPNG(base * scale) else { continue }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try? data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
