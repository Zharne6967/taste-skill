// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func segmentPath(center: CGPoint, inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
    path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
    path.closeSubpath()
    return path
}

func drawIcon(side: Int) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = CGFloat(side) / 1024
    context.scaleBy(x: s, y: s)

    // Rounded-square tile in the macOS icon grid (824 pt inside 1024).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    context.addPath(tilePath)
    context.setFillColor(color(0xFF6A3D))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0xFF4F3A), color(0xFFA640), color(0x9C7BF0)] as CFArray,
                                locations: [0, 0.55, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 760), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 760), endRadius: 520, options: [])

    let center = CGPoint(x: 512, y: 512)
    // Glass disc.
    context.addEllipse(in: CGRect(x: center.x - 330, y: center.y - 330, width: 660, height: 660))
    context.setFillColor(color(0xFFFFFF, 0.22))
    context.fillPath()
    context.addEllipse(in: CGRect(x: center.x - 330, y: center.y - 330, width: 660, height: 660))
    context.setStrokeColor(color(0xFFFFFF, 0.7))
    context.setLineWidth(5)
    context.strokePath()

    // Six segments with rounded joins; the one at 2 o'clock is "hovered".
    let count = 6
    let gap: CGFloat = 0.15
    for index in 0..<count {
        let mid = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(count)
        let half = .pi / CGFloat(count) - gap
        let path = segmentPath(center: center, inner: 175, outer: 280, start: mid - half, end: mid + half)
        let hovered = index == 1
        context.saveGState()
        if hovered {
            context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0xB4260A, 0.45))
        }
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(34)
        context.setFillColor(hovered ? color(0xF2401A) : color(0xFFF3EA))
        context.setStrokeColor(hovered ? color(0xF2401A) : color(0xFFF3EA))
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    // Hub with an upward arrow (⇧).
    context.addEllipse(in: CGRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236))
    context.setFillColor(color(0xFFFFFF, 0.92))
    context.fillPath()
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 512, y: 585))
    arrow.addLine(to: CGPoint(x: 588, y: 505))
    arrow.addLine(to: CGPoint(x: 545, y: 505))
    arrow.addLine(to: CGPoint(x: 545, y: 440))
    arrow.addLine(to: CGPoint(x: 479, y: 440))
    arrow.addLine(to: CGPoint(x: 479, y: 505))
    arrow.addLine(to: CGPoint(x: 436, y: 505))
    arrow.closeSubpath()
    context.addPath(arrow)
    context.setLineJoin(.round)
    context.setLineWidth(14)
    context.setFillColor(color(0xF2541F))
    context.setStrokeColor(color(0xF2541F))
    context.drawPath(using: .fillStroke)
    context.restoreGState()
    return context.makeImage()
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        guard let image = drawIcon(side: points * scale) else { exit(1) }
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: output.appendingPathComponent(name))
    }
}
print("Icon written to \(output.path)")
