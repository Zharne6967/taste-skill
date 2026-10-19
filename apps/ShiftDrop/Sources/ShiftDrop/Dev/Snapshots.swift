import AppKit
import SwiftUI

/// `ShiftDrop --snapshots <dir>` renders the wheel and every editor to PNG so the UI can be reviewed from CI.
@MainActor
enum Snapshots {
    static func render(into directory: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sampleURL = directory.appendingPathComponent("sample.jpg")
        guard (try? Fixtures.photo(at: sampleURL)) != nil, let document = try? ImageDocument.load(sampleURL) else {
            print("❌ Couldn't create the sample image")
            return false
        }

        var ok = true
        let wheels: [(String, WheelModel, NSAppearance.Name)] = [
            ("wheel-image-formats", .preview(kind: .image, source: .jpg, mode: .convert, hovered: 3), .aqua),
            ("wheel-image-tools", .preview(kind: .image, source: .jpg, mode: .tools, hovered: 3), .aqua),
            ("wheel-pdf-formats", .preview(kind: .pdf, source: .pdf, mode: .convert, hovered: 1, summary: "2.4 MB"), .aqua),
            ("wheel-video-dark", .preview(kind: .video, source: .mov, mode: .convert, hovered: nil, summary: "48 MB"), .darkAqua),
        ]
        for (name, model, appearance) in wheels {
            ok = await save(DesktopBackdrop(model: model), size: CGSize(width: 520, height: 520), appearance: appearance,
                            to: directory.appendingPathComponent(name + ".png")) && ok
        }

        let editors: [(String, AnyView, CGSize)] = [
            ("editor-crop", AnyView(CropEditor(document: document, onCancel: {}, onApply: { _ in })), CGSize(width: 760, height: 680)),
            ("editor-background", AnyView(BackgroundEditor(document: document, onCancel: {}, onApply: { _ in })), CGSize(width: 760, height: 760)),
            ("editor-adjust", AnyView(AdjustEditor(document: document, onCancel: {}, onApply: { _ in })), CGSize(width: 860, height: 640)),
            ("editor-annotate", AnyView(AnnotateEditor(document: document, onCancel: {}, onApply: { _ in })), CGSize(width: 820, height: 700)),
            ("editor-redact", AnyView(RedactEditor(document: document, onCancel: {}, onApply: { _, _ in })), CGSize(width: 820, height: 700)),
            ("metadata", AnyView(MetadataView(fileName: "sample.jpg",
                                              entries: ((try? ImageEngine.metadataEntries(for: sampleURL)) ?? [])
                                                  .map { MetadataRow(label: $0.0, value: $0.1) },
                                              onClose: {}, onStrip: {})), CGSize(width: 520, height: 520)),
            ("welcome", AnyView(WelcomeView(onClose: {})), CGSize(width: 520, height: 700)),
            ("toast", AnyView(ToastView(success: true, title: "Saved Photo.png", detail: "2.4 MB → 380 KB", canReveal: true)
                .padding(20).background(Color.gray)), CGSize(width: 360, height: 100)),
        ]
        for (name, view, size) in editors {
            ok = await save(view, size: size, appearance: .aqua, to: directory.appendingPathComponent(name + ".png")) && ok
        }
        return ok
    }

    private static func save<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async -> Bool {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI lay out, run onAppear and settle its spring animations.
        try? await Task.sleep(nanoseconds: 900_000_000)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
            print("❌ \(url.lastPathComponent)")
            return false
        }
        print("🖼  \(url.lastPathComponent)")
        return true
    }
}

/// A desktop-like gradient behind the wheel, standing in for the real behind-window blur.
private struct DesktopBackdrop: View {
    let model: WheelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1.0, green: 0.40, blue: 0.25), Color(red: 0.98, green: 0.62, blue: 0.25),
                                    Color(red: 0.55, green: 0.50, blue: 0.88)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.3))
                .frame(width: model.geometry.diameter, height: model.geometry.diameter)
            WheelView(model: model)
        }
    }
}
