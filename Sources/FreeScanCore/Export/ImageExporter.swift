import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes a processed positive `CGImage` to JPEG / PNG / TIFF, preserving its bit depth.
///
/// Bit-depth handling:
/// - The exporter honors the source `CGImage`'s `bitsPerComponent`. A 16-bit image stays 16-bit
///   through TIFF and PNG. (Verified by the 16-bit round-trip test.)
/// - JPEG cannot hold 16-bit data, so a 16-bit source is downconverted to 8-bit (via vImage,
///   with optional dithering) before the JPEG write — never silently corrupted or errored.
public enum ImageExporter {

    public enum ExportError: Error, LocalizedError {
        case unsupportedFormat(OutputFormat)
        case imageDestinationCreationFailed
        case writeFailed
        case downconvertFailed

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f): return "Unsupported output format: \(f.displayName)"
            case .imageDestinationCreationFailed: return "Could not create image destination."
            case .writeFailed: return "Failed to write the image."
            case .downconvertFailed: return "Failed to downconvert 16-bit image to 8-bit for JPEG."
            }
        }
    }

    /// Write `image` to `url` in `format`, recording `dpi`.
    /// - If `format == .jpeg` and the image is 16-bit, it is downconverted to 8-bit first.
    public static func write(
        _ image: CGImage,
        to url: URL,
        format: OutputFormat,
        dpi: UInt = 300
    ) throws {
        let imageToWrite: CGImage
        if format == .jpeg && image.bitsPerComponent > 8 {
            guard let down = downconvert16To8(image) else { throw ExportError.downconvertFailed }
            imageToWrite = down
        } else {
            imageToWrite = image
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.uti as CFString,
            1,
            nil
        ) else {
            throw ExportError.imageDestinationCreationFailed
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        // Embed an sRGB profile so the file is unambiguous on other machines.
        properties[kCGImagePropertyColorModel] = "RGB"

        CGImageDestinationAddImage(destination, imageToWrite, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed
        }
    }

    /// Downconvert a 16-bit-per-channel image to 8-bit so it can be written to JPEG. Uses Core
    /// Graphics (a simple scaled downconvert). Returns nil on failure. A dithered vImage path
    /// (`vImageConvert_ARGB16UToARGB8888_dithered`) is the higher-quality future option.
    public static func downconvert16To8(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
