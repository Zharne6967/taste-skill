import AppKit

/// Carries values that aren't Sendable (NSAttributedString, CGImage) out of background work.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs a non-interactive wheel action on a batch of files.
@MainActor
enum ActionRunner {
    static func run(_ action: WheelAction, files: [URL], kind: FileKind, override: URL?) async throws -> ActionResult {
        let accepted = files.filter { file in
            let fileKind = FileKind.of(file)
            if case .tool(.merge) = action { return fileKind == .pdf || fileKind == .image }
            return fileKind == kind
        }
        guard !accepted.isEmpty else { throw AppError.unsupported("These files can't be handled together.") }
        var result: ActionResult
        switch action {
        case .convert(let format): result = try await convert(accepted, kind: kind, to: format, override: override)
        case .tool(let tool): result = try await apply(tool, to: accepted, kind: kind, override: override)
        }
        result.failedCount += files.count - accepted.count
        return result
    }

    private static func convert(_ files: [URL], kind: FileKind, to format: Format, override: URL?) async throws -> ActionResult {
        switch kind {
        case .image:
            switch format {
            case .pdf:
                let suffix = files.count > 1 ? "+\(files.count - 1)" : nil
                let output = Output.url(for: files[0], suffix: suffix, ext: "pdf", override: override)
                try await Background.run { try ImageEngine.makePDF(from: files, to: output) }
                return ActionResult(outputs: [output])
            case .txt, .docx:
                return try await eachFile(files) { url in
                    let text = try await Background.run { try ImageEngine.recognizeText(url) }
                    let output = Output.url(for: url, ext: format.fileExtension, override: override)
                    try DocumentEngine.write(DocumentEngine.plain(text), as: format, to: output)
                    return [output]
                }
            default:
                return try await eachFile(files) { url in
                    [try await Background.run { try ImageEngine.convert(url, to: format, override: override) }]
                }
            }

        case .pdf:
            return try await eachFile(files) { url in
                switch format {
                case .jpg, .png:
                    return try await Background.run { try PDFEngine.toImages(url, format: format, override: override) }
                case .txt:
                    let text = try await Background.run { try PDFEngine.text(of: PDFEngine.open(url)) }
                    let output = Output.url(for: url, ext: "txt", override: override)
                    try text.write(to: output, atomically: true, encoding: .utf8)
                    return [output]
                case .docx:
                    let text = try await Background.run { Unchecked(value: try PDFEngine.attributedText(of: PDFEngine.open(url))) }
                    let output = Output.url(for: url, ext: "docx", override: override)
                    try DocumentEngine.write(text.value, as: .docx, to: output)
                    return [output]
                default:
                    throw AppError.unsupported("PDFs can't be saved as \(format.label).")
                }
            }

        case .document:
            return try await eachFile(files) { url in [try DocumentEngine.convert(url, to: format, override: override)] }

        case .video:
            return try await eachFile(files) { url in [try await MediaEngine.convertVideo(url, to: format, override: override)] }

        case .audio:
            return try await eachFile(files) { url in [try await MediaEngine.convertAudio(url, to: format, override: override)] }

        case .unsupported:
            throw AppError.unsupported("This kind of file isn't supported.")
        }
    }

    private static func apply(_ tool: Tool, to files: [URL], kind: FileKind, override: URL?) async throws -> ActionResult {
        switch (tool, kind) {
        case (.compress, .image):
            return try await withSizeNote(files, try await eachFile(files) { url in
                [try await Background.run { try ImageEngine.compress(url, override: override) }]
            })
        case (.compress, .pdf):
            return try await withSizeNote(files, try await eachFile(files) { url in
                [try await Background.run { try PDFEngine.compress(url, override: override) }]
            })
        case (.compress, .video):
            return try await withSizeNote(files, try await eachFile(files) { url in
                [try await MediaEngine.compressVideo(url, override: override)]
            })
        case (.compress, .audio):
            return try await withSizeNote(files, try await eachFile(files) { url in
                let output = try await MediaEngine.convertAudio(url, to: .m4a, suffix: "Compressed", bitrate: 96_000, override: override)
                try MediaEngine.discardIfNotSmaller(output, than: url)
                return [output]
            })
        case (.removeBackground, .image):
            guard #available(macOS 14.0, *) else { throw AppError.unsupported("Cut Out needs macOS 14 or newer.") }
            return try await eachFile(files) { url in
                [try await Background.run { try ImageEngine.removeBackground(url, override: override) }]
            }
        case (.merge, _):
            let output = try await Background.run { try PDFEngine.merge(files, override: override) }
            return ActionResult(outputs: [output])
        case (.split, .pdf):
            return try await eachFile(files) { url in [try await Background.run { try PDFEngine.split(url, override: override) }] }
        case (.rotate, .pdf):
            return try await eachFile(files) { url in [try await Background.run { try PDFEngine.rotate(url, override: override) }] }
        case (.mute, .video):
            return try await eachFile(files) { url in [try await MediaEngine.mute(url, override: override)] }
        case (.snapshot, .video):
            return try await eachFile(files) { url in [try await MediaEngine.snapshot(url, override: override)] }
        default:
            throw AppError.unsupported("\(tool.title) isn't available for this file.")
        }
    }

    private static func eachFile(_ files: [URL], _ work: (URL) async throws -> [URL]) async throws -> ActionResult {
        var outputs: [URL] = []
        var errors: [Error] = []
        for file in files {
            do {
                outputs += try await work(file)
            } catch {
                errors.append(error)
            }
        }
        if outputs.isEmpty, let first = errors.first { throw first }
        return ActionResult(outputs: outputs, failedCount: errors.count)
    }

    private static func withSizeNote(_ files: [URL], _ result: ActionResult) async throws -> ActionResult {
        var result = result
        if files.count == 1, let output = result.outputs.first {
            result.note = Output.sizeChange(from: files[0], to: output)
        }
        return result
    }
}
