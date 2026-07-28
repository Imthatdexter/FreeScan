import Foundation
import CoreGraphics

/// Pure coordinate conversions between the three spaces the app juggles:
///
/// 1. **View space** — SwiftUI points in the prescan's display frame.
/// 2. **Prescan pixel space** — pixels of the `overviewImage`.
/// 3. **Physical inches** — the scanner's `scanArea` units (with `measurementUnit == .inches`).
///
/// The prescan and the final scan cover the *same* physical area (the whole TPU region); the
/// prescan is just lower-DPI. So a rect in prescan pixels maps directly to physical inches via
/// the overview image's effective resolution, and that inch rect goes straight into `scanArea`.
public enum CropMath {

    // MARK: Prescan pixels ↔ physical inches

    /// Inches covered by one prescan pixel, derived from the overview image size and the
    /// functional unit's `physicalSize`. Deriving from dimensions (rather than trusting the
    /// unit's `overviewResolution` value) is more robust.
    public static func inchesPerPixel(overviewPixelSize: CGSize, physicalSize: CGSize) -> CGSize {
        guard overviewPixelSize.width > 0, overviewPixelSize.height > 0 else { return .zero }
        return CGSize(
            width: physicalSize.width / overviewPixelSize.width,
            height: physicalSize.height / overviewPixelSize.height
        )
    }

    /// Map a prescan-pixel rect to physical inches.
    public static func inches(
        fromPixelRect pixel: CGRect,
        overviewPixelSize: CGSize,
        physicalSize: CGSize
    ) -> CGRect {
        let s = inchesPerPixel(overviewPixelSize: overviewPixelSize, physicalSize: physicalSize)
        return CGRect(
            x: pixel.minX * s.width,
            y: pixel.minY * s.height,
            width: pixel.width * s.width,
            height: pixel.height * s.height
        )
    }

    /// Inverse of `inches(fromPixelRect:...)`.
    public static func pixel(
        fromInchRect inches: CGRect,
        overviewPixelSize: CGSize,
        physicalSize: CGSize
    ) -> CGRect {
        guard physicalSize.width > 0, physicalSize.height > 0 else { return .zero }
        let px = overviewPixelSize.width / physicalSize.width
        let py = overviewPixelSize.height / physicalSize.height
        return CGRect(
            x: inches.minX * px,
            y: inches.minY * py,
            width: inches.width * px,
            height: inches.height * py
        )
    }

    // MARK: View space ↔ prescan pixels

    /// Uniform display scale (displayed points per prescan pixel) under aspect-fit.
    public static func displayedScale(imagePixelSize: CGSize, displayedSize: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0 else { return 1 }
        return displayedSize.width / imagePixelSize.width
    }

    /// Map a view-space rect to prescan pixels.
    public static func pixel(
        fromViewRect view: CGRect,
        imagePixelSize: CGSize,
        displayedSize: CGSize
    ) -> CGRect {
        let s = displayedScale(imagePixelSize: imagePixelSize, displayedSize: displayedSize)
        guard s > 0 else { return .zero }
        return CGRect(
            x: view.minX / s,
            y: view.minY / s,
            width: view.width / s,
            height: view.height / s
        )
    }

    /// Map a prescan-pixel rect to view space.
    public static func view(
        fromPixelRect pixel: CGRect,
        imagePixelSize: CGSize,
        displayedSize: CGSize
    ) -> CGRect {
        let s = displayedScale(imagePixelSize: imagePixelSize, displayedSize: displayedSize)
        return CGRect(
            x: pixel.minX * s,
            y: pixel.minY * s,
            width: pixel.width * s,
            height: pixel.height * s
        )
    }

    // MARK: Convenience: view → inches in one step

    /// Full pipeline: a view-space rect → physical inches for `scanArea`.
    public static func inches(
        fromViewRect view: CGRect,
        imagePixelSize: CGSize,
        displayedSize: CGSize,
        physicalSize: CGSize
    ) -> CGRect {
        let pixelRect = pixel(fromViewRect: view, imagePixelSize: imagePixelSize, displayedSize: displayedSize)
        return inches(fromPixelRect: pixelRect, overviewPixelSize: imagePixelSize, physicalSize: physicalSize)
    }

    /// Clamp a rect to the scan area and enforce a minimum size (so a crop never collapses).
    public static func clamped(_ rect: CGRect, to bounds: CGRect, minSize: CGFloat = 0.05) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - minSize)
        r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - minSize)
        r.size.width = max(min(r.width, bounds.maxX - r.origin.x), minSize)
        r.size.height = max(min(r.height, bounds.maxY - r.origin.y), minSize)
        return r
    }
}
