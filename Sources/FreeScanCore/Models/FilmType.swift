import Foundation

/// The kind of film loaded in the transparency unit. Determines the post-scan processing.
public enum FilmType: String, CaseIterable, Sendable, Codable {
    /// Color negative film — requires orange-mask removal + per-channel normalization + invert.
    case colorNegative
    /// Black & white negative film — invert (+ optional contrast/gamma via the tone curve).
    case blackAndWhiteNegative
    /// Positive / slide film — scanned as-is, no inversion. (Future; separate functional unit.)
    case positive

    public var displayName: String {
        switch self {
        case .colorNegative: return "Color Negative"
        case .blackAndWhiteNegative: return "B&W Negative"
        case .positive: return "Positive / Slide"
        }
    }

    /// Whether the scan must be inverted to a positive.
    public var requiresInversion: Bool {
        switch self {
        case .colorNegative, .blackAndWhiteNegative: return true
        case .positive: return false
        }
    }

    /// Whether the image carries independent color channels (vs. a single luminance channel).
    public var isColor: Bool {
        switch self {
        case .colorNegative, .positive: return true
        case .blackAndWhiteNegative: return false
        }
    }
}
