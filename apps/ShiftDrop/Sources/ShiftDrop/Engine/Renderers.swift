import AppKit
import CoreImage

// Pure rendering code shared by the editor previews, the final export and the self-test.

struct RGB: Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        self.init(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    init(_ color: NSColor) {
        let converted = color.usingColorSpace(.sRGB) ?? .black
        self.init(converted.redComponent, converted.greenComponent, converted.blueComponent)
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

// MARK: - Crop

enum CropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 = left/top edge, 1 = right/bottom edge, 0 = untouched.
    var x: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: return -1
        case .topRight, .right, .bottomRight: return 1
        case .top, .bottom: return 0
        }
    }

    var y: Int {
        switch self {
        case .topLeft, .top, .topRight: return -1
        case .bottomLeft, .bottom, .bottomRight: return 1
        case .left, .right: return 0
        }
    }

    var isCorner: Bool { x != 0 && y != 0 }

    func position(in rect: CGRect) -> CGPoint {
        CGPoint(x: x < 0 ? rect.minX : (x > 0 ? rect.maxX : rect.midX),
                y: y < 0 ? rect.minY : (y > 0 ? rect.maxY : rect.midY))
    }
}

enum CropAspect: String, CaseIterable {
    case free, square, wide, tall, classic, portrait

    var label: String {
        switch self {
        case .free: return "Free"
        case .square: return "1:1"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .classic: return "4:3"
        case .portrait: return "3:4"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .classic: return 4.0 / 3.0
        case .portrait: return 3.0 / 4.0
        }
    }
}

/// Crop rectangles are in image pixels with a top-left origin.
enum CropMath {
    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }

    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        var result = rect.offsetBy(dx: delta.width, dy: delta.height)
        result.origin.x = clamp(result.minX, bounds.minX, bounds.maxX - result.width)
        result.origin.y = clamp(result.minY, bounds.minY, bounds.maxY - result.height)
        return result
    }

    static func resized(_ rect: CGRect, handle: CropHandle, delta: CGSize, ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        let minimum = min(16, bounds.width, bounds.height)
        guard let ratio else {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if handle.x < 0 { minX = clamp(rect.minX + delta.width, bounds.minX, maxX - minimum) }
            if handle.x > 0 { maxX = clamp(rect.maxX + delta.width, minX + minimum, bounds.maxX) }
            if handle.y < 0 { minY = clamp(rect.minY + delta.height, bounds.minY, maxY - minimum) }
            if handle.y > 0 { maxY = clamp(rect.maxY + delta.height, minY + minimum, bounds.maxY) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        if handle.isCorner {
            let anchor = CGPoint(x: handle.x < 0 ? rect.maxX : rect.minX, y: handle.y < 0 ? rect.maxY : rect.minY)
            var width = max(minimum, rect.width + delta.width * CGFloat(handle.x))
            var height = max(minimum, rect.height + delta.height * CGFloat(handle.y))
            width = max(width, height * ratio)
            height = width / ratio
            let maxWidth = handle.x < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x
            let maxHeight = handle.y < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y
            let fit = min(1, maxWidth / width, maxHeight / height)
            width *= fit
            height *= fit
            return CGRect(x: handle.x < 0 ? anchor.x - width : anchor.x,
                          y: handle.y < 0 ? anchor.y - height : anchor.y,
                          width: width, height: height)
        }

        if handle.x != 0 {
            let anchorX = handle.x < 0 ? rect.maxX : rect.minX
            var width = max(minimum, rect.width + delta.width * CGFloat(handle.x))
            var height = width / ratio
            let maxWidth = handle.x < 0 ? anchorX - bounds.minX : bounds.maxX - anchorX
            let maxHeight = 2 * min(rect.midY - bounds.minY, bounds.maxY - rect.midY)
            let fit = min(1, maxWidth / width, maxHeight / height)
            width *= fit
            height *= fit
            return CGRect(x: handle.x < 0 ? anchorX - width : anchorX, y: rect.midY - height / 2,
                          width: width, height: height)
        }

        let anchorY = handle.y < 0 ? rect.maxY : rect.minY
        var height = max(minimum, rect.height + delta.height * CGFloat(handle.y))
        var width = height * ratio
        let maxHeight = handle.y < 0 ? anchorY - bounds.minY : bounds.maxY - anchorY
        let maxWidth = 2 * min(rect.midX - bounds.minX, bounds.maxX - rect.midX)
        let fit = min(1, maxWidth / width, maxHeight / height)
        width *= fit
        height *= fit
        return CGRect(x: rect.midX - width / 2, y: handle.y < 0 ? anchorY - height : anchorY,
                      width: width, height: height)
    }

    /// Largest rectangle of the given ratio that fits the bounds, centred as close to `center` as possible.
    static func fitted(ratio: CGFloat, around center: CGPoint, in bounds: CGRect) -> CGRect {
        var width = bounds.width
        var height = width / ratio
        if height > bounds.height {
            height = bounds.height
            width = height * ratio
        }
        return CGRect(x: clamp(center.x - width / 2, bounds.minX, bounds.maxX - width),
                      y: clamp(center.y - height / 2, bounds.minY, bounds.maxY - height),
                      width: width, height: height)
    }

    static func resizedTo(_ rect: CGRect, width: CGFloat?, height: CGFloat?, ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        var newWidth = min(max(16, width ?? rect.width), bounds.width)
        var newHeight = min(max(16, height ?? rect.height), bounds.height)
        if let ratio {
            if width != nil { newHeight = newWidth / ratio } else { newWidth = newHeight * ratio }
            let fit = min(1, bounds.width / newWidth, bounds.height / newHeight)
            newWidth *= fit
            newHeight *= fit
        }
        return CGRect(x: clamp(rect.midX - newWidth / 2, bounds.minX, bounds.maxX - newWidth),
                      y: clamp(rect.midY - newHeight / 2, bounds.minY, bounds.maxY - newHeight),
                      width: newWidth, height: newHeight)
    }
}

// MARK: - Add background

struct GradientBlob: Hashable {
    var color: RGB
    var x: CGFloat
    var y: CGFloat
    var radius: CGFloat
}

struct GradientPreset: Hashable, Identifiable {
    var id: String
    var stops: [RGB]
    var blobs: [GradientBlob]

    static let all: [GradientPreset] = [
        GradientPreset(id: "ember", stops: [RGB(hex: 0xFF4D3D), RGB(hex: 0xFFB04A)],
                       blobs: [GradientBlob(color: RGB(hex: 0xFF2D6F), x: 0.15, y: 0.85, radius: 0.7),
                               GradientBlob(color: RGB(hex: 0xFFD66B), x: 0.85, y: 0.1, radius: 0.6)]),
        GradientPreset(id: "cloud", stops: [RGB(hex: 0xF4F7FB), RGB(hex: 0xDCE6F5)],
                       blobs: [GradientBlob(color: RGB(hex: 0xFFFFFF), x: 0.3, y: 0.2, radius: 0.6)]),
        GradientPreset(id: "prism", stops: [RGB(hex: 0xFF7A85), RGB(hex: 0x6FD3FF)],
                       blobs: [GradientBlob(color: RGB(hex: 0xFFE27A), x: 0.2, y: 0.15, radius: 0.55),
                               GradientBlob(color: RGB(hex: 0xA77BFF), x: 0.85, y: 0.85, radius: 0.6)]),
        GradientPreset(id: "blush", stops: [RGB(hex: 0xFAD3E1), RGB(hex: 0xE5D7FA)],
                       blobs: [GradientBlob(color: RGB(hex: 0xFFC2D6), x: 0.8, y: 0.2, radius: 0.5)]),
        GradientPreset(id: "lilac", stops: [RGB(hex: 0xC8A8F6), RGB(hex: 0xF6C3E4)],
                       blobs: [GradientBlob(color: RGB(hex: 0x9C8CFF), x: 0.1, y: 0.9, radius: 0.6)]),
        GradientPreset(id: "night", stops: [RGB(hex: 0x1B1740), RGB(hex: 0x0E1424)],
                       blobs: [GradientBlob(color: RGB(hex: 0xFF6A2A), x: 0.2, y: 0.85, radius: 0.55),
                               GradientBlob(color: RGB(hex: 0xD6337F), x: 0.8, y: 0.25, radius: 0.5),
                               GradientBlob(color: RGB(hex: 0x2BC6E8), x: 0.9, y: 0.95, radius: 0.35)]),
        GradientPreset(id: "lagoon", stops: [RGB(hex: 0x23D1E6), RGB(hex: 0x3A6DF0)],
                       blobs: [GradientBlob(color: RGB(hex: 0x7FFFD4), x: 0.15, y: 0.15, radius: 0.5)]),
        GradientPreset(id: "haze", stops: [RGB(hex: 0xA9B6FF), RGB(hex: 0xF3AEFA)],
                       blobs: [GradientBlob(color: RGB(hex: 0xFFFFFF), x: 0.5, y: 0.5, radius: 0.45)]),
    ]

    static let solids: [RGB] = [
        RGB(hex: 0xFFFFFF), RGB(hex: 0xF6C744), RGB(hex: 0x9BD14B), RGB(hex: 0x34A867), RGB(hex: 0x1E9C8F),
        RGB(hex: 0x3EC7D6), RGB(hex: 0x3567E8), RGB(hex: 0x1D2440), RGB(hex: 0x7A4BD8),
    ]
}

final class ImageBox: Equatable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
    static func == (lhs: ImageBox, rhs: ImageBox) -> Bool { lhs === rhs }
}

enum BackgroundStyle: Equatable {
    case gradient(GradientPreset)
    case solid(RGB)
    case image(ImageBox)
    case transparent
}

enum CanvasRatio: String, CaseIterable {
    case auto, square, wide, portrait

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .wide: return "16:9"
        case .portrait: return "4:5"
        }
    }

    var value: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .wide: return 16.0 / 9.0
        case .portrait: return 4.0 / 5.0
        }
    }
}

/// Lengths are in pixels of the original image.
struct BackgroundSettings: Equatable {
    var style: BackgroundStyle
    var padding: CGFloat
    var corner: CGFloat
    var shadow: CGFloat
    var ratio: CanvasRatio

    static func defaults(for size: CGSize) -> BackgroundSettings {
        let longest = max(size.width, size.height)
        return BackgroundSettings(style: .gradient(GradientPreset.all[0]),
                                  padding: (longest * 0.08).rounded(),
                                  corner: (longest * 0.025).rounded(),
                                  shadow: (longest * 0.02).rounded(),
                                  ratio: .auto)
    }
}

enum BackgroundRenderer {
    /// `scale` maps original-image pixels to the pixels of `image` (smaller than 1 for previews).
    static func render(_ image: CGImage, settings: BackgroundSettings, scale: CGFloat) -> CGImage? {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let padding = settings.padding * scale
        var canvas = CGSize(width: imageWidth + padding * 2, height: imageHeight + padding * 2)
        if let ratio = settings.ratio.value {
            if canvas.width / canvas.height > ratio {
                canvas.height = canvas.width / ratio
            } else {
                canvas.width = canvas.height * ratio
            }
        }
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0, width * height < 500_000_000,
              let context = Bitmap.context(width: width, height: height, colorSpace: image.colorSpace)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        draw(settings.style, in: bounds, context: context)

        let rect = CGRect(x: ((CGFloat(width) - imageWidth) / 2).rounded(), y: ((CGFloat(height) - imageHeight) / 2).rounded(),
                          width: imageWidth, height: imageHeight)
        let radius = min(settings.corner * scale, min(imageWidth, imageHeight) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let blur = settings.shadow * scale

        context.saveGState()
        if blur > 0.5 {
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur, color: CGColor(gray: 0, alpha: 0.38))
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
        return context.makeImage()
    }

    static func draw(_ style: BackgroundStyle, in rect: CGRect, context: CGContext) {
        switch style {
        case .transparent:
            break
        case .solid(let color):
            context.setFillColor(color.cgColor())
            context.fill(rect)
        case .gradient(let preset):
            let colors = preset.stops.map { $0.cgColor() } as CFArray
            if let gradient = CGGradient(colorsSpace: Bitmap.sRGB, colors: colors, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                                           end: CGPoint(x: rect.maxX, y: rect.minY),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            let longest = max(rect.width, rect.height)
            for blob in preset.blobs {
                let center = CGPoint(x: rect.minX + blob.x * rect.width, y: rect.minY + (1 - blob.y) * rect.height)
                let colors = [blob.color.cgColor(alpha: 0.85), blob.color.cgColor(alpha: 0)] as CFArray
                let locations: [CGFloat] = [0, 1]
                if let gradient = CGGradient(colorsSpace: Bitmap.sRGB, colors: colors, locations: locations) {
                    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                               endRadius: blob.radius * longest, options: [])
                }
            }
        case .image(let box):
            let image = box.image
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.saveGState()
            context.clip(to: rect)
            context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                           width: size.width, height: size.height))
            context.restoreGState()
        }
    }

    static func swatch(_ style: BackgroundStyle, side: Int = 64) -> CGImage? {
        guard let context = Bitmap.context(width: side, height: side) else { return nil }
        draw(style, in: CGRect(x: 0, y: 0, width: side, height: side), context: context)
        return context.makeImage()
    }
}

// MARK: - Adjustments

struct Adjustments: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    var vibrance: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0
    var quarterTurns = 0
    var flipped = false

    var isIdentity: Bool { self == Adjustments() }
}

enum ImageAdjuster {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ adjustments: Adjustments, to image: CGImage) -> CGImage? {
        var output = CIImage(cgImage: image)
        if adjustments.flipped { output = output.oriented(.upMirrored) }
        switch ((adjustments.quarterTurns % 4) + 4) % 4 {
        case 1: output = output.oriented(.right)
        case 2: output = output.oriented(.down)
        case 3: output = output.oriented(.left)
        default: break
        }
        let extent = output.extent
        if adjustments.exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjustments.exposure])
        }
        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustments.brightness,
                kCIInputContrastKey: adjustments.contrast,
                kCIInputSaturationKey: adjustments.saturation,
            ])
        }
        if adjustments.warmth != 0 {
            // Telling Core Image the scene was lit by bluer light makes the picture warmer.
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + CGFloat(adjustments.warmth) * 3000, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if adjustments.vibrance != 0 {
            output = output.applyingFilter("CIVibrance", parameters: ["inputAmount": adjustments.vibrance])
        }
        if adjustments.sharpness > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adjustments.sharpness])
        }
        if adjustments.vignette > 0 {
            output = output.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: adjustments.vignette,
                kCIInputRadiusKey: 1.6,
            ])
        }
        output = output.cropped(to: extent)
        return context.createCGImage(output, from: extent)
    }
}

// MARK: - Annotations

enum AnnotationTool: String, CaseIterable {
    case pen, highlighter, arrow, rectangle, ellipse

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }

    var title: String { rawValue.capitalized }
}

/// Points are in image pixels with a top-left origin.
struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var color: RGB
    var width: CGFloat
    var points: [CGPoint]
}

enum AnnotationRenderer {
    static func path(for annotation: Annotation) -> CGPath {
        let path = CGMutablePath()
        guard let first = annotation.points.first else { return path }
        let last = annotation.points.last ?? first
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(last.x - first.x), height: abs(last.y - first.y))
        switch annotation.tool {
        case .pen, .highlighter:
            path.move(to: first)
            for point in annotation.points.dropFirst() { path.addLine(to: point) }
            if annotation.points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
        case .rectangle:
            path.addRect(rect)
        case .ellipse:
            path.addEllipse(in: rect)
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(annotation.width * 4, 14)
            for spread in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + length * cos(angle + spread), y: last.y + length * sin(angle + spread)))
            }
        }
        return path
    }

    static func lineWidth(for annotation: Annotation) -> CGFloat {
        annotation.tool == .highlighter ? annotation.width * 3 : annotation.width
    }

    static func opacity(for annotation: Annotation) -> CGFloat {
        annotation.tool == .highlighter ? 0.4 : 1
    }

    static func render(_ annotations: [Annotation], on image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = Bitmap.context(width: width, height: height, colorSpace: image.colorSpace) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for annotation in annotations {
            context.saveGState()
            if annotation.tool == .highlighter { context.setBlendMode(.multiply) }
            context.addPath(path(for: annotation))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(lineWidth(for: annotation))
            context.setStrokeColor(annotation.color.cgColor(alpha: opacity(for: annotation)))
            context.strokePath()
            context.restoreGState()
        }
        return context.makeImage()
    }
}

// MARK: - Redaction

enum RedactStyle: String, CaseIterable {
    case blackout, pixelate, blur

    var title: String {
        switch self {
        case .blackout: return "Black Bar"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        }
    }
}

enum Redactor {
    /// `rects` are in pixels of `image`, top-left origin.
    static func apply(_ rects: [CGRect], style: RedactStyle, to image: CGImage) -> CGImage? {
        guard !rects.isEmpty else { return image }
        let base = CIImage(cgImage: image)
        let height = CGFloat(image.height)
        var output = base
        for rect in rects {
            let area = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
                .intersection(base.extent)
            guard !area.isEmpty else { continue }
            let patch: CIImage
            switch style {
            case .blackout:
                patch = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: area)
            case .pixelate:
                let block = max(8, min(area.width, area.height) / 5)
                patch = base.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: block,
                        kCIInputCenterKey: CIVector(x: area.minX, y: area.minY),
                    ])
                    .cropped(to: area)
            case .blur:
                let radius = max(12, min(area.width, area.height) / 3)
                patch = base.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: area)
            }
            output = patch.composited(over: output)
        }
        return ImageAdjuster.context.createCGImage(output, from: base.extent)
    }

    /// Converts Vision's normalized, bottom-left boxes to padded pixel rectangles with a top-left origin.
    static func pixelRects(fromNormalized boxes: [CGRect], imageSize: CGSize, padding: CGFloat = 0.12) -> [CGRect] {
        boxes.map { box in
            let rect = CGRect(x: box.minX * imageSize.width, y: (1 - box.maxY) * imageSize.height,
                              width: box.width * imageSize.width, height: box.height * imageSize.height)
            let inset = -min(rect.width, rect.height) * padding
            return rect.insetBy(dx: inset, dy: inset)
                .intersection(CGRect(origin: .zero, size: imageSize))
        }
    }
}
