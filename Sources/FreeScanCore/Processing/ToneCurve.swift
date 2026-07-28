import Foundation
import CoreImage

/// A control point on a tone curve. Both axes are normalized to [0, 1].
public struct ToneCurvePoint: Hashable, Sendable {
    public var input: Float
    public var output: Float
    public init(input: Float, output: Float) { self.input = input; self.output = output }
}

/// A user-editable tone curve: a Catmull-Rom spline through control points, sampled into a
/// 1D LUT (256 entries for the 8-bit preview, up to 65536 for an accurate 16-bit pass) and
/// embeddable into a Core Image `CIColorCube` so it can be applied per channel without losing
/// precision (the cube data is 32-bit float).
///
/// `CIToneCurve` is intentionally not used: it supports only 5 fixed points and forces a
/// gamma-2 working space. Building our own spline + LUT keeps the curve exact at 16-bit.
public struct ToneCurve: Hashable, Sendable {

    /// Control points sorted ascending by input. Should bracket [0, 1] for a clean curve;
    /// endpoints are clamped if missing.
    public var points: [ToneCurvePoint]

    public init(points: [ToneCurvePoint]) {
        self.points = points.sorted { $0.input < $1.input }
    }

    /// The identity curve (input == output).
    public static var identity: ToneCurve {
        ToneCurve(points: [ToneCurvePoint(input: 0, output: 0), ToneCurvePoint(input: 1, output: 1)])
    }

    /// A gentle S-curve (raised contrast) for a sensible default.
    public static var defaultContrast: ToneCurve {
        ToneCurve(points: [
            ToneCurvePoint(input: 0.00, output: 0.00),
            ToneCurvePoint(input: 0.25, output: 0.18),
            ToneCurvePoint(input: 0.50, output: 0.50),
            ToneCurvePoint(input: 0.75, output: 0.82),
            ToneCurvePoint(input: 1.00, output: 1.00),
        ])
    }

    /// Evaluate the curve at `t` (clamped to the points' input range). Uniform Catmull-Rom with
    /// clamped boundary tangents (endpoints duplicated) so the curve passes through every point.
    public func value(at t: Float) -> Float {
        let pts = points
        guard pts.count >= 2 else { return pts.first?.output ?? t }

        let firstIn = pts.first!.input
        let lastIn = pts.last!.input
        let x = min(max(t, firstIn), lastIn)

        // Find the segment [seg, seg+1] containing x.
        var seg = 0
        for i in 0..<(pts.count - 1) {
            if x >= pts[i].input && x <= pts[i + 1].input { seg = i; break }
            if i == pts.count - 2 { seg = i }
        }

        let p0 = pts[max(0, seg - 1)]
        let p1 = pts[seg]
        let p2 = pts[seg + 1]
        let p3 = pts[min(pts.count - 1, seg + 2)]

        let span = p2.input - p1.input
        let local: Float = span > 0 ? (x - p1.input) / span : 0
        let l2 = local * local
        let l3 = l2 * local

        // Catmull-Rom basis (tension 0.5).
        let v = 0.5 * (
            (2 * p1.output) +
            (-p0.output + p2.output) * local +
            (2 * p0.output - 5 * p1.output + 4 * p2.output - p3.output) * l2 +
            (-p0.output + 3 * p1.output - 3 * p2.output + p3.output) * l3
        )
        return min(max(v, 0), 1)
    }

    /// Sample the spline into a flat LUT of `count` Float entries in [0, 1].
    public func lut(count: Int = 256) -> [Float] {
        guard count > 1 else { return [value(at: 0)] }
        return (0..<count).map { i -> Float in
            let t = Float(i) / Float(count - 1)
            return value(at: t)
        }
    }

    /// Build a `CIColorCube`-compatible Float32 RGBA data blob (premultiplied; alpha 1 → identity
    /// premultiplication) from a master curve and optional per-channel curves. Cube is indexed
    /// `[b][g][r]` with R varying fastest, matching Core Image's expected layout.
    ///
    /// Channel semantics: if a per-channel curve is supplied it overrides the master for that
    /// channel; channels without one fall back to the master.
    public static func colorCubeData(
        dimension: Int = 64,
        master: ToneCurve = .identity,
        r: ToneCurve? = nil,
        g: ToneCurve? = nil,
        b: ToneCurve? = nil
    ) -> [Float] {
        precondition((2...128).contains(dimension), "CIColorCube dimension must be 2...128")
        var data = [Float]()
        data.reserveCapacity(dimension * dimension * dimension * 4)
        let last = Float(dimension - 1)
        for bIdx in 0..<dimension {
            for gIdx in 0..<dimension {
                for rIdx in 0..<dimension {
                    let ri = Float(rIdx) / last
                    let gi = Float(gIdx) / last
                    let bi = Float(bIdx) / last
                    let ro = (r ?? master).value(at: ri)
                    let go = (g ?? master).value(at: gi)
                    let bo = (b ?? master).value(at: bi)
                    data.append(ro)
                    data.append(go)
                    data.append(bo)
                    data.append(1.0)
                }
            }
        }
        return data
    }
}
