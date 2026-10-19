import AppKit
import PDFKit

enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw AppError.unsupported("\(url.lastPathComponent) is password-protected.") }
        return document
    }

    /// Renders a page upright (page rotation applied) at the given resolution.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        guard let pdfPage = page.pageRef else { return nil }
        let box = pdfPage.getBoxRect(.cropBox)
        let quarterTurned = (pdfPage.rotationAngle / 90) % 2 != 0
        let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        var scale = dpi / 72
        let maxPixels: CGFloat = 80_000_000
        if size.width * size.height * scale * scale > maxPixels {
            scale = sqrt(maxPixels / (size.width * size.height))
        }
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = Bitmap.context(width: width, height: height, opaque: true) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                        rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdfPage)
        return context.makeImage()
    }

    static func toImages(_ url: URL, format: Format, override: URL?) throws -> [URL] {
        let document = try open(url)
        guard document.pageCount > 0 else { throw AppError.failed("\(url.lastPathComponent) has no pages.") }
        if document.pageCount == 1, let page = document.page(at: 0), let image = render(page, dpi: 200) {
            let output = Output.url(for: url, ext: format.fileExtension, override: override)
            try ImageEngine.encode(image, as: format, to: output)
            return [output]
        }
        let folder = try Output.folder(for: url, suffix: format.label, override: override)
        let base = url.deletingPathExtension().lastPathComponent
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = render(page, dpi: 200) else { continue }
            let name = "\(base) \(String(format: "%03d", index + 1))"
            try ImageEngine.encode(image, as: format, to: Output.unique(in: folder, base: name, ext: format.fileExtension))
        }
        return [folder]
    }

    /// Embedded text when there is some; scanned PDFs fall back to OCR.
    static func text(of document: PDFDocument) throws -> String {
        let embedded = document.string ?? ""
        if !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return embedded }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 200) {
            guard let page = document.page(at: index), let image = render(page, dpi: 220) else { continue }
            pages.append(try OCR.recognize(image))
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.noText }
        return text
    }

    static func attributedText(of document: PDFDocument) throws -> NSAttributedString {
        let combined = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.attributedString, text.length > 0 else { continue }
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
            combined.append(text)
        }
        if combined.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSAttributedString(string: try text(of: document), attributes: [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        return combined
    }

    static func compress(_ url: URL, override: URL?) throws -> URL {
        let document = try open(url)
        let output = Output.url(for: url, suffix: "Compressed", ext: "pdf", override: override)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard document.write(to: output, withOptions: options) else { throw AppError.writeFailed(output.lastPathComponent) }
        if Output.fileSize(output) >= Output.fileSize(url) {
            try? FileManager.default.removeItem(at: output)
            throw AppError.alreadySmall
        }
        return output
    }

    /// Joins PDFs and images, in the order they were dragged.
    static func merge(_ urls: [URL], override: URL?) throws -> URL {
        guard let first = urls.first else { throw AppError.failed("Nothing to merge.") }
        let merged = PDFDocument()
        for url in urls {
            if FileKind.of(url) == .image {
                let loaded = try ImageEngine.load(url)
                let image = NSImage(cgImage: loaded.image, size: loaded.size)
                if let page = PDFPage(image: image) { merged.insert(page, at: merged.pageCount) }
                continue
            }
            let document = try open(url)
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let output = Output.url(for: first, suffix: "Merged", ext: "pdf", override: override)
        guard merged.pageCount > 0, merged.write(to: output) else { throw AppError.writeFailed(output.lastPathComponent) }
        return output
    }

    static func split(_ url: URL, override: URL?) throws -> URL {
        let document = try open(url)
        guard document.pageCount > 1 else { throw AppError.failed("\(url.lastPathComponent) has only one page.") }
        let folder = try Output.folder(for: url, suffix: "Pages", override: override)
        let base = url.deletingPathExtension().lastPathComponent
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let output = Output.unique(in: folder, base: "\(base) \(String(format: "%03d", index + 1))", ext: "pdf")
            guard single.write(to: output) else { throw AppError.writeFailed(output.lastPathComponent) }
        }
        return folder
    }

    static func rotate(_ url: URL, override: URL?) throws -> URL {
        let document = try open(url)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + 90) % 360
        }
        let output = Output.url(for: url, suffix: "Rotated", ext: "pdf", override: override)
        guard document.write(to: output) else { throw AppError.writeFailed(output.lastPathComponent) }
        return output
    }

    static func protect(_ url: URL, password: String, override: URL?) throws -> URL {
        let document = try open(url)
        let output = Output.url(for: url, suffix: "Protected", ext: "pdf", override: override)
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard document.write(to: output, withOptions: options) else { throw AppError.writeFailed(output.lastPathComponent) }
        return output
    }

    static func stripMetadata(_ url: URL, override: URL?) throws -> URL {
        let document = try open(url)
        document.documentAttributes = [:]
        let output = Output.url(for: url, suffix: "Clean", ext: "pdf", override: override)
        guard document.write(to: output) else { throw AppError.writeFailed(output.lastPathComponent) }
        return output
    }

    static func metadataEntries(for url: URL) throws -> [(String, String)] {
        let document = try open(url)
        let attributes = document.documentAttributes ?? [:]
        var entries: [(String, String)] = [
            ("Pages", "\(document.pageCount)"),
            ("File size", ByteCountFormatter.string(fromByteCount: Output.fileSize(url), countStyle: .file)),
        ]
        if let page = document.page(at: 0) {
            let size = page.bounds(for: .mediaBox).size
            entries.append(("Page size", String(format: "%.0f × %.0f pt", size.width, size.height)))
        }
        let keys: [(PDFDocumentAttribute, String)] = [
            (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
            (.creatorAttribute, "Created with"), (.producerAttribute, "Producer"), (.keywordsAttribute, "Keywords"),
            (.creationDateAttribute, "Created"), (.modificationDateAttribute, "Modified"),
        ]
        for (key, label) in keys {
            guard let value = attributes[key.rawValue] else { continue }
            if let date = value as? Date {
                entries.append((label, date.formatted(date: .abbreviated, time: .shortened)))
            } else if let list = value as? [String] {
                if !list.isEmpty { entries.append((label, list.joined(separator: ", "))) }
            } else {
                let text = "\(value)"
                if !text.isEmpty { entries.append((label, text)) }
            }
        }
        return entries
    }
}
