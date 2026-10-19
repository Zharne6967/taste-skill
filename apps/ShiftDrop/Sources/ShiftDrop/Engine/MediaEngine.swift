import AVFoundation
import ImageIO

/// Video goes through AVFoundation; audio goes through /usr/bin/afconvert, which ships with every Mac.
enum MediaEngine {
    static let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")

    static func export(_ asset: AVAsset, preset: String, fileType: AVFileType, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.unsupported("This video can't be exported that way.")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw AppError.unsupported("This video can't be saved as .\(output.pathExtension).")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? AppError.failed("The export didn't finish.")
        }
    }

    static func convertVideo(_ url: URL, to format: Format, override: URL?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        switch format {
        case .mp4, .mov:
            let fileType: AVFileType = format == .mp4 ? .mp4 : .mov
            let output = Output.url(for: url, ext: format.fileExtension, override: override)
            do {
                // Re-wrapping without re-encoding is instant and lossless when the codecs allow it.
                try await export(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: output)
            } catch {
                try await export(asset, preset: AVAssetExportPresetHighestQuality, fileType: fileType, to: output)
            }
            return output
        case .hevc:
            let output = Output.url(for: url, suffix: "HEVC", ext: "mp4", override: override)
            try await export(asset, preset: AVAssetExportPresetHEVCHighestQuality, fileType: .mp4, to: output)
            return output
        case .gif:
            let output = Output.url(for: url, ext: "gif", override: override)
            try await makeGIF(from: asset, to: output)
            return output
        case .m4a:
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw AppError.failed("\(url.lastPathComponent) has no sound.")
            }
            let output = Output.url(for: url, ext: "m4a", override: override)
            try await export(asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: output)
            return output
        default:
            throw AppError.unsupported("Videos can't be saved as \(format.label).")
        }
    }

    static func makeGIF(from asset: AVAsset, to output: URL, fps: Double = 12, maxSeconds: Double = 20,
                        maxSide: CGFloat = 520) async throws {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AppError.failed("The video has no frames.") }
        let seconds = min(duration, maxSeconds)
        let frameCount = max(1, Int(seconds * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString,
                                                                frameCount, nil) else {
            throw AppError.writeFailed(output.lastPathComponent)
        }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for index in 0..<frameCount {
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw AppError.writeFailed(output.lastPathComponent)
        }
    }

    static func compressVideo(_ url: URL, override: URL?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let output = Output.url(for: url, suffix: "Compressed", ext: "mp4", override: override)
        do {
            try await export(asset, preset: AVAssetExportPresetHEVC1920x1080, fileType: .mp4, to: output)
        } catch {
            try await export(asset, preset: AVAssetExportPreset1280x720, fileType: .mp4, to: output)
        }
        try discardIfNotSmaller(output, than: url)
        return output
    }

    /// A "compressed" file that came out larger than the original is useless; drop it.
    static func discardIfNotSmaller(_ output: URL, than source: URL) throws {
        guard Output.fileSize(output) >= Output.fileSize(source) else { return }
        try? FileManager.default.removeItem(at: output)
        throw AppError.alreadySmall
    }

    static func mute(_ url: URL, override: URL?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        guard !composition.tracks.isEmpty else { throw AppError.failed("\(url.lastPathComponent) has no picture.") }
        let isMP4 = Format.from(url: url) == .mp4
        let output = Output.url(for: url, suffix: "Muted", ext: isMP4 ? "mp4" : "mov", override: override)
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, fileType: isMP4 ? .mp4 : .mov, to: output)
        } catch {
            try await export(composition, preset: AVAssetExportPresetHighestQuality, fileType: isMP4 ? .mp4 : .mov, to: output)
        }
        return output
    }

    static func snapshot(_ url: URL, override: URL?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let seconds = duration.isFinite ? min(1, duration * 0.1) : 0
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let output = Output.url(for: url, ext: "jpg", override: override)
        try ImageEngine.encode(image, as: .jpg, to: output, quality: 0.92)
        return output
    }

    static func convertAudio(_ url: URL, to format: Format, suffix: String? = nil, bitrate: Int = 256_000,
                             override: URL?) async throws -> URL {
        let arguments: [String]
        switch format {
        case .m4a: arguments = ["-f", "m4af", "-d", "aac", "-b", String(bitrate)]
        case .wav: arguments = ["-f", "WAVE", "-d", "LEI16"]
        case .aiff: arguments = ["-f", "AIFF", "-d", "BEI16"]
        case .flac: arguments = ["-f", "flac", "-d", "flac"]
        default: throw AppError.unsupported("Audio can't be saved as \(format.label).")
        }
        let output = Output.url(for: url, suffix: suffix, ext: format.fileExtension, override: override)
        try await Background.run {
            do {
                try Shell.run(afconvert, arguments + [url.path, output.path])
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        return output
    }
}
