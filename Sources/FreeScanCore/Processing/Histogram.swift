import Foundation
import CoreGraphics
import Accelerate

/// Per-channel 256-bin histogram of an image, plus the derived min/max bin (used for
/// auto-levels / `ColorNegativeLevels`). Computed via vImage for speed.
public struct Histogram: Sendable, Hashable {
    public static let binCount = 256
    public let red: [UInt]
    public let green: [UInt]
    public let blue: [UInt]

    public init(red: [UInt], green: [UInt], blue: [UInt]) {
        precondition(red.count == Histogram.binCount && green.count == Histogram.binCount && blue.count == Histogram.binCount)
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var totalCount: UInt { red.reduce(0, +) + green.reduce(0, +) + blue.reduce(0, +) }

    /// First non-empty bin (clamped to 255). -1 if the channel is entirely empty.
    public static func firstNonZero(_ channel: [UInt]) -> Int {
        channel.firstIndex { $0 > 0 } ?? -1
    }

    /// Last non-empty bin (clamped to 0). -1 if the channel is entirely empty.
    public static func lastNonZero(_ channel: [UInt]) -> Int {
        channel.lastIndex { $0 > 0 } ?? -1
    }
}

public enum HistogramComputation {

    /// Compute a per-channel histogram from a `CGImage`. The image is drawn into an 8-bit ARGB
    /// buffer and counted with `vImageHistogramCalculation_ARGB8888` (always 256 bins/channel).
    /// For a 16-bit source the 8-bit buffer still yields a visually correct histogram.
    public static func compute(from cgImage: CGImage) -> Histogram? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        // premultipliedFirst → byte order A,R,G,B, which matches vImage's ARGB8888 channel order.
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixels.withUnsafeMutableBufferPointer { pxPtr -> Histogram? in
            guard let base = pxPtr.baseAddress else { return nil }
            var buffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(base),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )

            // 4 channels × 256 bins. ARGB8888 channel order is fixed: [A, R, G, B].
            var counts = [vImagePixelCount](repeating: 0, count: 4 * 256)
            let error: vImage_Error = counts.withUnsafeMutableBufferPointer { countsPtr in
                guard let cbase = countsPtr.baseAddress else { return kvImageInvalidParameter }
                var channelPtrs: [UnsafeMutablePointer<vImagePixelCount>?] = (0..<4).map { cbase.advanced(by: $0 * 256) }
                return channelPtrs.withUnsafeMutableBufferPointer { ptrsPtr -> vImage_Error in
                    guard let ptrsBase = ptrsPtr.baseAddress else { return kvImageInvalidParameter }
                    return vImageHistogramCalculation_ARGB8888(&buffer, ptrsBase, vImage_Flags(kvImageNoFlags))
                }
            }
            guard error == kvImageNoError else { return nil }

            // Map [A, R, G, B] → (R, G, B).
            let r = Array(counts[(1 * 256)..<(2 * 256)])
            let g = Array(counts[(2 * 256)..<(3 * 256)])
            let b = Array(counts[(3 * 256)..<(4 * 256)])
            return Histogram(red: r, green: g, blue: b)
        }
    }
}
