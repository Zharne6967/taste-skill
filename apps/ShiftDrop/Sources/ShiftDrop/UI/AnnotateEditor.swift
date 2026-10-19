import SwiftUI

struct AnnotateEditor: View {
    let document: ImageDocument
    let onCancel: () -> Void
    let onApply: ([Annotation]) -> Void

    static let palette: [RGB] = [
        RGB(hex: 0xFF3B30), RGB(hex: 0xFF9500), RGB(hex: 0xFFCC00), RGB(hex: 0x34C759),
        RGB(hex: 0x0A84FF), RGB(hex: 0xAF52DE), RGB(hex: 0x111111), RGB(hex: 0xFFFFFF),
    ]

    @State private var tool: AnnotationTool = .arrow
    @State private var color = AnnotateEditor.palette[0]
    @State private var size: Double = 3
    @State private var annotations: [Annotation] = []
    @State private var current: Annotation?

    /// Stroke widths scale with the picture so they look the same on a 1000 px and a 6000 px image.
    private var unit: CGFloat { max(document.size.width, document.size.height) / 500 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                let fit = FitTransform(imageSize: document.size,
                                       container: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 24, dy: 24))
                Canvas { context, _ in
                    context.draw(Image(decorative: document.preview, scale: 1), in: fit.imageRect)
                    for annotation in annotations + (current.map { [$0] } ?? []) {
                        draw(annotation, in: &context, fit: fit)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = fit.toImage(value.location)
                            if current == nil {
                                current = Annotation(tool: tool, color: color, width: CGFloat(size) * unit,
                                                     points: [fit.toImage(value.startLocation)])
                            }
                            if tool == .pen || tool == .highlighter {
                                current?.points.append(point)
                            } else if let first = current?.points.first {
                                current?.points = [first, point]
                            }
                        }
                        .onEnded { _ in
                            if let current { annotations.append(current) }
                            current = nil
                        }
                )
            }
            .background(Theme.canvas)
            Divider()
            EditorFooter(resetTitle: "Clear", onReset: { annotations.removeAll() }, primaryTitle: "Save",
                         primaryDisabled: annotations.isEmpty, onCancel: onCancel) { onApply(annotations) }
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases, id: \.self) { item in
                    Button {
                        tool = item
                    } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 32, height: 26)
                            .foregroundStyle(tool == item ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tool == item ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 6) {
                ForEach(Self.palette, id: \.self) { swatch in
                    Button {
                        color = swatch
                    } label: {
                        Circle()
                            .fill(Color(nsColor: swatch.nsColor))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3).opacity(color == swatch ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: $size, in: 1...10).controlSize(.small).tint(Theme.accent).frame(width: 110)
            }

            Spacer()
            Button {
                if !annotations.isEmpty { annotations.removeLast() }
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 22)
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("z", modifiers: .command)
            .disabled(annotations.isEmpty)
            .help("Undo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func draw(_ annotation: Annotation, in context: inout GraphicsContext, fit: FitTransform) {
        let path = Path(AnnotationRenderer.path(for: annotation)).applying(fit.viewTransform)
        var layer = context
        if annotation.tool == .highlighter { layer.blendMode = .multiply }
        layer.stroke(path,
                     with: .color(Color(nsColor: annotation.color.nsColor).opacity(AnnotationRenderer.opacity(for: annotation))),
                     style: StrokeStyle(lineWidth: AnnotationRenderer.lineWidth(for: annotation) * fit.scale,
                                        lineCap: .round, lineJoin: .round))
    }
}
