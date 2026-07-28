import XCTest
import CoreGraphics
@testable import FreeScanCore

final class CropMathTests: XCTestCase {

    func testInchesPerPixel() {
        let s = CropMath.inchesPerPixel(
            overviewPixelSize: CGSize(width: 1000, height: 1500),
            physicalSize: CGSize(width: 1.0, height: 1.5)
        )
        XCTAssertEqual(s.width, 0.001, accuracy: 1e-9)
        XCTAssertEqual(s.height, 0.001, accuracy: 1e-9)
    }

    func testPixelToInches() {
        let pixel = CGRect(x: 100, y: 150, width: 200, height: 300)
        let inches = CropMath.inches(
            fromPixelRect: pixel,
            overviewPixelSize: CGSize(width: 1000, height: 1500),
            physicalSize: CGSize(width: 1.0, height: 1.5)
        )
        XCTAssertEqual(inches.origin.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(inches.origin.y, 0.1, accuracy: 1e-9)   // 150 px * (1.5/1500) = 0.15
        XCTAssertEqual(inches.origin.y, 0.15, accuracy: 1e-9)
        XCTAssertEqual(inches.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(inches.height, 0.3, accuracy: 1e-9)
    }

    func testInchesPixelRoundTrip() {
        let original = CGRect(x: 250, y: 333, width: 421, height: 99)
        let pixelSize = CGSize(width: 1200, height: 1800)
        let physical = CGSize(width: 1.0, height: 1.5)
        let inches = CropMath.inches(fromPixelRect: original, overviewPixelSize: pixelSize, physicalSize: physical)
        let back = CropMath.pixel(fromInchRect: inches, overviewPixelSize: pixelSize, physicalSize: physical)
        XCTAssertEqual(back.origin.x, original.origin.x, accuracy: 1e-6)
        XCTAssertEqual(back.origin.y, original.origin.y, accuracy: 1e-6)
        XCTAssertEqual(back.width, original.width, accuracy: 1e-6)
        XCTAssertEqual(back.height, original.height, accuracy: 1e-6)
    }

    func testViewPixelRoundTrip() {
        let pixelSize = CGSize(width: 1000, height: 1500)
        let displayed = CGSize(width: 500, height: 750)   // 0.5 scale
        let view = CGRect(x: 50, y: 75, width: 100, height: 150)
        let px = CropMath.pixel(fromViewRect: view, imagePixelSize: pixelSize, displayedSize: displayed)
        XCTAssertEqual(px.origin.x, 100, accuracy: 1e-6)
        XCTAssertEqual(px.origin.y, 150, accuracy: 1e-6)
        let back = CropMath.view(fromPixelRect: px, imagePixelSize: pixelSize, displayedSize: displayed)
        XCTAssertEqual(back, view, accuracy: 1e-6)
    }

    func testViewToInchesFullPipeline() {
        let inches = CropMath.inches(
            fromViewRect: CGRect(x: 100, y: 150, width: 200, height: 300),
            imagePixelSize: CGSize(width: 1000, height: 1500),
            displayedSize: CGSize(width: 500, height: 750),    // 0.5 scale → 200 view px = 400 image px
            physicalSize: CGSize(width: 1.0, height: 1.5)      // 400 px → 0.4 in
        )
        XCTAssertEqual(inches.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(inches.height, 0.6, accuracy: 1e-9)
    }

    func testClampedRectRespectsBoundsAndMinSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
        let r = CropMath.clamped(CGRect(x: -0.5, y: -0.5, width: 5, height: 5), to: bounds, minSize: 0.1)
        XCTAssertEqual(r.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.origin.y, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(r.maxX, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(r.maxY, 1.0 + 1e-9)
        XCTAssertGreaterThanOrEqual(r.width, 0.1)
        XCTAssertGreaterThanOrEqual(r.height, 0.1)
    }
}
