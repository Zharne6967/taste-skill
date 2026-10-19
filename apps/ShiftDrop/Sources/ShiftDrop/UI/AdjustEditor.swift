import SwiftUI

struct AdjustEditor: View {
    let document: ImageDocument
    let onCancel: () -> Void
    let onApply: (Adjustments) -> Void

    @State private var adjustments = Adjustments()
    @State private var preview: CGImage?
    @State private var showOriginal = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Theme.canvas
                if let image = showOriginal ? document.preview : preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("Original")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(14)
                    .opacity(showOriginal ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { pressing in
                showOriginal = pressing
            }, perform: {})
            .help("Press and hold to compare with the original")

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Light") {
                            ValueSlider(title: "Exposure", value: $adjustments.exposure, range: -2...2, format: signed)
                            ValueSlider(title: "Brightness", value: $adjustments.brightness, range: -0.4...0.4, format: percent)
                            ValueSlider(title: "Contrast", value: $adjustments.contrast, range: 0.5...1.5, format: relative)
                        }
                        section("Color") {
                            ValueSlider(title: "Saturation", value: $adjustments.saturation, range: 0...2, format: relative)
                            ValueSlider(title: "Vibrance", value: $adjustments.vibrance, range: -1...1, format: percent)
                            ValueSlider(title: "Warmth", value: $adjustments.warmth, range: -1...1, format: percent)
                        }
                        section("Detail") {
                            ValueSlider(title: "Sharpness", value: $adjustments.sharpness, range: 0...2, format: percent)
                            ValueSlider(title: "Vignette", value: $adjustments.vignette, range: 0...2, format: percent)
                        }
                        section("Orientation") {
                            HStack(spacing: 8) {
                                iconButton("rotate.left", help: "Rotate left") { adjustments.quarterTurns -= 1 }
                                iconButton("rotate.right", help: "Rotate right") { adjustments.quarterTurns += 1 }
                                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally") {
                                    adjustments.flipped.toggle()
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .frame(width: 320)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                EditorFooter(onReset: { adjustments = Adjustments() }, primaryTitle: "Save",
                             primaryDisabled: adjustments.isIdentity, onCancel: onCancel) { onApply(adjustments) }
            }
            .background(.bar)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear(perform: render)
        .onChange(of: adjustments) { _ in render() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 26)
        }
        .buttonStyle(QuietButtonStyle())
        .help(help)
    }

    private func signed(_ value: Double) -> String { String(format: "%+.1f", value) }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))" }
    private func relative(_ value: Double) -> String { "\(Int(((value - 1) * 100).rounded()))" }

    private func render() {
        preview = ImageAdjuster.apply(adjustments, to: document.preview)
    }
}
