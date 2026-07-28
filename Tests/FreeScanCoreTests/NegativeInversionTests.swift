import XCTest
import simd
@testable import FreeScanCore

final class NegativeInversionTests: XCTestCase {

    func testInvertColorNeutralLevels() {
        // With Dmin=0, Dmax=1, normalize is identity → pure invert.
        let levels = ColorNegativeLevels.neutral
        let pos = NegativeInversion.invertColor(SIMD3<Float>(0.2, 0.5, 0.8), levels: levels)
        XCTAssertEqual(pos.x, 0.8, accuracy: 1e-5)
        XCTAssertEqual(pos.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(pos.z, 0.2, accuracy: 1e-5)
    }

    func testInvertColorWithMaskRemoval() {
        // Dmin removes the orange offset; mid-gray negative should map near mid-gray positive.
        let levels = ColorNegativeLevels(
            dmin: SIMD3<Float>(0.1, 0.1, 0.1),
            dmax: SIMD3<Float>(0.9, 0.9, 0.9)
        )
        // neg=0.5 → norm = (0.5-0.1)/0.8 = 0.5 → pos = 0.5
        let pos = NegativeInversion.invertColor(SIMD3<Float>(0.5, 0.5, 0.5), levels: levels)
        XCTAssertEqual(pos.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(pos.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(pos.z, 0.5, accuracy: 1e-4)
    }

    func testInvertColorClampsOutOfRange() {
        let levels = ColorNegativeLevels(
            dmin: SIMD3<Float>(0.2, 0.2, 0.2),
            dmax: SIMD3<Float>(0.8, 0.8, 0.8)
        )
        // neg below Dmin → norm<0 → clamped to 0 → pos=1 (white)
        let hi = NegativeInversion.invertColor(SIMD3<Float>(0.0, 0.0, 0.0), levels: levels)
        XCTAssertEqual(hi.x, 1.0, accuracy: 1e-5)
        // neg above Dmax → norm>1 → clamped to 1 → pos=0 (black)
        let lo = NegativeInversion.invertColor(SIMD3<Float>(1.0, 1.0, 1.0), levels: levels)
        XCTAssertEqual(lo.x, 0.0, accuracy: 1e-5)
    }

    func testInvertGray() {
        XCTAssertEqual(NegativeInversion.invertGray(0.25), 0.75, accuracy: 1e-6)
        XCTAssertEqual(NegativeInversion.invertGray(0.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(NegativeInversion.invertGray(1.0), 0.0, accuracy: 1e-6)
    }

    func testLevelsFromHistograms() {
        // Red channel mass concentrated in bins 10…20 → Dmin≈10/255, Dmax≈20/255.
        var r = [UInt](repeating: 0, count: 256)
        for i in 10...20 { r[i] = 100 }
        let g = r, b = r

        let levels = NegativeInversion.levels(fromHistograms: r, g, b)
        XCTAssertEqual(levels.dmin.x, 10.0 / 255.0, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(levels.dmax.x, levels.dmin.x)
        XCTAssertLessThanOrEqual(levels.dmax.x, 21.0 / 255.0)
    }

    func testLevelsEmptyChannelIsNeutral() {
        let empty = [UInt](repeating: 0, count: 256)
        let levels = NegativeInversion.levels(fromHistograms: empty, empty, empty)
        XCTAssertEqual(levels.dmin.x, 0)
        XCTAssertEqual(levels.dmax.x, 1)
    }
}
