import SwiftUI
import WheelCore

/// Sizes and hit-testing for the radial menu. Angles are in radians, 0 = 12 o'clock, clockwise.
struct WheelGeometry {
    var outer: CGFloat = 130
    var hub: CGFloat = 55
    var ringGap: CGFloat = 8      // between hub and slices
    var sliceGap: CGFloat = 4     // between neighbouring slices
    var corner: CGFloat = 12
    var rim: CGFloat = 10         // glass border outside the slices
    var rotation: CGFloat = 0     // radians added to every slice angle

    init() {}

    init(style s: WheelStyle) {
        let k = CGFloat(s.size)
        outer = 130 * k
        hub = outer * CGFloat(s.hubRatio)
        ringGap = 8 * k
        sliceGap = CGFloat(s.sliceGap) * k
        corner = CGFloat(s.roundness) * k
        rim = 10 * k
        rotation = CGFloat(s.rotation) * .pi / 180
    }

    var inner: CGFloat { hub + ringGap }
    var diameter: CGFloat { (outer + rim) * 2 }
    /// Scale for text and icons so labels grow with the wheel.
    var labelScale: CGFloat { outer / 130 }

    enum Hit: Equatable { case none, hub, slice(Int) }

    func hit(_ p: CGPoint, center c: CGPoint, count: Int) -> Hit {
        let dx = p.x - c.x, dy = p.y - c.y
        let r = hypot(dx, dy)
        if r <= hub + ringGap / 2 { return .hub }
        guard count > 0, r <= outer + rim else { return .none }
        var a = atan2(dx, -dy) - rotation // 0 at top, clockwise, y down
        let span = 2 * .pi / CGFloat(count)
        a += span / 2
        a = a.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return .slice(Int(a / span) % count)
    }

    /// Centre angle of slice i.
    func angle(_ i: Int, count: Int) -> CGFloat { 2 * .pi / CGFloat(count) * CGFloat(i) + rotation }

    func labelPoint(_ i: Int, count: Int, center c: CGPoint) -> CGPoint {
        let a = angle(i, count: count), r = (inner + outer) / 2
        return CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
    }

    /// Largest corner radius that still leaves a visible wedge for `count` slices.
    func effectiveCorner(count: Int) -> CGFloat {
        let span = 2 * .pi / CGFloat(max(count, 1))
        let radial = (outer - inner) / 2 - 1
        let angular = count > 1 ? (sin(span / 2) * inner - sliceGap / 2) * 0.9 : radial
        return max(0, min(corner, radial, angular))
    }
}

/// One rounded annular wedge with straight, parallel gaps to its neighbours.
struct WedgeShape: Shape {
    let index: Int
    let count: Int
    let geo: WheelGeometry

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let cr = geo.effectiveCorner(count: count)
        // Build the wedge inset by the corner radius, then stroke it with round joins
        // at 2× radius: the union is the wedge with rounded corners.
        let rIn = geo.inner + cr, rOut = geo.outer - cr
        let d = geo.sliceGap / 2 + cr
        let span = 2 * .pi / CGFloat(max(count, 1))
        let mid = geo.angle(index, count: count)
        let a0 = mid - span / 2, a1 = mid + span / 2

        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r) }
        // Angles where a line parallel to the edge at distance d meets radius r.
        func edge(_ a: CGFloat, _ r: CGFloat, _ dir: CGFloat) -> CGFloat { a + dir * asin(min(1, d / r)) }

        var p = Path()
        if count == 1 {
            p.addEllipse(in: CGRect(x: c.x - rOut, y: c.y - rOut, width: rOut * 2, height: rOut * 2))
            p.addEllipse(in: CGRect(x: c.x - rIn, y: c.y - rIn, width: rIn * 2, height: rIn * 2))
            return p
        }
        let o0 = edge(a0, rOut, 1), o1 = edge(a1, rOut, -1)
        let i0 = edge(a0, rIn, 1), i1 = edge(a1, rIn, -1)
        guard o1 > o0 else { return p }
        // SwiftUI arcs measure from 3 o'clock; ours from 12.
        func sw(_ a: CGFloat) -> Angle { .radians(Double(a - .pi / 2)) }
        p.move(to: pt(rOut, o0))
        p.addArc(center: c, radius: rOut, startAngle: sw(o0), endAngle: sw(o1), clockwise: false)
        p.addLine(to: pt(rIn, max(i1, i0)))
        if i1 > i0 { p.addArc(center: c, radius: rIn, startAngle: sw(i1), endAngle: sw(i0), clockwise: true) }
        p.closeSubpath()
        guard cr > 0.5 else { return p }
        return p.union(p.strokedPath(StrokeStyle(lineWidth: cr * 2, lineJoin: .round)))
    }
}
