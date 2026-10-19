import SwiftUI

struct CropEditor: View {
    let document: ImageDocument
    let onCancel: () -> Void
    let onApply: (CGRect) -> Void

    @State private var crop: CGRect
    @State private var aspect: CropAspect = .free
    @State private var dragOrigin: CGRect?

    init(document: ImageDocument, onCancel: @escaping () -> Void, onApply: @escaping (CGRect) -> Void) {
        self.document = document
        self.onCancel = onCancel
        self.onApply = onApply
        _crop = State(initialValue: CGRect(origin: .zero, size: document.size))
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: document.size) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let fit = FitTransform(imageSize: document.size,
                                       container: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 28, dy: 28))
                let cropRect = fit.toView(crop)
                ZStack(alignment: .topLeading) {
                    Image(decorative: document.preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.imageRect.width, height: fit.imageRect.height)
                        .offset(x: fit.imageRect.minX, y: fit.imageRect.minY)

                    CutoutShape(outer: fit.imageRect, hole: cropRect)
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)

                    ThirdsShape(rect: cropRect)
                        .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                        .allowsHitTesting(false)

                    Path(cropRect)
                        .stroke(Theme.accent, lineWidth: 1.5)
                        .allowsHitTesting(false)

                    Color.white.opacity(0.001)
                        .frame(width: max(cropRect.width - 24, 1), height: max(cropRect.height - 24, 1))
                        .contentShape(Rectangle())
                        .gesture(moveGesture(scale: fit.scale))
                        .offset(x: cropRect.minX + 12, y: cropRect.minY + 12)

                    ForEach(CropHandle.allCases, id: \.self) { handle in
                        CropHandleView(handle: handle)
                            .gesture(resizeGesture(handle, scale: fit.scale))
                            .position(handle.position(in: cropRect))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .background(Theme.canvas)

            Divider()
            controls
            Divider()
            EditorFooter(onReset: reset, primaryTitle: "Apply", onCancel: onCancel) { onApply(crop.integral) }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Aspect ratio")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                PillPicker(options: CropAspect.allCases, selection: Binding(get: { aspect }, set: setAspect), title: \.label)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Size")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                dimensionField("W", value: Binding(get: { Int(crop.width.rounded()) }, set: { width in
                    crop = CropMath.resizedTo(crop, width: CGFloat(width), height: nil, ratio: aspect.ratio, in: bounds)
                }))
                dimensionField("H", value: Binding(get: { Int(crop.height.rounded()) }, set: { height in
                    crop = CropMath.resizedTo(crop, width: nil, height: CGFloat(height), ratio: aspect.ratio, in: bounds)
                }))
                Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func dimensionField(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 64)
        }
    }

    private func setAspect(_ newValue: CropAspect) {
        aspect = newValue
        guard let ratio = newValue.ratio else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            crop = CropMath.fitted(ratio: ratio, around: CGPoint(x: crop.midX, y: crop.midY), in: bounds)
        }
    }

    private func reset() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            aspect = .free
            crop = bounds
        }
    }

    private func moveGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragOrigin ?? crop
                if dragOrigin == nil { dragOrigin = crop }
                crop = CropMath.moved(start, by: CGSize(width: value.translation.width / scale,
                                                        height: value.translation.height / scale), in: bounds)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func resizeGesture(_ handle: CropHandle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragOrigin ?? crop
                if dragOrigin == nil { dragOrigin = crop }
                crop = CropMath.resized(start, handle: handle,
                                        delta: CGSize(width: value.translation.width / scale,
                                                      height: value.translation.height / scale),
                                        ratio: aspect.ratio, in: bounds)
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

struct CropHandleView: View {
    let handle: CropHandle

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.accent)
                .frame(width: handle.isCorner ? 10 : (handle.x == 0 ? 22 : 5),
                       height: handle.isCorner ? 10 : (handle.y == 0 ? 22 : 5))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
}

/// The dimmed area outside the crop.
struct CutoutShape: Shape {
    let outer: CGRect
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(outer)
        path.addRect(hole)
        return path
    }
}

struct ThirdsShape: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
