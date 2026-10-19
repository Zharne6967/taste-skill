import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct LoadedImage: @unchecked Sendable {
    let image: CGImage
    let properties: [CFString: Any]
    let typeIdentifier: String?

    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

enum Bitmap {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(width: Int, height: Int, opaque: Bool = false, colorSpace: CGColorSpace? = nil) -> CGContext? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        if let colorSpace, colorSpace.model == .rgb,
           let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: colorSpace, bitmapInfo: info) {
            return context
        }
        return CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                         bytesPerRow: 0, space: sRGB, bitmapInfo: info)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// True when some pixels are actually see-through (not just an unused alpha channel).
    static func usesTransparency(_ image: CGImage) -> Bool {
        guard hasAlpha(image) else { return false }
        let side = 48
        guard let context = Self.context(width: side, height: side), let data = context.data else { return true }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * side)
        for y in 0..<side {
            for x in 0..<side where bytes[y * context.bytesPerRow + x * 4 + 3] < 250 {
                return true
            }
        }
        return false
    }

    static func flatten(_ image: CGImage, on color: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard hasAlpha(image),
              let context = Self.context(width: image.width, height: image.height, opaque: true, colorSpace: image.colorSpace)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = Self.context(width: width, height: height, colorSpace: image.colorSpace) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

enum ImageEngine {
    /// Loads an image with its EXIF orientation already applied, so every tool works on upright pixels.
    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { throw AppError.unreadable(url.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        var image: CGImage?
        if longest > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? longest, longest),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if image == nil { image = CGImageSourceCreateImageAtIndex(source, 0, nil) }
        guard let image else { throw AppError.unreadable(url.lastPathComponent) }
        return LoadedImage(image: image, properties: properties, typeIdentifier: CGImageSourceGetType(source) as String?)
    }

    /// EXIF, GPS and IPTC survive a format change; orientation is reset because pixels are already upright.
    static func portableMetadata(from properties: [CFString: Any]) -> [CFString: Any] {
        var metadata: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { metadata[key] = value }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        return metadata
    }

    static func encode(_ image: CGImage, as format: Format, to url: URL, quality: Double = 0.9,
                       metadata: [CFString: Any] = [:]) throws {
        guard let identifier = format.imageTypeIdentifier else {
            throw AppError.unsupported("\(format.label) isn't an image format.")
        }
        if Codecs.canWriteNatively(format) {
            let pixels = format.supportsAlpha ? image : Bitmap.flatten(image)
            var properties = metadata
            if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            properties[kCGImagePropertyOrientation] = 1
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, identifier as CFString, 1, nil) else {
                throw AppError.unsupported("macOS can't write \(format.label) files.")
            }
            CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: url)
                throw AppError.writeFailed(url.lastPathComponent)
            }
            return
        }
        guard let encoder = Codecs.externalEncoder(for: format) else {
            let formula = format == .webp ? "webp" : "libavif"
            throw AppError.unsupported("This Mac can't encode \(format.label). Install an encoder with: brew install \(formula)")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encode(image, as: .png, to: temporary)
        let q = String(Int((quality * 100).rounded()))
        let arguments = format == .webp
            ? ["-quiet", "-q", q, temporary.path, "-o", url.path]
            : ["-q", q, temporary.path, url.path]
        try Shell.run(encoder, arguments)
    }

    // MARK: - Actions

    static func convert(_ url: URL, to format: Format, override: URL?) throws -> URL {
        let loaded = try load(url)
        let output = Output.url(for: url, ext: format.fileExtension, override: override)
        try encode(loaded.image, as: format, to: output, metadata: portableMetadata(from: loaded.properties))
        return output
    }

    /// One PDF page per image, at the image's own size.
    static func makePDF(from urls: [URL], to output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw AppError.writeFailed(output.lastPathComponent)
        }
        do {
            for url in urls {
                let loaded = try load(url)
                let dpi = (loaded.properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
                var box = CGRect(x: 0, y: 0,
                                 width: CGFloat(loaded.image.width) * 72 / CGFloat(dpi),
                                 height: CGFloat(loaded.image.height) * 72 / CGFloat(dpi))
                context.beginPage(mediaBox: &box)
                context.interpolationQuality = .high
                context.draw(loaded.image, in: box)
                context.endPage()
            }
            context.closePDF()
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func recognizeText(_ url: URL) throws -> String {
        let loaded = try load(url, maxPixelSize: 4096)
        let text = try OCR.recognize(loaded.image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.noText }
        return text
    }

    static func compress(_ url: URL, override: URL?) throws -> URL {
        let loaded = try load(url, maxPixelSize: 3840)
        let source = Format.from(url: url)
        let transparent = Bitmap.usesTransparency(loaded.image)
        let target: Format
        if source == .heic || transparent {
            target = Codecs.canWriteNatively(.heic) ? .heic : (transparent ? .png : .jpg)
        } else {
            target = .jpg
        }
        let output = Output.url(for: url, suffix: "Compressed", ext: target.fileExtension, override: override)
        try encode(loaded.image, as: target, to: output, quality: 0.62)
        if Output.fileSize(output) >= Output.fileSize(url), target == source {
            try? FileManager.default.removeItem(at: output)
            throw AppError.alreadySmall
        }
        return output
    }

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isEmpty else { return nil }
        return image.cropping(to: clipped)
    }

    /// Removes EXIF, GPS, IPTC and XMP. Uses a lossless copy when ImageIO supports it.
    static func stripMetadata(_ url: URL, override: URL?) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw AppError.unreadable(url.lastPathComponent)
        }
        let output = Output.url(for: url, suffix: "Clean", ext: url.pathExtension.isEmpty ? "png" : url.pathExtension,
                                override: override)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let metadata = CGImageMetadataCreateMutable()
            if orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, NSNumber(value: orientation))
            }
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeXMP: true,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
               !hasIdentifyingMetadata(output) {
                return output
            }
            try? FileManager.default.removeItem(at: output)
        }
        // Fallback: re-encode upright pixels with no metadata at all.
        let loaded = try load(url)
        let format = Format.from(url: url).flatMap { Codecs.canWriteNatively($0) ? $0 : nil } ?? .png
        let fallback = Output.url(for: url, suffix: "Clean", ext: format.fileExtension, override: override)
        try encode(loaded.image, as: format, to: fallback, quality: 0.92)
        return fallback
    }

    static func hasIdentifyingMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil {
            return true
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifLensModel] != nil {
            return true
        }
        return false
    }

    @available(macOS 14.0, *)
    static func removeBackground(_ url: URL, override: URL?) throws -> URL {
        let loaded = try load(url, maxPixelSize: 4096)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: loaded.image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw AppError.noSubject
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let cutout = ImageAdjuster.context.createCGImage(masked, from: masked.extent) else {
            throw AppError.failed("Couldn't render the cut-out.")
        }
        let output = Output.url(for: url, suffix: "Cut Out", ext: "png", override: override)
        try encode(cutout, as: .png, to: output)
        return output
    }

    // MARK: - Metadata for display

    static func metadataEntries(for url: URL) throws -> [(String, String)] {
        let loaded = try load(url, maxPixelSize: 64)
        let properties = loaded.properties
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        var entries: [(String, String)] = [
            ("Dimensions", "\(width) × \(height) px"),
            ("File size", ByteCountFormatter.string(fromByteCount: Output.fileSize(url), countStyle: .file)),
        ]
        if let type = loaded.typeIdentifier, let description = UTType(type)?.localizedDescription {
            entries.append(("Type", description))
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String { entries.append(("Color profile", profile)) }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { entries.append(("Camera", camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { entries.append(("Lens", lens)) }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { entries.append(("Taken", date)) }
        var exposure: [String] = []
        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", fNumber)) }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time < 1 ? "1/\(Int((1 / time).rounded())) s" : String(format: "%.1f s", time))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { exposure.append(String(format: "%.0f mm", focal)) }
        if !exposure.isEmpty { entries.append(("Exposure", exposure.joined(separator: "  "))) }
        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            entries.append(("Location", String(format: "%.5f° %@, %.5f° %@", latitude, latRef, longitude, lonRef)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { entries.append(("Software", software)) }
        if let artist = (tiff[kCGImagePropertyTIFFArtist] as? String) ?? (iptc[kCGImagePropertyIPTCByline] as? [String])?.first {
            entries.append(("Author", artist))
        }
        if let copyright = (tiff[kCGImagePropertyTIFFCopyright] as? String) ?? (iptc[kCGImagePropertyIPTCCopyrightNotice] as? String) {
            entries.append(("Copyright", copyright))
        }
        return entries
    }
}

enum OCR {
    static func recognize(_ image: CGImage, fast: Bool = false) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return layout(request.results ?? [])
    }

    /// Normalized bounding boxes (bottom-left origin) of every text line.
    static func textBoxes(_ image: CGImage) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    static func faceBoxes(_ image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Groups observations into rows, top to bottom, left to right; leaves a blank line at paragraph gaps.
    static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines = observations
            .compactMap { observation -> (box: CGRect, text: String)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (observation.boundingBox, text)
            }
            .sorted { $0.box.midY > $1.box.midY }

        var rows: [[(box: CGRect, text: String)]] = []
        for line in lines {
            if let last = rows.last?.first, abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        var output = ""
        var previous: CGRect?
        for row in rows {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let box = sorted[0].box
            if let previous {
                let gap = previous.minY - box.maxY
                output += gap > max(previous.height, box.height) * 0.9 ? "\n\n" : "\n"
            }
            output += sorted.map(\.text).joined(separator: " ")
            previous = box
        }
        return output
    }
}
