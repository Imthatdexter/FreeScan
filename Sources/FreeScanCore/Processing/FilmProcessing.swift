import Foundation
import CoreGraphics
import CoreImage

/// End-to-end film processing: assemble the negative→positive pipeline (inversion + tone curve)
/// and render it to a `CGImage` at the requested bit depth. All color math runs in **linear sRGB**
/// (via the shared context's working color space), with the curve applied through a 32-bit-float
/// `CIColorCube` so precision survives at 16-bit.
public enum FilmProcessing {

    /// Shared CI context. Process in **sRGB (gamma) space**, NOT linear: the scanned image and the
    /// histogram-derived levels (Dmin/Dmax) are both gamma-encoded sRGB, so the per-channel matrix
    /// must run in gamma space to match. (Running it in a linear working space mismatched the
    /// gamma thresholds and clamped most pixels to white.) This is the gamma-space scantips
    /// "Levels" method. Half-float working format keeps precision.
    public static let context: CIContext = {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: cs,
            .workingFormat: CIFormat.RGBAh,
        ])
    }()

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Build the processed (positive) `CIImage` for the given film type and tone curve.
    /// `levels` (Dmin/Dmax) is required for color negatives; pass nil to use neutral end points.
    public static func pipeline(
        _ input: CIImage,
        filmType: FilmType,
        levels: ColorNegativeLevels?,
        curve: ToneCurve,
        invert: Bool = true
    ) -> CIImage {
        var img = input
        if invert && filmType.requiresInversion {
            switch filmType {
            case .colorNegative:
                // Per-channel normalize (removes the orange mask + sets white/black points), then invert.
                img = NegativeInversion.colorNegativePipeline(img, levels: levels ?? .neutral)
            case .blackAndWhiteNegative:
                // Desaturate, then a uniform luminance levels stretch + invert.
                let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                img = NegativeInversion.colorNegativePipeline(gray, levels: levels ?? .neutral)
            case .positive:
                break
            }
        } else if filmType == .blackAndWhiteNegative {
            // Not inverting (e.g. the driver already delivered a positive); still desaturate to a
            // neutral grayscale before the curve.
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        }
        // Apply the tone curve through a 64³ 32-bit-float cube in sRGB (matches the working space).
        let floats = ToneCurve.colorCubeData(dimension: 64, master: curve)
        let cubeData = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeData": cubeData,
            "inputCubeDimension": 64,
            "inputColorSpace": sRGB,
        ])
        return img
    }

    /// Auto-compute levels from an image's own histogram: per-channel for color negatives
    /// (orange-mask removal), or a single luminance stretch for B&W. Deriving levels from the
    /// image being processed — not a different one (e.g. the prescan) — keeps the tonal mapping
    /// correct even when the final scan is exposed differently from the overview.
    public static func autoLevels(for filmType: FilmType, from image: CGImage) -> ColorNegativeLevels? {
        guard let hist = HistogramComputation.compute(from: image) else { return nil }
        return filmType == .colorNegative
            ? NegativeInversion.levels(fromHistograms: hist.red, hist.green, hist.blue)
            : NegativeInversion.luminanceLevels(fromHistogram: hist.green)
    }

    /// Render a `CIImage` to a `CGImage` at the requested bit depth (8 or 16 bits/channel),
    /// in sRGB. Returns nil on failure.
    public static func render(_ ci: CIImage, bitsPerComponent: Int) -> CGImage? {
        let format: CIFormat = bitsPerComponent >= 16 ? .RGBA16 : .RGBA8
        return context.createCGImage(ci, from: ci.extent, format: format, colorSpace: sRGB)
    }

    /// Convenience: process then render in one call.
    public static func processAndRender(
        _ input: CGImage,
        filmType: FilmType,
        levels: ColorNegativeLevels?,
        curve: ToneCurve,
        bitsPerComponent: Int,
        invert: Bool = true
    ) -> CGImage? {
        let ci = CIImage(cgImage: input, options: [.colorSpace: sRGB])
        let processed = pipeline(ci, filmType: filmType, levels: levels, curve: curve, invert: invert)
        return render(processed, bitsPerComponent: bitsPerComponent)
    }
}
