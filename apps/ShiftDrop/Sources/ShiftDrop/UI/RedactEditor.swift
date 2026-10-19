import SwiftUI

struct RedactEditor: View {
    let document: ImageDocument
    let onCancel: () -> Void
    let onApply: ([CGRect], RedactStyle) -> Void

    @State private var style: RedactStyle = .blackout
    @State private var rects: [CGRect] = []
    @State private var drawing: CGRect?
    @State private var preview: CGImage?
    @State private var detecting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PillPicker(options: RedactStyle.allCases, selection: $style, title: \.title)
                Spacer()
                Button {
                    detect(faces: true)
                } label: {
                    Label("Find Faces", systemImage: "face.dashed")
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                    detect(faces: false)
                } label: {
                    Label("Find Text", systemImage: "text.viewfinder")
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                    if !rects.isEmpty { rects.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 22)
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("z", modifiers: .command)
                .disabled(rects.isEmpty)
                .help("Undo")
            }
            .disabled(detecting)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            GeometryReader { proxy in
                let fit = FitTransform(imageSize: document.size,
                                       container: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 24, dy: 24))
                ZStack(alignment: .topLeading) {
                    Image(decorative: preview ?? document.preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.imageRect.width, height: fit.imageRect.height)
                        .offset(x: fit.imageRect.minX, y: fit.imageRect.minY)
                    ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                        let frame = fit.toView(rect)
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    if let drawing {
                        let frame = fit.toView(drawing)
                        Rectangle()
                            .fill(Theme.accent.opacity(0.18))
                            .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    if detecting {
                        ProgressView().controlSize(.small)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let start = fit.toImage(value.startLocation)
                            let end = fit.toImage(value.location)
                            drawing = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                             width: abs(end.x - start.x), height: abs(end.y - start.y))
                        }
                        .onEnded { _ in
                            if let drawing, drawing.width > 4, drawing.height > 4 { rects.append(drawing) }
                            drawing = nil
                        }
                )
            }
            .background(Theme.canvas)

            Divider()
            HStack {
                Text("Drag over anything you want hidden. The saved copy has no metadata.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            EditorFooter(resetTitle: "Clear", onReset: { rects.removeAll() }, primaryTitle: "Save Redacted",
                         primaryDisabled: rects.isEmpty, onCancel: onCancel) { onApply(rects, style) }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear(perform: render)
        .onChange(of: rects) { _ in render() }
        .onChange(of: style) { _ in render() }
    }

    private func render() {
        let scale = document.previewScale
        let scaled = rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
        preview = Redactor.apply(scaled, style: style, to: document.preview)
    }

    private func detect(faces: Bool) {
        detecting = true
        let image = Unchecked(value: document.preview)
        let size = document.size
        Task { @MainActor in
            defer { detecting = false }
            do {
                let boxes = try await Background.run { () throws -> [CGRect] in
                    if faces { return try OCR.faceBoxes(image.value) }
                    return try OCR.textBoxes(image.value)
                }
                let found = Redactor.pixelRects(fromNormalized: boxes, imageSize: size, padding: faces ? 0.18 : 0.08)
                if found.isEmpty {
                    Toast.shared.show(AppError.failed(faces ? "No faces found." : "No text found."), near: nil)
                }
                rects += found
            } catch {
                Toast.shared.show(error, near: nil)
            }
        }
    }
}
