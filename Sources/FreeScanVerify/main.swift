import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import FreeScanCore

/// CLT-runnable self-checks for FreeScanCore (the XCTest suite needs full Xcode; this mirrors the
/// same assertions so the logic can be verified with only the Command Line Tools).
///
/// Run: `swift run FreeScanVerify`

@main
struct FreeScanVerify {
    static func main() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  ✓ \(name)")
                passed += 1
            } else {
                print("  ✗ \(name)  \(detail)")
                failed += 1
            }
        }

        print("ToneCurve")
        check("identity is linear", ToneCurve.identity.value(at: 0.5) ~== (0.5, 1e-6))
        check("identity endpoints", ToneCurve.identity.value(at: 0) ~== (0, 1e-6) && ToneCurve.identity.value(at: 1) ~== (1, 1e-6))
        check("passes through control points",
              curve3Points().value(at: 0.5) ~== (0.6, 1e-5))
        check("default contrast monotonic", isMonotonic(ToneCurve.defaultContrast.lut(count: 256)))
        check("clamps out-of-range", ToneCurve.identity.value(at: -0.5) ~== (0, 1e-6) && ToneCurve.identity.value(at: 1.5) ~== (1, 1e-6))
        check("colorCube shape (2³×4=32)", ToneCurve.colorCubeData(dimension: 2).count == 32)
        check("colorCube black corner", cubeCorner(dimension: 2, at: 0) ~== ([0, 0, 0, 1], 1e-6))
        check("colorCube white corner", cubeCorner(dimension: 2, at: 28) ~== ([1, 1, 1, 1], 1e-6))

        print("NegativeInversion")
        let neutral = ColorNegativeLevels.neutral
        check("invert neutral (0.2,0.5,0.8)→(0.8,0.5,0.2)",
              approx(NegativeInversion.invertColor(SIMD3<Float>(0.2, 0.5, 0.8), levels: neutral), [0.8, 0.5, 0.2], 1e-5))
        let masked = ColorNegativeLevels(dmin: SIMD3<Float>(0.1, 0.1, 0.1), dmax: SIMD3<Float>(0.9, 0.9, 0.9))
        check("mid-gray negative → 0.5 with mask removal",
              approx(NegativeInversion.invertColor(SIMD3<Float>(0.5, 0.5, 0.5), levels: masked), [0.5, 0.5, 0.5], 1e-4))
        check("below Dmin clamps to white",
              approx(NegativeInversion.invertColor(SIMD3<Float>(0, 0, 0), levels: masked), [1, 1, 1], 1e-5))
        check("above Dmax clamps to black",
              approx(NegativeInversion.invertColor(SIMD3<Float>(1, 1, 1), levels: masked), [0, 0, 0], 1e-5))
        check("invertGray(0.25)=0.75", NegativeInversion.invertGray(0.25) ~== (0.75, 1e-6))
        let (r, g, b) = rampHistogram()
        let lv = NegativeInversion.levels(fromHistograms: r, g, b)
        check("levels Dmin≈10/255 from histogram", lv.dmin.x ~== (10.0 / 255.0, 1e-6))

        print("CropMath")
        let ipp = CropMath.inchesPerPixel(overviewPixelSize: CGSize(width: 1000, height: 1500), physicalSize: CGSize(width: 1, height: 1.5))
        check("inchesPerPixel", ipp.width ~== (0.001, 1e-9) && ipp.height ~== (0.001, 1e-9))
        let inchRect = CropMath.inches(fromPixelRect: CGRect(x: 100, y: 150, width: 200, height: 300),
                                       overviewPixelSize: CGSize(width: 1000, height: 1500),
                                       physicalSize: CGSize(width: 1, height: 1.5))
        check("pixel→inches", inchRect.origin.x ~== (0.1, 1e-9) && inchRect.width ~== (0.2, 1e-9) && inchRect.height ~== (0.3, 1e-9))
        let back = CropMath.pixel(fromInchRect: inchRect, overviewPixelSize: CGSize(width: 1000, height: 1500), physicalSize: CGSize(width: 1, height: 1.5))
        check("inch→pixel round-trip", back.origin.x ~== (100, 1e-6) && back.width ~== (200, 1e-6))
        let vp = CropMath.pixel(fromViewRect: CGRect(x: 50, y: 75, width: 100, height: 150),
                                imagePixelSize: CGSize(width: 1000, height: 1500), displayedSize: CGSize(width: 500, height: 750))
        check("view→pixel (0.5 scale)", vp.origin.x ~== (100, 1e-6) && vp.width ~== (200, 1e-6))

        print("ImageExporter (16-bit round-trip — the critical de-risk)")
        let ramp = make16BitRamp(width: 64, height: 4)
        check("16-bit ramp created", ramp.bitsPerComponent == 16)
        if let tiff = roundTrip(ramp, ext: "tiff", format: .tiff) {
            check("16-bit TIFF preserves depth", tiff.bitsPerComponent == 16)
        } else {
            check("16-bit TIFF round-trip", false, "no image returned")
        }
        if let png = roundTrip(ramp, ext: "png", format: .png) {
            check("16-bit PNG preserves depth on this SDK", png.bitsPerComponent == 16)
        } else {
            check("16-bit PNG round-trip", false, "no image returned")
        }
        do {
            let jpgURL = tmpURL(ext: "jpg")
            try ImageExporter.write(ramp, to: jpgURL, format: .jpeg, dpi: 72)
            let jpg = readFirstCGImage(url: jpgURL)
            check("16-bit → JPEG downconverts to 8-bit (no error)", jpg?.bitsPerComponent == 8)
        } catch {
            check("16-bit → JPEG", false, "\(error)")
        }

        print("Histogram (vImage ARGB→RGB mapping)")
        let solid = make8BitSolid(width: 2, height: 2, r: 255, g: 0, b: 0)
        if let h = HistogramComputation.compute(from: solid) {
            // 2×2 = 4 pixels. Red should be entirely in bin 255; green/blue in bin 0.
            check("red bin 255 == 4", h.red[255] == 4)
            check("green bin 0 == 4", h.green[0] == 4)
            check("blue bin 0 == 4", h.blue[0] == 4)
        } else {
            check("histogram computation", false, "returned nil")
        }

        print("FilmProcessing pipeline")
        // 16-bit render must preserve depth.
        let rampCI = CIImage(cgImage: ramp, options: [:])
        if let rendered16 = FilmProcessing.render(rampCI, bitsPerComponent: 16) {
            check("16-bit render preserves depth", rendered16.bitsPerComponent == 16,
                  "got \(rendered16.bitsPerComponent)")
        } else {
            check("16-bit render preserves depth", false, "render returned nil")
        }
        // A bright negative should invert to a (substantially) darker positive. The pipeline
        // inverts in LINEAR light, so the exact value differs from a naive sRGB 1-x; what matters
        // is that inversion made it darker. Compare against the same image run as a positive.
        let brightNeg = make8BitSolid(width: 8, height: 8, r: 220, g: 220, b: 220)
        let positiveGray = FilmProcessing.processAndRender(brightNeg, filmType: .positive,
                                                           levels: nil, curve: .identity,
                                                           bitsPerComponent: 8).flatMap(centerGray)
        let invertedGray = FilmProcessing.processAndRender(brightNeg, filmType: .blackAndWhiteNegative,
                                                            levels: nil, curve: .identity,
                                                            bitsPerComponent: 8).flatMap(centerGray)
        if let p = positiveGray, let i = invertedGray {
            check("B&W invert darkens the image (linear-light)", i < p - 40,
                  "positive=\(p) inverted=\(i)")
        } else {
            check("B&W pipeline renders", false)
        }

        // Color-negative pipeline must ALSO invert (bright "negative" → dark positive).
        let colorInverted = FilmProcessing.processAndRender(brightNeg, filmType: .colorNegative,
                                                             levels: .neutral, curve: .identity,
                                                             bitsPerComponent: 8).flatMap(centerGray)
        if let g = colorInverted {
            check("color-negative inverts (bright→dark)", g < 100, "gray=\(g)")
        } else {
            check("color-negative pipeline renders", false)
        }

        print("")
        print("Passed: \(passed)   Failed: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: helpers

    private static func curve3Points() -> ToneCurve {
        ToneCurve(points: [ToneCurvePoint(input: 0, output: 0),
                           ToneCurvePoint(input: 0.5, output: 0.6),
                           ToneCurvePoint(input: 1, output: 1)])
    }

    private static func isMonotonic(_ lut: [Float]) -> Bool {
        guard lut.count > 1 else { return true }
        for i in 1..<lut.count where lut[i] < lut[i - 1] - 1e-6 { return false }
        return true
    }

    private static func cubeCorner(dimension: Int, at offset: Int) -> [Float] {
        let d = ToneCurve.colorCubeData(dimension: dimension)
        return [d[offset], d[offset + 1], d[offset + 2], d[offset + 3]]
    }

    private static func rampHistogram() -> ([UInt], [UInt], [UInt]) {
        var r = [UInt](repeating: 0, count: 256)
        for i in 10...20 { r[i] = 100 }
        return (r, r, r)
    }

    private static func approx(_ a: SIMD3<Float>, _ b: [Float], _ eps: Float) -> Bool {
        guard b.count == 3 else { return false }
        return abs(a.x - b[0]) <= eps && abs(a.y - b[1]) <= eps && abs(a.z - b[2]) <= eps
    }

    private static func make16BitRamp(width: Int, height: Int) -> CGImage {
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
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
                       bytesPerRow: width * 6, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func make8BitSolid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private static func roundTrip(_ image: CGImage, ext: String, format: OutputFormat) -> CGImage? {
        let url = tmpURL(ext: ext)
        do {
            try ImageExporter.write(image, to: url, format: format)
        } catch {
            return nil
        }
        return readFirstCGImage(url: url)
    }

    private static func tmpURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("freescan-verify-\(UUID().uuidString).\(ext)")
    }

    private static func readFirstCGImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Average luminance of the center pixel of `image` (0–255), via an 8-bit context.
    private static func centerGray(_ image: CGImage) -> Int? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = w / 2, cy = h / 2
        let i = (cy * bytesPerRow) + (cx * 4)
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        return (r + g + b) / 3
    }
}

// Tolerance comparison sugar for Float / CGFloat.
infix operator ~==: ComparisonPrecedence
func ~== (lhs: Float, rhs: (Float, Float)) -> Bool { abs(lhs - rhs.0) <= rhs.1 }
func ~== (lhs: CGFloat, rhs: (CGFloat, CGFloat)) -> Bool { abs(lhs - rhs.0) <= rhs.1 }
func ~== (lhs: [Float], rhs: ([Float], Float)) -> Bool {
    guard lhs.count == rhs.0.count else { return false }
    return zip(lhs, rhs.0).allSatisfy { abs($0 - $1) <= rhs.1 }
}
