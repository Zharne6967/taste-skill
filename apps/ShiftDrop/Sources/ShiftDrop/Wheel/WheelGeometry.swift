import CoreGraphics
import SwiftUI

enum WheelHit: Equatable {
    case none, center
    case segment(Int)
}

/// All measurements of the wheel. Angles are radians measured clockwise from 12 o'clock.
struct WheelGeometry: Equatable {
    /// The larger item count of the two wheels, so switching wheels never resizes the window.
    var capacity: Int

    var diameter: CGFloat { capacity > 8 ? 352 : 324 }
    var margin: CGFloat { 30 }
    var windowSide: CGFloat { diameter + margin * 2 }
    var discRadius: CGFloat { diameter / 2 }
    var outerRadius: CGFloat { discRadius - 9 }
    var innerRadius: CGFloat { (discRadius * 0.43).rounded() }
    var hubRadius: CGFloat { innerRadius - 9 }
    var corner: CGFloat { 13 }
    var gap: CGFloat { 7 }

    func span(count: Int) -> Double { 2 * .pi / Double(max(count, 1)) }

    func centerAngle(index: Int, count: Int) -> Double { Double(index) * span(count: count) }

    /// Hit test from an offset relative to the wheel's centre, with y pointing up (AppKit).
    func hit(dx: CGFloat, dy: CGFloat, count: Int) -> WheelHit {
        let distance = hypot(dx, dy)
        if distance > discRadius + 4 { return .none }
        if distance <= innerRadius || count == 0 { return .center }
        var angle = atan2(Double(dx), Double(dy))
        if angle < 0 { angle += 2 * .pi }
        let span = span(count: count)
        let index = Int(((angle + span / 2) / span).rounded(.down)) % count
        return .segment(index)
    }

    /// A point in a `diameter`-sized square with y pointing down (SwiftUI).
    func point(radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(x: discRadius + radius * CGFloat(sin(angle)), y: discRadius - radius * CGFloat(cos(angle)))
    }

    func labelPoint(index: Int, count: Int) -> CGPoint {
        point(radius: (innerRadius + outerRadius) / 2, angle: centerAngle(index: index, count: count))
    }

    func segment(index: Int, count: Int) -> RingSegment {
        let center = centerAngle(index: index, count: count)
        let half = span(count: count) / 2
        return RingSegment(start: center - half, end: center + half,
                           inner: innerRadius + corner, outer: outerRadius - corner,
                           inset: gap / 2 + corner, full: count == 1)
    }
}

/// An annular sector shrunk by the corner radius. Drawn filled and stroked with a round join of
/// twice that radius, it becomes a segment with evenly rounded corners and a constant gap.
struct RingSegment: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat
    var inset: CGFloat
    var full = false

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
        }
        var path = Path()
        if full {
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            return path
        }
        let outerInset = Double(asin(min(1, inset / outer)))
        let innerInset = Double(asin(min(1, inset / inner)))
        let outerStart = start + outerInset, outerEnd = max(outerStart, end - outerInset)
        let innerStart = start + innerInset, innerEnd = max(innerStart, end - innerInset)
        let steps = 28
        for step in 0...steps {
            let angle = outerStart + (outerEnd - outerStart) * Double(step) / Double(steps)
            if step == 0 { path.move(to: point(outer, angle)) } else { path.addLine(to: point(outer, angle)) }
        }
        for step in 0...steps {
            let angle = innerEnd - (innerEnd - innerStart) * Double(step) / Double(steps)
            path.addLine(to: point(inner, angle))
        }
        path.closeSubpath()
        return path
    }
}
