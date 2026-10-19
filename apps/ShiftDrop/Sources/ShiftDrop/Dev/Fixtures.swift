import AppKit
import AVFoundation
import ImageIO

/// Sample files generated on the fly for the self-test, so CI needs nothing checked in.
@MainActor
enum Fixtures {
    static let polish = "Zażółć gęślą jaźń — pchnąć w tę łódź jeża lub ośm skrzyń fig."

    static var paragraphs: String {
        let paragraph = """
        ShiftDrop turns any file into another format with a single drag. \(polish) \
        The quick brown fox jumps over the lazy dog, and every conversion lands right next to the original file.
        """
        return (1...60).map { "\($0). \(paragraph)" }.joined(separator: "\n\n")
    }

    static func photo(at url: URL) throws -> URL {
        let width = 1200, height = 800
        guard let context = Bitmap.context(width: width, height: height, opaque: true) else { throw AppError.failed("context") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        let colors = [RGB(hex: 0xFF7A45).cgColor(), RGB(hex: 0xFFC46B).cgColor()] as CFArray
        if let gradient = CGGradient(colorsSpace: Bitmap.sRGB, colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 220), options: [])
        }
        context.setFillColor(RGB(hex: 0x3567E8).cgColor())
        context.fillEllipse(in: CGRect(x: 940, y: 520, width: 180, height: 180))
        draw(text: "SHIFTDROP", size: 120, at: CGPoint(x: 110, y: 470), in: context)
        draw(text: "Self test 2026", size: 64, at: CGPoint(x: 116, y: 350), in: context)
        guard let image = context.makeImage() else { throw AppError.failed("photo") }
        let metadata: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ShiftDrop", kCGImagePropertyTIFFModel: "Test Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:19 12:00:00",
                                             kCGImagePropertyExifLensModel: "Test Lens 50mm"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.2297, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 21.0122, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any],
        ]
        try ImageEngine.encode(image, as: .jpg, to: url, quality: 0.92, metadata: metadata)
        return url
    }

    /// 300×200 pixels stored with EXIF orientation 6, so it must load as 200×300.
    static func rotatedPhoto(at url: URL) throws -> URL {
        guard let context = Bitmap.context(width: 300, height: 200, opaque: true) else { throw AppError.failed("context") }
        context.setFillColor(RGB(hex: 0xE53935).cgColor())
        context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        context.setFillColor(RGB(hex: 0x1E88E5).cgColor())
        context.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw AppError.failed("rotated") }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 50.06, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 19.94, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError.failed("rotated") }
        return url
    }

    static func logo(at url: URL) throws -> URL {
        guard let context = Bitmap.context(width: 400, height: 400) else { throw AppError.failed("context") }
        context.clear(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(RGB(hex: 0xF2541F).cgColor())
        context.fillEllipse(in: CGRect(x: 60, y: 60, width: 280, height: 280))
        guard let image = context.makeImage() else { throw AppError.failed("logo") }
        try ImageEngine.encode(image, as: .png, to: url)
        return url
    }

    /// Mid-grey square for colour checks.
    static func grey(side: Int = 64) -> CGImage? {
        guard let context = Bitmap.context(width: side, height: side, opaque: true) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    static func notes(at url: URL) throws -> URL {
        try ("Notes\n\n" + paragraphs).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func legacyNotes(at url: URL) throws -> URL {
        guard let data = polish.data(using: .windowsCP1250) else { throw AppError.failed("cp1250") }
        try data.write(to: url)
        return url
    }

    static func html(at url: URL) throws -> URL {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>ShiftDrop</title></head>
        <body><h1>ShiftDrop</h1><p>\(polish)</p><ul><li>Drag</li><li>Shift</li><li>Drop</li></ul></body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func docx(at url: URL) throws -> URL {
        try DocumentEngine.write(DocumentEngine.plain("Letter\n\n\(polish)\n\nShiftDrop"), as: .docx, to: url)
        return url
    }

    static func report(at url: URL) throws -> URL {
        try DocumentPDFRenderer.render(DocumentEngine.plain("Report\n\n" + paragraphs), to: url)
        return url
    }

    static func tone(at url: URL, seconds: Double = 2.5) throws -> URL {
        let rate = 44_100.0
        let frames = AVAudioFrameCount(rate * seconds)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let channels = buffer.floatChannelData else { throw AppError.failed("audio buffer") }
        buffer.frameLength = frames
        for channel in 0..<Int(file.processingFormat.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = Float(0.3 * sin(2 * Double.pi * 440 * Double(frame) / rate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Two seconds of animated colour with the tone as its soundtrack.
    static func clip(at url: URL, soundtrack: URL, scratch: URL) async throws -> URL {
        let silent = scratch.appendingPathComponent("Silent.mov")
        try await silentVideo(at: silent)
        let video = AVURLAsset(url: silent)
        let audio = AVURLAsset(url: soundtrack)
        let duration = try await video.load(.duration)
        let audioDuration = try await audio.load(.duration)
        guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audio.loadTracks(withMediaType: .audio).first else { throw AppError.failed("tracks") }
        let composition = AVMutableComposition()
        let videoCopy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try videoCopy?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        let audioCopy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try audioCopy?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)),
                                       of: audioTrack, at: .zero)
        try await MediaEngine.export(composition, preset: AVAssetExportPresetHighestQuality, fileType: .mov, to: url)
        return url
    }

    private static func silentVideo(at url: URL, width: Int = 640, height: Int = 360, fps: Int32 = 30, seconds: Int = 2) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError.failed("writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(Int(fps) * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw AppError.failed("pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw AppError.failed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: Bitmap.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                let progress = CGFloat(frame) / CGFloat(Int(fps) * seconds)
                context.setFillColor(NSColor(calibratedHue: progress, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillEllipse(in: CGRect(x: 40 + progress * CGFloat(width - 200), y: 110, width: 140, height: 140))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppError.failed("writer") }
    }

    private static func draw(text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: NSColor.black,
        ]).draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }
}
