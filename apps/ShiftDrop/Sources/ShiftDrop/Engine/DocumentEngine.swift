import AppKit
import UniformTypeIdentifiers

/// Text documents go through NSAttributedString, which reads and writes RTF, DOCX, ODT and HTML natively.
/// HTML import uses WebKit, so everything here runs on the main thread.
@MainActor
enum DocumentEngine {
    static let bodyFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)

    private static let richExtensions: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt", "html", "htm", "webarchive"]

    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if !richExtensions.contains(ext) {
            return plain(try readText(url))
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw AppError.unreadable(url.lastPathComponent)
        }
    }

    static func plain(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
    }

    /// UTF-8 first, then the encodings Polish and Western text files usually come in.
    nonisolated static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        for encoding in [String.Encoding.windowsCP1250, .isoLatin2, .windowsCP1252, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw AppError.unreadable(url.lastPathComponent)
    }

    static func write(_ text: NSAttributedString, as format: Format, to url: URL) throws {
        switch format {
        case .pdf: try DocumentPDFRenderer.render(text, to: url)
        case .txt: try text.string.write(to: url, atomically: true, encoding: .utf8)
        case .docx: try write(text, type: .officeOpenXML, to: url)
        case .rtf: try write(text, type: .rtf, to: url)
        case .html: try write(text, type: .html, to: url)
        case .odt: try write(text, type: .openDocument, to: url)
        default: throw AppError.unsupported("Documents can't be saved as \(format.label).")
        }
    }

    private static func write(_ text: NSAttributedString, type: NSAttributedString.DocumentType, to url: URL) throws {
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        try data.write(to: url, options: .atomic)
    }

    static func convert(_ url: URL, to format: Format, override: URL?) throws -> URL {
        let text = try load(url)
        let output = Output.url(for: url, ext: format.fileExtension, override: override)
        try write(text, as: format, to: output)
        return output
    }
}

/// Lays an attributed string out on A4 pages and draws them into a PDF.
enum DocumentPDFRenderer {
    static func render(_ text: NSAttributedString, to url: URL,
                       pageSize: CGSize = CGSize(width: 595, height: 842), margin: CGFloat = 56) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let containerSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: containerSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0, containers.count > 1 {
                layout.removeTextContainer(at: containers.count - 1)
                containers.removeLast()
                break
            }
            if range.length == 0 || NSMaxRange(range) >= layout.numberOfGlyphs || containers.count >= 5000 { break }
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw AppError.writeFailed(url.lastPathComponent)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.closePDF()
    }
}
