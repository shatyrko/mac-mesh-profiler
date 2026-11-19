// Renders the app icon into an .iconset directory (passed as the first argument).
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square background with a deep teal → indigo gradient.
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225,
                      cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.05, green: 0.42, blue: 0.45, alpha: 1),
        CGColor(red: 0.17, green: 0.16, blue: 0.45, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Mesh: a ring of nodes, every node connected to every other.
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = rect.width * 0.32
    let count = 6
    var nodes: [CGPoint] = []
    for i in 0..<count {
        let a = CGFloat(i) / CGFloat(count) * 2 * .pi + .pi / 2
        nodes.append(CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
    }
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    ctx.setLineWidth(max(1, s * 0.012))
    for i in 0..<count {
        for j in (i + 1)..<count {
            ctx.move(to: nodes[i]); ctx.addLine(to: nodes[j])
        }
    }
    ctx.strokePath()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.setLineWidth(max(1, s * 0.022))
    for i in 0..<count {
        ctx.move(to: nodes[i]); ctx.addLine(to: nodes[(i + 1) % count])
    }
    ctx.strokePath()
    let nodeR = s * 0.05
    for (i, p) in nodes.enumerated() {
        let c = i % 2 == 0
            ? CGColor(red: 0.55, green: 0.95, blue: 0.80, alpha: 1)  // Yggdrasil-ish green
            : CGColor(red: 0.98, green: 0.78, blue: 0.40, alpha: 1)  // Mycelium-ish amber
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: p.x - nodeR, y: p.y - nodeR, width: 2 * nodeR, height: 2 * nodeR))
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let cr = s * 0.07
    ctx.fillEllipse(in: CGRect(x: center.x - cr, y: center.y - cr, width: 2 * cr, height: 2 * cr))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
