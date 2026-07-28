import Foundation

/// A frame selection on the prescan, expressed in the scanner's native measurement space
/// (inches when `measurementUnit == .inches`). Identifiable so the UI can manage multiple
/// simultaneous selections on one strip.
public struct CropRect: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// Rect in the selected functional unit's measurement space. Origin at the scan-area corner.
    public var rect: CGRect

    public init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }

    public var width: CGFloat { rect.width }
    public var height: CGFloat { rect.height }

    /// A 35mm frame is nominally 24 × 36 mm ≈ 0.945" × 1.417" (landscape) or its transpose.
    public static let frame35mmLandscape = CGSize(width: 1.417, height: 0.945)
    public static let frame35mmPortrait = CGSize(width: 0.945, height: 1.417)
}
