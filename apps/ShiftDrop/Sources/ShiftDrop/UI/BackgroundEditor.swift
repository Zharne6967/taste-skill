import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackgroundEditor: View {
    let document: ImageDocument
    let onCancel: () -> Void
    let onApply: (BackgroundSettings) -> Void

    @State private var settings: BackgroundSettings
    @State private var preview: CGImage?
    @State private var customColor = Color(red: 0.24, green: 0.42, blue: 0.95)
    @State private var customImage: ImageBox?

    init(document: ImageDocument, onCancel: @escaping () -> Void, onApply: @escaping (BackgroundSettings) -> Void) {
        self.document = document
        self.onCancel = onCancel
        self.onApply = onApply
        _settings = State(initialValue: BackgroundSettings.defaults(for: document.size))
    }

    private var longest: Double { Double(max(document.size.width, document.size.height)) }
    private var shortest: Double { Double(min(document.size.width, document.size.height)) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Checkerboard().opacity(settings.style == .transparent ? 1 : 0)
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)

            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    label("Background")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(GradientPreset.all) { preset in
                                swatch(.gradient(preset))
                            }
                            imageSwatch
                        }
                        HStack(spacing: 8) {
                            ForEach(GradientPreset.solids, id: \.self) { color in
                                swatch(.solid(color))
                            }
                            ColorPicker("", selection: Binding(get: { customColor }, set: { color in
                                customColor = color
                                settings.style = .solid(RGB(NSColor(color)))
                            }), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 30)
                            swatch(.transparent)
                        }
                    }
                }
                ValueSlider(title: "Padding", value: lengthBinding(\.padding), range: 0...longest * 0.4) { "\(Int($0)) px" }
                ValueSlider(title: "Corners", value: lengthBinding(\.corner), range: 0...shortest * 0.25) { "\(Int($0)) px" }
                ValueSlider(title: "Shadow", value: lengthBinding(\.shadow), range: 0...longest * 0.08) { "\(Int($0)) px" }
                HStack(spacing: 12) {
                    label("Ratio")
                    PillPicker(options: CanvasRatio.allCases, selection: binding(\.ratio), title: \.label)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            EditorFooter(onReset: { settings = BackgroundSettings.defaults(for: document.size) },
                         primaryTitle: "Save with Background", onCancel: onCancel) { onApply(settings) }
        }
        .frame(minWidth: 620, minHeight: 640)
        .onAppear(perform: render)
        .onChange(of: settings) { _ in render() }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 74, alignment: .leading)
            .padding(.top, 6)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BackgroundSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func lengthBinding(_ keyPath: WritableKeyPath<BackgroundSettings, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(settings[keyPath: keyPath]) }, set: { settings[keyPath: keyPath] = CGFloat($0.rounded()) })
    }

    private func swatch(_ style: BackgroundStyle) -> some View {
        let selected = settings.style == style
        return Button {
            settings.style = style
        } label: {
            ZStack {
                if style == .transparent {
                    Checkerboard(cell: 5)
                } else if let image = SwatchCache.image(for: style) {
                    Image(decorative: image, scale: 1).resizable()
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(style == .transparent ? "Transparent" : "")
    }

    private var imageSwatch: some View {
        Button(action: pickImage) {
            ZStack {
                if let customImage {
                    Image(decorative: customImage.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.06)
                    Image(systemName: "photo.on.rectangle").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2).padding(-3)
                .opacity(customImage.map { settings.style == .image($0) } == true ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help("Use your own picture")
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let loaded = try? ImageEngine.load(url, maxPixelSize: 4096) else { return }
        let box = ImageBox(loaded.image)
        customImage = box
        settings.style = .image(box)
    }

    private func render() {
        preview = BackgroundRenderer.render(document.preview, settings: settings, scale: document.previewScale)
    }
}

enum SwatchCache {
    private static var cache: [String: CGImage] = [:]

    static func image(for style: BackgroundStyle) -> CGImage? {
        let key: String
        switch style {
        case .gradient(let preset): key = "g." + preset.id
        case .solid(let color): key = "s.\(color.r).\(color.g).\(color.b)"
        default: return nil
        }
        if let image = cache[key] { return image }
        let image = BackgroundRenderer.swatch(style)
        cache[key] = image
        return image
    }
}
