import Foundation
import CoreImage
import simd

/// Per-channel end points used to convert a color negative to a positive, derived from the
/// film base (orange mask) `Dmin` and the clearest-exposed area `Dmax`. Values are in linear
/// light, normalized to [0, 1].
public struct ColorNegativeLevels: Hashable, Sendable {
    public var dmin: SIMD3<Float>
    public var dmax: SIMD3<Float>

    public init(dmin: SIMD3<Float>, dmax: SIMD3<Float>) {
        self.dmin = dmin
        self.dmax = dmax
    }

    public static let neutral = ColorNegativeLevels(
        dmin: SIMD3<Float>(0, 0, 0),
        dmax: SIMD3<Float>(1, 1, 1)
    )
}

/// Negative → positive conversion.
///
/// Color negatives: in **linear light**, per-channel normalize
///   `norm = (neg - Dmin) / (Dmax - Dmin)` then invert `1 - norm`.
/// Subtracting `Dmin` per channel removes the orange mask's offset and equalizes black points;
/// dividing by `(Dmax - Dmin)` equalizes white points. A plain invert then yields a neutral
/// positive. (The math must run in linear light — doing `1 - x` in gamma space distorts
/// midtones — which is why the CI pipeline runs in a linear working color space.)
///
/// B&W negatives: straight invert, with contrast/gamma left to the tone curve.
public enum NegativeInversion {

    /// Convert a single linear-light color-negative RGB sample (each channel in [0,1]) to a
    /// positive. Channels are normalized independently.
    public static func invertColor(_ neg: SIMD3<Float>, levels: ColorNegativeLevels) -> SIMD3<Float> {
        var out = SIMD3<Float>.zero
        for c in 0..<3 {
            let span = max(levels.dmax[c] - levels.dmin[c], 1e-5)
            let norm = (neg[c] - levels.dmin[c]) / span
            out[c] = 1 - min(max(norm, 0), 1)
        }
        return out
    }

    /// Convert a linear-light B&W-negative luminance sample to a positive.
    public static func invertGray(_ neg: Float) -> Float {
        1 - min(max(neg, 0), 1)
    }

    // MARK: Deriving levels from a histogram

    /// Estimate `Dmin` / `Dmax` per channel from 256-bin per-channel histograms of the (linear)
    /// prescan, using low/high pixel-count percentiles to stay robust against dust and outliers.
    ///
    /// - Parameters:
    ///   - r/g/b: per-channel 256-bin counts.
    ///   - lowFraction: fraction of total pixels below `Dmin` (default ~0.1%).
    ///   - highFraction: fraction of total pixels above `Dmax` (default ~0.1%).
    /// - Returns: levels in [0,1] per channel; `.neutral` if a channel is empty.
    public static func levels(
        fromHistograms r: [UInt], _ g: [UInt], _ b: [UInt],
        lowFraction: Float = 0.001,
        highFraction: Float = 0.001
    ) -> ColorNegativeLevels {
        precondition(r.count == 256 && g.count == 256 && b.count == 256,
                     "Histograms must be 256 bins")
        let re = channelEnds(r, lowFraction: lowFraction, highFraction: highFraction)
        let ge = channelEnds(g, lowFraction: lowFraction, highFraction: highFraction)
        let be = channelEnds(b, lowFraction: lowFraction, highFraction: highFraction)
        return ColorNegativeLevels(
            dmin: SIMD3<Float>(re.min, ge.min, be.min),
            dmax: SIMD3<Float>(re.max, ge.max, be.max)
        )
    }

    /// Single (luminance) end-points applied uniformly to all channels — used for B&W, where the
    /// whole image should be stretched as one tone rather than per-channel.
    public static func luminanceLevels(
        fromHistogram hist: [UInt],
        lowFraction: Float = 0.001,
        highFraction: Float = 0.001
    ) -> ColorNegativeLevels {
        precondition(hist.count == 256, "Histogram must be 256 bins")
        let e = channelEnds(hist, lowFraction: lowFraction, highFraction: highFraction)
        return ColorNegativeLevels(
            dmin: SIMD3<Float>(repeating: e.min),
            dmax: SIMD3<Float>(repeating: e.max)
        )
    }

    private static func channelEnds(
        _ hist: [UInt], lowFraction: Float, highFraction: Float
    ) -> (min: Float, max: Float) {
        let total = hist.reduce(UInt(0), +)
        guard total > 0 else { return (0, 1) }
        let lowTarget = Float(total) * lowFraction
        let highTarget = Float(total) * (1 - highFraction)
        var acc: Float = 0
        var lo: Float = 0
        var hi: Float = 1
        var seenLow = false
        for (i, count) in hist.enumerated() {
            acc += Float(count)
            let v = Float(i) / 255
            if !seenLow && acc >= lowTarget { lo = v; seenLow = true }
            if acc <= highTarget { hi = v }
        }
        return (lo, max(hi, lo + 1.0 / 255))
    }

    // MARK: Core Image pipeline

    /// Build a CIImage pipeline that performs the per-channel normalize + invert. Uses stock
    /// `CIColorMatrix` (per-channel scale + bias) then `CIColorInvert`. Must run in a **gamma sRGB**
    /// working space (as FilmProcessing sets) so the matrix's Dmin/Dmax thresholds — which come from
    /// a gamma-encoded histogram — match the pixel values.
    public static func colorNegativePipeline(_ input: CIImage, levels: ColorNegativeLevels) -> CIImage {
        // norm = neg * scale - bias, where scale = 1/(Dmax-Dmin), bias = Dmin/(Dmax-Dmin).
        let scaleR = 1 / max(levels.dmax.x - levels.dmin.x, 1e-5)
        let scaleG = 1 / max(levels.dmax.y - levels.dmin.y, 1e-5)
        let scaleB = 1 / max(levels.dmax.z - levels.dmin.z, 1e-5)
        let biasR = -levels.dmin.x * scaleR
        let biasG = -levels.dmin.y * scaleG
        let biasB = -levels.dmin.z * scaleB

        let scaled = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scaleR), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scaleG), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scaleB), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: CGFloat(biasR), y: CGFloat(biasG), z: CGFloat(biasB), w: 0),
        ])
        // 1 - normalized.
        return scaled.applyingFilter("CIColorInvert")
    }

    /// B&W pipeline: desaturate to luminance (removing any color cast — e.g. a warm TPU lamp or a
    /// color negative's orange base if color film is scanned in B&W mode), then invert.
    public static func blackAndWhitePipeline(_ input: CIImage) -> CIImage {
        let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        return gray.applyingFilter("CIColorInvert")
    }
}
