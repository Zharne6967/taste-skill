import SwiftUI

enum Theme {
    static let accent = Color(red: 0.95, green: 0.35, blue: 0.12)
    static let accentLight = Color(red: 1.0, green: 0.50, blue: 0.22)
    static let accentDeep = Color(red: 0.90, green: 0.20, blue: 0.06)

    static let accentGradient = LinearGradient(colors: [accentLight, accentDeep], startPoint: .top, endPoint: .bottom)
    static let hoverGradient = LinearGradient(colors: [accentLight, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let canvas = Color(nsColor: .underPageBackgroundColor)
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accentGradient))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
            .shadow(color: Theme.accentDeep.opacity(0.25), radius: 3, y: 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Rectangle())
    }
}

/// Segmented control with an orange pill, as used across the editors.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .background(Capsule().fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Label + slider + value, aligned in a grid-like row.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
            Text(format(value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// Checkerboard shown behind images so transparency is visible.
struct Checkerboard: View {
    var cell: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.88)))
                }
            }
        }
    }
}

/// Bottom bar shared by the editors: secondary action on the left, primary on the right.
struct EditorFooter: View {
    var resetTitle = "Reset"
    let onReset: () -> Void
    let primaryTitle: String
    var primaryDisabled = false
    let onCancel: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(resetTitle, action: onReset).buttonStyle(QuietButtonStyle())
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
                .opacity(primaryDisabled ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Maps between image pixels (top-left origin) and the rectangle an aspect-fit image occupies on screen.
struct FitTransform {
    let imageSize: CGSize
    let imageRect: CGRect

    init(imageSize: CGSize, container: CGRect) {
        self.imageSize = imageSize
        let scale = max(0.0001, min(container.width / max(imageSize.width, 1), container.height / max(imageSize.height, 1)))
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        imageRect = CGRect(x: container.midX - width / 2, y: container.midY - height / 2, width: width, height: height)
    }

    var scale: CGFloat { imageRect.width / max(imageSize.width, 1) }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + rect.minX * scale, y: imageRect.minY + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max((point.x - imageRect.minX) / scale, 0), imageSize.width),
                y: min(max((point.y - imageRect.minY) / scale, 0), imageSize.height))
    }

    /// Maps view points to image pixels, then into the coordinate space of a stored image path.
    var viewTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: imageRect.minX, ty: imageRect.minY)
    }
}
