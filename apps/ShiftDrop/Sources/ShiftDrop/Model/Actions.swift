import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The broad family a dragged file belongs to. It decides which wheel the user sees.
enum FileKind: String {
    case image, pdf, document, video, audio, unsupported

    static func of(_ url: URL) -> FileKind {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            let kind = of(type)
            if kind != .unsupported { return kind }
        }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .unsupported }
        return of(type)
    }

    static func of(_ type: UTType) -> FileKind {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .svg) { return .unsupported }
        if type.conforms(to: .image) { return .image }
        // Audio first: MPEG-4 audio also conforms to public.movie.
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return .unsupported
    }

    private static let documentTypes: [UTType] = [.plainText, .rtf, .rtfd, .flatRTFD, .html] + [
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text",
        "net.daringfireball.markdown",
        "com.apple.webarchive",
    ].compactMap { UTType($0) }

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .video: return "Video"
        case .audio: return "Audio"
        case .unsupported: return "File"
        }
    }
}

/// Every output format the wheel can offer.
enum Format: String, CaseIterable, Hashable {
    case png, jpg, heic, webp, avif, tiff, bmp, gif
    case pdf, txt, docx, rtf, html, odt
    case mp4, mov, hevc, m4a, wav, aiff, flac

    var label: String { rawValue.uppercased() }

    var fileExtension: String {
        switch self {
        case .hevc: return "mp4"
        default: return rawValue
        }
    }

    var isImage: Bool { imageTypeIdentifier != nil }

    var imageTypeIdentifier: String? {
        switch self {
        case .png: return "public.png"
        case .jpg: return "public.jpeg"
        case .heic: return "public.heic"
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        default: return nil
        }
    }

    var supportsAlpha: Bool { [.png, .heic, .webp, .avif, .tiff].contains(self) }
    var isLossy: Bool { [.jpg, .heic, .webp, .avif].contains(self) }

    static func from(url: URL) -> Format? { from(extension: url.pathExtension) }

    static func from(type: UTType) -> Format? {
        type.preferredFilenameExtension.flatMap { from(extension: $0) }
    }

    static func from(extension ext: String) -> Format? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg", "jpe": return .jpg
        case "heic", "heif": return .heic
        case "webp": return .webp
        case "avif": return .avif
        case "tif", "tiff": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "pdf": return .pdf
        case "txt", "text": return .txt
        case "docx": return .docx
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "odt": return .odt
        case "mp4", "m4v": return .mp4
        case "mov", "qt": return .mov
        case "m4a": return .m4a
        case "wav", "wave": return .wav
        case "aif", "aiff", "aifc": return .aiff
        case "flac": return .flac
        default: return nil
        }
    }
}

/// Tools live on the second wheel (press Shift again).
enum Tool: String, Hashable {
    case compress, metadata, edit, annotate, addBackground, crop, redact, removeBackground
    case merge, split, rotate, protect
    case mute, snapshot

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .metadata: return "Metadata"
        case .edit: return "Edit"
        case .annotate: return "Annotate"
        case .addBackground: return "Add BG"
        case .crop: return "Crop"
        case .redact: return "Redact"
        case .removeBackground: return "Cut Out"
        case .merge: return "Merge"
        case .split: return "Split"
        case .rotate: return "Rotate"
        case .protect: return "Protect"
        case .mute: return "Mute"
        case .snapshot: return "Snapshot"
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "tag"
        case .edit: return "slider.horizontal.3"
        case .annotate: return "pencil.tip.crop.circle"
        case .addBackground: return "photo"
        case .crop: return "crop"
        case .redact: return "eye.slash"
        case .removeBackground: return "wand.and.stars"
        case .merge: return "doc.on.doc"
        case .split: return "square.split.2x1"
        case .rotate: return "rotate.right"
        case .protect: return "lock"
        case .mute: return "speaker.slash"
        case .snapshot: return "camera"
        }
    }

    /// Tools that need a window (or a prompt) before anything is written.
    var isInteractive: Bool {
        switch self {
        case .metadata, .edit, .annotate, .addBackground, .crop, .redact, .protect: return true
        default: return false
        }
    }
}

enum WheelAction: Hashable {
    case convert(Format)
    case tool(Tool)
}

struct WheelItem: Identifiable, Hashable {
    let action: WheelAction
    var id: String {
        switch action {
        case .convert(let format): return "convert." + format.rawValue
        case .tool(let tool): return "tool." + tool.rawValue
        }
    }

    var label: String {
        switch action {
        case .convert(let format): return format.label
        case .tool(let tool): return tool.title.uppercased()
        }
    }

    var symbol: String? {
        if case .tool(let tool) = action { return tool.symbol }
        return nil
    }
}

enum WheelMode {
    case convert, tools
}

/// Which formats and tools each kind of file gets, in wheel order (clockwise from the top).
enum Catalog {
    static func formats(for kind: FileKind, source: Format?) -> [Format] {
        let all: [Format]
        switch kind {
        case .image: all = [.png, .jpg, .webp, .heic, .tiff, .avif, .bmp, .pdf, .txt, .docx]
        case .pdf: all = [.docx, .jpg, .png, .txt]
        case .document: all = [.pdf, .docx, .rtf, .html, .odt, .txt]
        case .video: all = [.mp4, .mov, .hevc, .gif, .m4a]
        case .audio: all = [.m4a, .wav, .aiff, .flac]
        case .unsupported: all = []
        }
        return all.filter { $0 != source && Codecs.canProduce($0) }
    }

    static func tools(for kind: FileKind, fileCount: Int) -> [Tool] {
        switch kind {
        case .image:
            var tools: [Tool] = [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact]
            if #available(macOS 14.0, *) { tools.append(.removeBackground) }
            return tools
        case .pdf:
            var tools: [Tool] = [.compress, .split, .rotate, .protect, .metadata]
            if fileCount > 1 { tools.insert(.merge, at: 1) }
            return tools
        case .video: return [.compress, .mute, .snapshot]
        case .audio: return [.compress]
        case .document, .unsupported: return []
        }
    }

    static func items(for kind: FileKind, source: Format?, mode: WheelMode, fileCount: Int) -> [WheelItem] {
        switch mode {
        case .convert: return formats(for: kind, source: source).map { WheelItem(action: .convert($0)) }
        case .tools: return tools(for: kind, fileCount: fileCount).map { WheelItem(action: .tool($0)) }
        }
    }
}

/// What this Mac can encode. ImageIO's writable list differs between macOS versions and hardware,
/// so WEBP/AVIF/HEIC are offered only when ImageIO or a Homebrew encoder can actually produce them.
enum Codecs {
    static let writableImageTypes: Set<String> = {
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as NSArray) as? [String] ?? []
        return Set(identifiers)
    }()

    static func canWriteNatively(_ format: Format) -> Bool {
        guard let identifier = format.imageTypeIdentifier else { return false }
        return writableImageTypes.contains(identifier)
    }

    static func externalEncoder(for format: Format) -> URL? {
        switch format {
        case .webp: return executable(named: "cwebp")
        case .avif: return executable(named: "avifenc")
        default: return nil
        }
    }

    static func canProduce(_ format: Format) -> Bool {
        guard format.isImage else { return true }
        return canWriteNatively(format) || externalEncoder(for: format) != nil
    }

    static func executable(named name: String) -> URL? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
