import XCTest
@testable import FreeScanCore

final class ToneCurveTests: XCTestCase {

    func testIdentityCurveIsLinear() {
        let curve = ToneCurve.identity
        XCTAssertEqual(curve.value(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 0.25), 0.25, accuracy: 1e-6)
    }

    func testIdentityPassesThroughEndpoints() {
        // A curve with explicit 0 and 1 endpoints and a mid lift should still hit the endpoints.
        let curve = ToneCurve(points: [
            ToneCurvePoint(input: 0, output: 0),
            ToneCurvePoint(input: 0.5, output: 0.6),
            ToneCurvePoint(input: 1, output: 1),
        ])
        XCTAssertEqual(curve.value(at: 0), 0, accuracy: 1e-5)
        XCTAssertEqual(curve.value(at: 1), 1, accuracy: 1e-5)
        XCTAssertEqual(curve.value(at: 0.5), 0.6, accuracy: 1e-5)   // spline passes through points
    }

    func testDefaultContrastIsMonotonic() {
        let lut = ToneCurve.defaultContrast.lut(count: 256)
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(lut.last!, 1, accuracy: 1e-6)
        // Monotonically non-decreasing.
        for i in 1..<lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1] - 1e-6, "LUT not monotonic at \(i)")
        }
    }

    func testClampsOutOfRangeInput() {
        let curve = ToneCurve.identity
        XCTAssertEqual(curve.value(at: -0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 1.5), 1, accuracy: 1e-6)
    }

    func testColorCubeDataShapeAndCorners() {
        let data = ToneCurve.colorCubeData(dimension: 2, master: .identity)
        // 2×2×2 texels × 4 floats = 32 entries. Cube is indexed [b][g][r], r fastest.
        XCTAssertEqual(data.count, 32)
        // First texel (b=0,g=0,r=0): identity outputs (0,0,0,1).
        XCTAssertEqual(data[0], 0, accuracy: 1e-6)
        XCTAssertEqual(data[1], 0, accuracy: 1e-6)
        XCTAssertEqual(data[2], 0, accuracy: 1e-6)
        XCTAssertEqual(data[3], 1, accuracy: 1e-6)
        // Last texel (b=1,g=1,r=1) at offset 28: (1,1,1,1).
        XCTAssertEqual(data[28], 1, accuracy: 1e-6)
        XCTAssertEqual(data[29], 1, accuracy: 1e-6)
        XCTAssertEqual(data[30], 1, accuracy: 1e-6)
        XCTAssertEqual(data[31], 1, accuracy: 1e-6)
    }

    func testPerChannelCurveOverridesMaster() {
        // Master = identity, but red channel inverted; green/blue follow master.
        let red = ToneCurve(points: [ToneCurvePoint(input: 0, output: 1), ToneCurvePoint(input: 1, output: 0)])
        let data = ToneCurve.colorCubeData(dimension: 2, master: .identity, r: red)
        // Corner (r=0,g=0,b=0): red uses red curve → 1, green→0, blue→0.
        XCTAssertEqual(data[0], 1, accuracy: 1e-6)   // R out
        XCTAssertEqual(data[1], 0, accuracy: 1e-6)   // G out
        XCTAssertEqual(data[2], 0, accuracy: 1e-6)   // B out
    }
}
