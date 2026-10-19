import SwiftUI

struct WelcomeView: View {
    let onClose: () -> Void
    @StateObject private var wheel = WheelModel.preview(kind: .image, source: .jpg, mode: .convert, hovered: 1)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(red: 1.0, green: 0.43, blue: 0.27), Color(red: 0.98, green: 0.66, blue: 0.29),
                                        Color(red: 0.62, green: 0.52, blue: 0.86)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color.white.opacity(0.22)).frame(width: wheel.geometry.diameter, height: wheel.geometry.diameter)
                WheelView(model: wheel)
            }
            .frame(height: 380)
            .clipped()

            VStack(alignment: .leading, spacing: 16) {
                Text("Convert anything without opening an app")
                    .font(.system(size: 20, weight: .bold))
                step(1, "Drag a file", "From Finder, the Desktop, Photos or a browser.")
                step(2, "Press ⇧ Shift while dragging", "A wheel of formats appears under the cursor. Press Shift again for tools like Crop, Compress or Add BG.")
                step(3, "Drop it on a format", "The result lands next to the original. Click the confirmation to reveal it.")
                HStack {
                    Text("ShiftDrop lives in the menu bar.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Got It", action: onClose)
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
        .frame(width: 520)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accentGradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
