import Foundation
import UniformTypeIdentifiers

/// Bit depth per channel for capture and export.
public enum BitDepthOption: String, CaseIterable, Sendable, Codable {
    case eightBit
    case sixteenBit

    public var bitsPerChannel: Int { self == .eightBit ? 8 : 16 }

    /// The matching `ICScannerBitDepth` is resolved in the scanner layer (1/8/16).
    public var displayName: String { "\(bitsPerChannel)-bit" }
}

/// Container formats the scanned positive can be written to.
public enum OutputFormat: String, CaseIterable, Sendable, Codable {
    case jpeg, png, tiff

    public var displayName: String { rawValue.uppercased() }

    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        }
    }

    public var uti: String { utType.identifier }

    /// JPEG cannot hold 16-bit data; TIFF and PNG can.
    public var supports16Bit: Bool { self != .jpeg }
}

/// All user-controllable scan settings, captured in one value the UI binds to.
public struct ScanSettings: Sendable, Codable {
    public var filmType: FilmType
    /// Scan resolution in DPI. Must be a member of the functional unit's `supportedResolutions`.
    public var resolution: Int
    public var bitDepth: BitDepthOption
    public var outputFormat: OutputFormat
    /// When true, also write the unprocessed (driver-delivered) scan next to the processed file,
    /// with a "-RAW" suffix — for archiving. Format is always TIFF.
    public var saveRawScan: Bool

    public init(
        filmType: FilmType = .colorNegative,
        resolution: Int = 1200,
        bitDepth: BitDepthOption = .sixteenBit,
        outputFormat: OutputFormat = .tiff,
        saveRawScan: Bool = false
    ) {
        self.filmType = filmType
        self.resolution = resolution
        self.bitDepth = bitDepth
        self.outputFormat = outputFormat
        self.saveRawScan = saveRawScan
    }
}
