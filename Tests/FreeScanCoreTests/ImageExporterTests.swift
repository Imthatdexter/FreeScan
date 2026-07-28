import XCTest
import CoreGraphics
import ImageIO
@testable import FreeScanCore

final class ImageExporterTests: XCTestCase {

    /// The critical de-risking test: a true 16-bit image must survive a TIFF round-trip
    /// (ImageIO honoring the source `bitsPerComponent`, not silently clamping to 8-bit).
    func test16BitTIFFPreservesDepth() throws {
        let img = make16BitRamp(width: 64, height: 4)
        XCTAssertEqual(img.bitsPerComponent, 16)
        let url = tmpURL(ext: "tiff")
        try ImageExporter.write(img, to: url, format: .tiff, dpi: 300)
        let back = readFirstCGImage(url: url)
        XCTAssertNotNil(back, "Could not read TIFF back")
        XCTAssertEqual(back?.bitsPerComponent, 16, "TIFF must preserve 16-bit depth")
    }

    /// PNG 16-bit — same expectation; if ImageIO downconverts on this SDK, this test reveals it.
    func test16BitPNGPreservesDepth() throws {
        let img = make16BitRamp(width: 64, height: 4)
        let url = tmpURL(ext: "png")
        try ImageExporter.write(img, to: url, format: .png, dpi: 300)
        let back = readFirstCGImage(url: url)
        XCTAssertNotNil(back, "Could not read PNG back")
        XCTAssertEqual(back?.bitsPerComponent, 16, "PNG must preserve 16-bit depth on this SDK")
    }

    /// JPEG is 8-bit-only; a 16-bit source must be downconverted (no throw, no corruption).
    func testJPEGDownconverts16BitWithoutError() throws {
        let img = make16BitRamp(width: 16, height: 4)
        let url = tmpURL(ext: "jpg")
        XCTAssertNoThrow(try ImageExporter.write(img, to: url, format: .jpeg, dpi: 72))
        let back = readFirstCGImage(url: url)
        XCTAssertNotNil(back)
        XCTAssertEqual(back?.bitsPerComponent, 8, "JPEG must come back 8-bit")
    }

    func test8BitTIFFWritesCleanly() throws {
        let img = make8BitSolid(width: 8, height: 8, r: 200, g: 100, b: 50)
        let url = tmpURL(ext: "tiff")
        try ImageExporter.write(img, to: url, format: .tiff)
        let back = readFirstCGImage(url: url)
        XCTAssertNotNil(back)
        XCTAssertEqual(back?.bitsPerComponent, 8)
    }

    // MARK: Helpers

    private func make16BitRamp(width: Int, height: Int) -> CGImage {
        var pixels = [UInt16]()
        pixels.reserveCapacity(width * height * 3)
        for _ in 0..<height {
            for x in 0..<width {
                let v = UInt16((Double(x) / Double(max(width - 1, 1))) * 65535.0)
                pixels.append(v); pixels.append(v); pixels.append(v)
            }
        }
        let cfData = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        let provider = CGDataProvider(data: cfData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func make8BitSolid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not create 8-bit context")
        }
        ctx.setFillColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func tmpURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("freescan-test-\(UUID().uuidString).\(ext)")
    }

    private func readFirstCGImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
