import SwiftUI

/// Fills the panel; the wheel itself sits in the middle.
struct WheelRootView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        WheelView(model: model)
            .id(model.presentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        let geometry = model.geometry
        ZStack {
            Circle()
                .fill(colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.16))
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.35 : 0.85),
                                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.25)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)

            SegmentRing(items: model.items, hovered: model.hovered, geometry: geometry)
                .id(model.mode)
                .transition(.asymmetric(insertion: .scale(scale: 0.72).combined(with: .opacity),
                                        removal: .scale(scale: 1.12).combined(with: .opacity)))

            WheelHub(model: model)
                .frame(width: geometry.hubRadius * 2, height: geometry.hubRadius * 2)
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .scaleEffect(appeared ? 1 : 0.8)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

struct SegmentRing: View {
    let items: [WheelItem]
    let hovered: Int?
    let geometry: WheelGeometry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isHovered = hovered == index
                ZStack {
                    SegmentShape(segment: geometry.segment(index: index, count: items.count),
                                 corner: geometry.corner,
                                 style: isHovered ? AnyShapeStyle(Theme.hoverGradient) : AnyShapeStyle(restingFill))
                        .opacity(isHovered ? 1 : restingOpacity)
                        .shadow(color: isHovered ? Theme.accentDeep.opacity(0.4) : Color.black.opacity(0.06),
                                radius: isHovered ? 10 : 2, y: isHovered ? 3 : 1)
                    SegmentLabel(item: item, highlighted: isHovered, compact: items.count > 8)
                        .position(geometry.labelPoint(index: index, count: items.count))
                }
                .frame(width: geometry.diameter, height: geometry.diameter)
                .scaleEffect(isHovered ? 1.045 : 1)
            }
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovered)
    }

    private var restingFill: Color { colorScheme == .dark ? Color(white: 0.32) : Color.white }
    private var restingOpacity: Double { colorScheme == .dark ? 0.55 : 0.68 }
}

/// Fill + round-joined stroke of the inset sector = a segment with rounded corners.
struct SegmentShape: View {
    let segment: RingSegment
    let corner: CGFloat
    let style: AnyShapeStyle

    var body: some View {
        ZStack {
            segment.fill(style, style: FillStyle(eoFill: true))
            segment.stroke(style, style: StrokeStyle(lineWidth: corner * 2, lineCap: .round, lineJoin: .round))
        }
        .compositingGroup()
    }
}

struct SegmentLabel: View {
    let item: WheelItem
    let highlighted: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(item.label)
                .font(.system(size: item.symbol == nil ? (compact ? 12 : 13) : 9.5, weight: .bold))
                .tracking(item.symbol == nil ? 0.3 : 0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(highlighted ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.9) : Color(white: 0.16)))
        .frame(width: 72)
    }
}

struct WheelHub: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(colorScheme == .dark ? Color(white: 0.18).opacity(0.7) : Color.white.opacity(0.42))
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5)
            content
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.phase)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.accentGradient)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.red)
        case .choosing:
            VStack(spacing: 6) {
                let hovered = model.hoveredItem
                Text(hovered?.label ?? model.summary)
                    .font(.system(size: hovered == nil ? 13 : 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.white.opacity(0.75)))
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color(white: 0.16))
                    .frame(maxWidth: model.geometry.hubRadius * 1.7)
                if let hint = model.otherModeHint {
                    Text(hint)
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.hovered)
        }
    }
}
