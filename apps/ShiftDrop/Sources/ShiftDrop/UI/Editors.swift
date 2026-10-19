import AppKit
import SwiftUI

struct ImageDocument: @unchecked Sendable {
    let url: URL
    let full: LoadedImage
    let preview: CGImage

    var image: CGImage { full.image }
    var size: CGSize { full.size }
    var previewScale: CGFloat { CGFloat(preview.width) / CGFloat(max(1, full.image.width)) }

    /// Edited images keep their format when ImageIO can write it well; everything else becomes PNG.
    var outputFormat: Format {
        if let format = Format.from(url: url), [.jpg, .png, .heic, .tiff, .webp, .avif].contains(format),
           Codecs.canWriteNatively(format) {
            return format
        }
        return .png
    }

    static func load(_ url: URL) throws -> ImageDocument {
        let full = try ImageEngine.load(url)
        let preview = Bitmap.downscale(full.image, maxPixel: 1400) ?? full.image
        return ImageDocument(url: url, full: full, preview: preview)
    }
}

final class EditorWindow: NSWindow, NSWindowDelegate {
    private static var open: [EditorWindow] = []

    @MainActor
    static func present<Content: View>(title: String, size: CGSize, content: (EditorWindow) -> Content) {
        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = window
        window.minSize = CGSize(width: 560, height: 480)
        window.contentView = NSHostingView(rootView: content(window))
        window.setContentSize(size)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        open.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The SwiftUI content captures the window, so drop it once the close has finished.
        Task { @MainActor [self] in
            contentView = nil
            EditorWindow.open.removeAll { $0 === self }
        }
    }
}

@MainActor
enum Editors {
    static func open(_ tool: Tool, files: [URL], kind: FileKind, override: URL?) {
        guard let url = files.first(where: { FileKind.of($0) == kind }) else {
            Toast.shared.show(AppError.unsupported("Nothing to open."), near: nil)
            return
        }
        switch (tool, kind) {
        case (.protect, .pdf):
            protectPDF(url, override: override)
        case (.metadata, .pdf):
            showMetadata(for: url, entries: { try PDFEngine.metadataEntries(for: url) },
                         strip: { try PDFEngine.stripMetadata(url, override: override) })
        case (.metadata, .image):
            showMetadata(for: url, entries: { try ImageEngine.metadataEntries(for: url) },
                         strip: { try ImageEngine.stripMetadata(url, override: override) })
        case (_, .image):
            Task { @MainActor in
                do {
                    let document = try await Background.run { try ImageDocument.load(url) }
                    presentImageEditor(tool, document: document, override: override)
                } catch {
                    Toast.shared.show(error, near: nil)
                }
            }
        default:
            Toast.shared.show(AppError.unsupported("\(tool.title) isn't available for this file."), near: nil)
        }
    }

    private static func presentImageEditor(_ tool: Tool, document: ImageDocument, override: URL?) {
        let name = document.url.lastPathComponent
        switch tool {
        case .crop:
            EditorWindow.present(title: "Crop Image — \(name)", size: CGSize(width: 760, height: 680)) { window in
                CropEditor(document: document, onCancel: { window.close() }, onApply: { rect in
                    window.close()
                    save(document: document, suffix: "Cropped", override: override) {
                        guard let image = ImageEngine.crop(document.image, to: rect) else { throw AppError.failed("Nothing left to crop.") }
                        return image
                    }
                })
            }
        case .addBackground:
            EditorWindow.present(title: "Add Background — \(name)", size: CGSize(width: 760, height: 760)) { window in
                BackgroundEditor(document: document, onCancel: { window.close() }, onApply: { settings in
                    window.close()
                    save(document: document, suffix: "With Background", format: .png, keepMetadata: false, override: override) {
                        guard let image = BackgroundRenderer.render(document.image, settings: settings, scale: 1) else {
                            throw AppError.failed("The image is too large to add a background.")
                        }
                        return image
                    }
                })
            }
        case .edit:
            EditorWindow.present(title: "Edit — \(name)", size: CGSize(width: 860, height: 640)) { window in
                AdjustEditor(document: document, onCancel: { window.close() }, onApply: { adjustments in
                    window.close()
                    save(document: document, suffix: "Edited", override: override) {
                        guard let image = ImageAdjuster.apply(adjustments, to: document.image) else { throw AppError.failed("Couldn't apply the edits.") }
                        return image
                    }
                })
            }
        case .annotate:
            EditorWindow.present(title: "Annotate — \(name)", size: CGSize(width: 820, height: 700)) { window in
                AnnotateEditor(document: document, onCancel: { window.close() }, onApply: { annotations in
                    window.close()
                    save(document: document, suffix: "Annotated", override: override) {
                        guard let image = AnnotationRenderer.render(annotations, on: document.image) else { throw AppError.failed("Couldn't draw the annotations.") }
                        return image
                    }
                })
            }
        case .redact:
            EditorWindow.present(title: "Redact — \(name)", size: CGSize(width: 820, height: 700)) { window in
                RedactEditor(document: document, onCancel: { window.close() }, onApply: { rects, style in
                    window.close()
                    save(document: document, suffix: "Redacted", keepMetadata: false, override: override) {
                        guard let image = Redactor.apply(rects, style: style, to: document.image) else { throw AppError.failed("Couldn't redact the image.") }
                        return image
                    }
                })
            }
        default:
            Toast.shared.show(AppError.unsupported("\(tool.title) isn't available for images."), near: nil)
        }
    }

    static func save(document: ImageDocument, suffix: String, format: Format? = nil, keepMetadata: Bool = true,
                     override: URL?, render: @escaping () throws -> CGImage) {
        let target = format ?? document.outputFormat
        let output = Output.url(for: document.url, suffix: suffix, ext: target.fileExtension, override: override)
        let metadata = keepMetadata ? ImageEngine.portableMetadata(from: document.full.properties) : [:]
        JobCenter.shared.begin()
        Task { @MainActor in
            defer { JobCenter.shared.end() }
            do {
                try await Background.run {
                    try ImageEngine.encode(try render(), as: target, to: output, quality: 0.92, metadata: metadata)
                }
                Toast.shared.show(ActionResult(outputs: [output]), near: nil)
                if Settings.shared.revealResults { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            } catch {
                Toast.shared.show(error, near: nil)
            }
        }
    }

    private static func showMetadata(for url: URL, entries: @escaping () throws -> [(String, String)],
                                     strip: @escaping () throws -> URL) {
        let rows: [(String, String)]
        do {
            rows = try entries()
        } catch {
            Toast.shared.show(error, near: nil)
            return
        }
        EditorWindow.present(title: "Metadata — \(url.lastPathComponent)", size: CGSize(width: 520, height: 520)) { window in
            MetadataView(fileName: url.lastPathComponent, entries: rows.map { MetadataRow(label: $0.0, value: $0.1) },
                         onClose: { window.close() },
                         onStrip: {
                             window.close()
                             JobCenter.shared.begin()
                             Task { @MainActor in
                                 defer { JobCenter.shared.end() }
                                 do {
                                     let output = try await Background.run { try strip() }
                                     Toast.shared.show(ActionResult(outputs: [output], note: "Metadata removed"), near: nil)
                                 } catch {
                                     Toast.shared.show(error, near: nil)
                                 }
                             }
                         })
        }
    }

    private static func protectPDF(_ url: URL, override: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Protect “\(url.lastPathComponent)”"
        alert.informativeText = "Anyone opening the copy will need this password."
        alert.addButton(withTitle: "Protect")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let password = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let repeated = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        repeated.placeholderString = "Repeat password"
        stack.addArrangedSubview(password)
        stack.addArrangedSubview(repeated)
        stack.frame = CGRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = password
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !password.stringValue.isEmpty else {
            Toast.shared.show(AppError.failed("The password can't be empty."), near: nil)
            return
        }
        guard password.stringValue == repeated.stringValue else {
            Toast.shared.show(AppError.failed("The passwords don't match."), near: nil)
            return
        }
        let secret = password.stringValue
        JobCenter.shared.begin()
        Task { @MainActor in
            defer { JobCenter.shared.end() }
            do {
                let output = try await Background.run { try PDFEngine.protect(url, password: secret, override: override) }
                Toast.shared.show(ActionResult(outputs: [output], note: "Password protected"), near: nil)
            } catch {
                Toast.shared.show(error, near: nil)
            }
        }
    }
}

struct MetadataRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct MetadataView: View {
    let fileName: String
    let entries: [MetadataRow]
    let onClose: () -> Void
    let onStrip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fileName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Saving a clean copy removes camera details, location, dates and authorship. The original stays untouched.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(entry.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(entry.value)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        if entry.id != entries.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .padding(.horizontal, 20)
            }

            Divider().padding(.top, 14)
            HStack {
                Spacer()
                Button("Close", action: onClose).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save Clean Copy", action: onStrip).buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}
