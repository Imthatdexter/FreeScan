import Foundation
import CoreGraphics
import ImageIO
import ImageCaptureCore
import FreeScanCore

/// FreeScanDiag — Step 0 validation tool.
///
/// Discovers the Epson Perfection V500 Photo over USB, prints its functional units with the
/// supported resolutions, bit depths, and document types, and runs one overview (prescan) scan
/// saved to disk. The app's resolution/bit-depth options are populated from this output.
///
/// If the negative-transparency unit is NOT listed, that's the signal to fall back to a SANE
/// path (see the build brief).
@main
@MainActor
enum FreeScanDiag {
    static func main() {
        print("FreeScanDiag — looking for scanners (USB)…")
        let driver = DiagDriver()
        driver.start()

        // Spin the main run loop so ImageCaptureCore callbacks (on delegateQueue = .main) fire,
        // until the driver signals completion or we time out.
        let deadline = Date(timeIntervalSinceNow: driver.timeout)
        while driver.shouldContinue && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        if !driver.completedOverview {
            print("\nNo scanner responded within \(Int(driver.timeout))s.")
            print("Make sure the V500 is connected via USB and Epson's ICA driver is installed:")
            print("  https://epson.com/Support/Scanners/Perfection-Series/Epson-Perfection-V500-Photo")
            exit(1)
        }
        print("\nDone.")
    }
}

@MainActor
final class DiagDriver {
    let controller = ScannerController()
    let timeout: TimeInterval = 120
    private(set) var shouldContinue = true
    private(set) var completedOverview = false
    private var savedURL: URL?

    func start() {
        controller.onDeviceReady = { [weak self] in self?.deviceReady() }
        controller.onUnitSelected = { [weak self] in self?.unitSelected() }
        controller.onOverviewCaptured = { [weak self] cg in self?.overviewCaptured(cg) }
        controller.startBrowsing()
    }

    private func deviceReady() {
        print("\n=== Scanner ready: \(controller.connectedDeviceName ?? "(unknown)") ===")
        print("Available functional units:")
        for type in controller.availableUnitTypes {
            print("  - \(Self.name(of: type))")
        }
        let hasNegative = controller.availableUnitTypes.contains(.negativeTransparency)
        let hasPositive = controller.availableUnitTypes.contains(.positiveTransparency)
        print(hasNegative ? "✓ Negative-transparency unit available (TPU film path)." : "✗ No negative-transparency unit.")
        if !hasNegative && !hasPositive {
            print("  → No transparency unit exposed. Falling back to flatbed + 35mm doc type.")
        }
        // Select the film unit (or flatbed fallback) so we can read its detailed capabilities.
        controller.selectUnit(for: .colorNegative)
    }

    private func unitSelected() {
        if let s = controller.unitSummary {
            print("\n=== Selected functional unit capabilities ===")
            print("  type:                \(Self.name(ofRaw: s.typeRaw))")
            print("  native resolution:   \(s.nativeXResolution) × \(s.nativeYResolution) dpi")
            print("  supported DPI:       \(s.supportedResolutions.map(String.init).joined(separator: ", "))")
            print("  supported bit depth: \(s.supportedBitDepths.map(String.init).joined(separator: ", "))")
            print("  physical size:       \(String(format: "%.3f", s.physicalSize.width)) × \(String(format: "%.3f", s.physicalSize.height)) in")
            let filmTypes = s.documentTypes.filter { (73...78).contains($0) }  // APS/H/C/P, 135, MF, LF
            if !filmTypes.isEmpty {
                print("  film document types: \(filmTypes.map(String.init).joined(separator: ", "))  (135 = 35mm)")
            }
        } else {
            print("\n(Functional-unit details weren't ready at select time; continuing to overview.)")
        }
        print("\nRequesting an overview scan…")
        controller.requestOverview()
    }

    private func overviewCaptured(_ cg: CGImage) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeScanDiag-overview.tiff")
        if write(cg, to: url) {
            savedURL = url
            completedOverview = true
            print("\n✓ Overview scan saved to:")
            print("  \(url.path)")
            print("  (\(cg.width) × \(cg.height) px)")
        } else {
            print("✗ Failed to write the overview image.")
        }
        shouldContinue = false
    }

    // MARK: Helpers

    private func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func name(of type: ICScannerFunctionalUnitType) -> String {
        switch type {
        case .flatbed: return "Flatbed"
        case .positiveTransparency: return "Positive Transparency (slides)"
        case .negativeTransparency: return "Negative Transparency (film)"
        case .documentFeeder: return "Document Feeder"
        @unknown default: return "Unknown(\(type.rawValue))"
        }
    }

    private static func name(ofRaw raw: Int) -> String {
        guard let type = ICScannerFunctionalUnitType(rawValue: UInt(raw)) else { return "Unknown(\(raw))" }
        return name(of: type)
    }
}
