import Foundation
import CoreGraphics
import ImageCaptureCore
import Observation

/// High-level state of the scanner, for UI feedback.
public enum ScannerStatus: Equatable, Sendable {
    case idle
    case browsing
    case openingSession
    case ready
    case selectingFunctionalUnit
    case overviewing
    case scanning
    case done
    case error(String)
}

/// A Sendable snapshot of what the selected functional unit supports, so the UI never has to
/// touch ImageCaptureCore types directly. Resolutions are DPI values; bit depths are 1/8/16;
/// document types are raw `ICScannerDocumentType` values (76 = 35mm).
public struct FunctionalUnitSummary: Sendable, Hashable {
    public let typeRaw: Int
    public var supportedResolutions: [Int]
    public var supportedBitDepths: [Int]
    public var nativeXResolution: Int
    public var nativeYResolution: Int
    public var physicalSize: CGSize
    public var documentTypes: [Int]

    public init(
        typeRaw: Int,
        supportedResolutions: [Int] = [],
        supportedBitDepths: [Int] = [],
        nativeXResolution: Int = 0,
        nativeYResolution: Int = 0,
        physicalSize: CGSize = .zero,
        documentTypes: [Int] = []
    ) {
        self.typeRaw = typeRaw
        self.supportedResolutions = supportedResolutions
        self.supportedBitDepths = supportedBitDepths
        self.nativeXResolution = nativeXResolution
        self.nativeYResolution = nativeYResolution
        self.physicalSize = physicalSize
        self.documentTypes = documentTypes
    }

    /// True when the unit is the negative-transparency unit (the TPU film path).
    public var isNegativeTransparency: Bool {
        typeRaw == ICScannerFunctionalUnitType.negativeTransparency.rawValue
    }
    public var isPositiveTransparency: Bool {
        typeRaw == ICScannerFunctionalUnitType.positiveTransparency.rawValue
    }
    public var supports16Bit: Bool { supportedBitDepths.contains(16) }
}

/// Unifies the three transparency/flatbed subclasses that expose `supportedDocumentTypes` +
/// `documentType` (the base `ICScannerFunctionalUnit` does not). All three declare them
/// identically, so a retroactive conformance satisfies the requirement with their @objc
/// properties.
private protocol DocumentTypedUnit {
    var supportedDocumentTypes: IndexSet { get }
    var documentType: ICScannerDocumentType { get set }
}
extension ICScannerFunctionalUnitFlatbed: DocumentTypedUnit {}
extension ICScannerFunctionalUnitPositiveTransparency: DocumentTypedUnit {}
extension ICScannerFunctionalUnitNegativeTransparency: DocumentTypedUnit {}

/// Drives an Epson Perfection V500 Photo (or any ImageCaptureCore scanner) over USB.
///
/// The class is `@MainActor` and is the single source of truth the SwiftUI layer observes.
/// Per the ImageCaptureCore headers, **all device delegate callbacks occur on the main thread**,
/// so the `nonisolated` delegate implementations hop onto the main actor with
/// `MainActor.assumeIsolated` (no actor crossing, no `Sendable` hazard with the non-Sendable
/// `ICScannerDevice`).
///
/// **The "go" signal is `deviceDidBecomeReady(_:)`**, not `didOpenSessionWithError`. All
/// configure/scan requests are gated behind readiness.
@MainActor
@Observable
public final class ScannerController: NSObject {

    // MARK: Published state

    public private(set) var status: ScannerStatus = .idle
    public private(set) var discoveredDevices: [ICScannerDevice] = []
    public private(set) var connectedDevice: ICScannerDevice?
    public private(set) var connectedDeviceName: String?
    public private(set) var availableUnitTypes: [ICScannerFunctionalUnitType] = []
    public private(set) var unitSummary: FunctionalUnitSummary?
    public private(set) var overviewImage: CGImage?
    public private(set) var overviewPhysicalSize: CGSize = .zero
    public private(set) var overviewPixelSize: CGSize = .zero
    public private(set) var lastScanURL: URL?
    public private(set) var lastScanError: String?

    /// Cached reference to the selected functional unit. `selectedFunctionalUnit` is non-optional
    /// in Swift but can transiently return nil at runtime (an ImageCaptureCore quirk); caching
    /// the unit when we successfully read it avoids relying on the property at scan time.
    public private(set) var currentUnit: ICScannerFunctionalUnit?

    // MARK: Internals

    private let browser = ICDeviceBrowser()

    /// Hooks (invoked on the main actor) for non-UI clients like the diagnostic CLI to react to
    /// transitions without polling. All fire from the delegate callbacks below.
    public var onDeviceReady: (() -> Void)?
    public var onUnitSelected: (() -> Void)?
    public var onOverviewCaptured: ((CGImage) -> Void)?
    public var onScanComplete: ((URL) -> Void)?

    public override init() {
        super.init()
    }

    // MARK: Browsing & connection

    /// Begin looking for locally-attached scanners over USB. (ICDeviceBrowser callbacks are
    /// delivered by the Image Capture agent; the device callbacks are documented as main-thread.)
    public func startBrowsing() {
        guard status == .idle else { return }
        status = .browsing
        browser.delegate = self
        let mask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? ICDeviceTypeMask.scanner
        browser.browsedDeviceTypeMask = mask
        browser.start()
    }

    /// Stop browsing and (if connected) close the session.
    public func stop() {
        if let device = connectedDevice {
            device.requestCloseSession()
        }
        browser.stop()
        status = .idle
    }

    /// Open a session with the given scanner. After `deviceDidBecomeReady`, functional units
    /// become available and scanning can proceed.
    public func connect(to device: ICScannerDevice) {
        connectedDevice = device
        connectedDeviceName = device.name
        device.delegate = self
        status = .openingSession
        device.requestOpenSession()
    }

    /// Convenience: connect to the first discovered scanner.
    public func connectToFirstDiscovered() {
        guard let device = discoveredDevices.first else { return }
        connect(to: device)
    }

    // MARK: Functional-unit selection

    /// Pick the functional unit for the given film type: negative-transparency for negatives,
    /// positive-transparency for slides. Falls back to flatbed + a 35mm document type if the
    /// transparency unit isn't advertised by the driver.
    public func selectUnit(for filmType: FilmType) {
        guard let device = connectedDevice, status == .ready else { return }
        let desired: ICScannerFunctionalUnitType = (filmType == .positive) ? .positiveTransparency : .negativeTransparency

        let types = Self.functionalUnitTypes(from: device.availableFunctionalUnitTypes)
        availableUnitTypes = types

        let chosen: ICScannerFunctionalUnitType
        if types.contains(desired) {
            chosen = desired
        } else if types.contains(.flatbed) {
            chosen = .flatbed   // driver exposes film as a flatbed variant
        } else if let first = types.first {
            chosen = first
        } else {
            status = .error("Scanner reports no functional units.")
            return
        }
        status = .selectingFunctionalUnit
        device.requestSelect(chosen)
    }

    // MARK: Overview (prescan)

    /// Run a fast overview scan and publish `overviewImage`. Re-runnable for repositioning film.
    public func requestOverview(resolution: Int? = nil) {
        guard let device = connectedDevice else {
            status = .error("No device connected.")
            return
        }
        guard let unit = currentUnit ?? Self.optionalUnit(device.selectedFunctionalUnit) else {
            print("[FreeScan] requestOverview: no functional unit available")
            status = .error("No functional unit selected yet — press “Select film unit” again.")
            return
        }
        if let res = resolution {
            unit.overviewResolution = res
        } else {
            unit.overviewResolution = unit.supportedResolutions.min() ?? 100
        }
        status = .overviewing
        device.requestOverviewScan()
    }

    // MARK: Final scan

    /// Configure the selected unit for a real scan and kick it off. The scanned file is delivered
    /// via `lastScanURL` (file-based transfer). `crop` is in inches; pass nil to scan the full
    /// physical area.
    public func startScan(settings: ScanSettings, crop: CropRect?) {
        guard let device = connectedDevice else {
            print("[FreeScan] startScan: no connected device")
            status = .error("No device connected.")
            return
        }
        guard let unit = currentUnit ?? Self.optionalUnit(device.selectedFunctionalUnit) else {
            print("[FreeScan] startScan: no functional unit (currentUnit is nil and selectedFunctionalUnit is nil)")
            status = .error("No functional unit selected — press “Select film unit” again.")
            return
        }

        // Resolution: snap to the nearest supported DPI ≥ the requested value.
        let supported = unit.supportedResolutions
        let res: Int
        if let r = supported.integerGreaterThanOrEqualTo(settings.resolution) {
            res = r
        } else {
            res = supported.max() ?? settings.resolution
        }
        unit.resolution = res

        // Bit depth + pixel data type. The transparency unit captures RGB (B&W is derived from
        // that in software); set it explicitly so the scan path doesn't fall back to a default
        // the driver rejects.
        unit.bitDepth = Self.scannerBitDepth(for: settings.bitDepth, from: unit.supportedBitDepths)
        unit.pixelDataType = .RGB

        // Physical units + crop region. ICRect/ICSize are NSRect/NSSize on macOS.
        unit.measurementUnit = .inches
        let phys = unit.physicalSize
        var scanArea: NSRect
        if let crop {
            scanArea = NSRect(x: crop.rect.minX, y: crop.rect.minY,
                              width: crop.rect.width, height: crop.rect.height)
        } else {
            scanArea = NSRect(x: 0, y: 0, width: phys.width, height: phys.height)
        }
        // Safety net: clamp to the physical area so we never request an out-of-bounds region.
        scanArea.origin.x = max(0, min(scanArea.origin.x, max(phys.width - scanArea.width, 0)))
        scanArea.origin.y = max(0, min(scanArea.origin.y, max(phys.height - scanArea.height, 0)))
        if scanArea.maxX > phys.width { scanArea.size.width = max(phys.width - scanArea.origin.x, 0.05) }
        if scanArea.maxY > phys.height { scanArea.size.height = max(phys.height - scanArea.origin.y, 0.05) }
        unit.scanArea = scanArea

        // NOTE: we intentionally do NOT set documentType = 135 here. That declares a single 35mm
        // frame and conflicts with a custom (e.g. multi-frame) scanArea — it stalled the scanner.
        // The scanArea alone defines the region.

        // File-based transfer.
        device.transferMode = .fileBased
        device.downloadsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        device.documentUTI = settings.outputFormat.uti
        device.documentName = "FreeScan-\(Int(Date().timeIntervalSinceReferenceDate))"

        print("[FreeScan] startScan: res=\(res) dpi, bitDepth=\(unit.bitDepth.rawValue), "
              + "physicalSize=\(phys.width)×\(phys.height) in, "
              + "scanArea=(\(scanArea.origin.x), \(scanArea.origin.y)) \(scanArea.size.width)×\(scanArea.size.height) in, "
              + "format=\(settings.outputFormat.uti), unitState=\(unit.state.rawValue)")

        status = .scanning
        device.requestScan()
        print("[FreeScan] startScan: requestScan() sent")

        // Watchdog: if no completion callback arrives, cancel so the UI doesn't hang forever and
        // we get a clear signal. Transparency scans on the V500 can take ~2–3 minutes (lamp
        // warm-up + carriage move, especially the first scan), so allow 5 minutes.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard let self else { return }
            if self.status == .scanning {
                print("[FreeScan] scan watchdog: no completion in 300s — canceling")
                self.connectedDevice?.cancelScan()
                self.status = .error("Scan timed out (no response in 5 min). Try a smaller area or lower DPI, then re-prescan and retry.")
            }
        }
    }

    /// Cancel any in-flight scan.
    public func cancelScan() {
        connectedDevice?.cancelScan()
    }

    // MARK: Helpers

    private func publishSummary(for unit: ICScannerFunctionalUnit) {
        guard let unit = Self.optionalUnit(unit) else { return }   // unit can be nil here (IC quirk)
        self.currentUnit = unit
        // IMPORTANT: physicalSize is reported "in the current measurement unit". The unit's default
        // is often centimeters, which would make every downstream "inch" value wrong (and the
        // scanArea passed at scan time ~2.5× too large). Pin inches here, before reading anything.
        if unit.supportedMeasurementUnits.contains(Int(ICScannerMeasurementUnit.inches.rawValue)) {
            unit.measurementUnit = .inches
        }
        let ps = unit.physicalSize
        let docTypes = (unit as? DocumentTypedUnit)?.supportedDocumentTypes.sorted() ?? []
        let summary = FunctionalUnitSummary(
            typeRaw: Int(unit.type.rawValue),
            supportedResolutions: unit.supportedResolutions.sorted(),
            supportedBitDepths: unit.supportedBitDepths.sorted(),
            nativeXResolution: unit.nativeXResolution,
            nativeYResolution: unit.nativeYResolution,
            physicalSize: CGSize(width: ps.width, height: ps.height),
            documentTypes: docTypes
        )
        self.unitSummary = summary
        self.overviewPhysicalSize = CGSize(width: ps.width, height: ps.height)
    }

    private func apply35mmDocumentType(to unit: ICScannerFunctionalUnit) {
        guard let unit = Self.optionalUnit(unit) else { return }
        guard var fu = unit as? DocumentTypedUnit,
              fu.supportedDocumentTypes.contains(76),
              let dt = ICScannerDocumentType(rawValue: 76) else { return }
        fu.documentType = dt
    }

    private static func functionalUnitTypes(from numbers: [NSNumber]) -> [ICScannerFunctionalUnitType] {
        numbers.compactMap { ICScannerFunctionalUnitType(rawValue: $0.uintValue) }
    }

    /// `selectedFunctionalUnit` and the `didSelectFunctionalUnit:` parameter are non-optional in
    /// the Swift bridge but can be nil at runtime (a known ImageCaptureCore quirk — the unit is
    /// briefly nil inside `didSelectFunctionalUnit`). Reinterpret the raw reference bits as an
    /// Optional so we can detect nil instead of trapping on a subsequent `as?` cast.
    private static func optionalUnit(_ unit: ICScannerFunctionalUnit) -> ICScannerFunctionalUnit? {
        unsafeBitCast(unit, to: Optional<ICScannerFunctionalUnit>.self)
    }

    private static func scannerBitDepth(for option: BitDepthOption, from depths: IndexSet) -> ICScannerBitDepth {
        let want = option.bitsPerChannel
        let chosen = depths.integerGreaterThanOrEqualTo(want) ?? depths.max() ?? 8
        switch chosen {
        case 16: return .depth16Bits
        case 1: return .depth1Bit
        default: return .depth8Bits
        }
    }
}

// MARK: - ICDeviceBrowserDelegate (didAdd/didRemove are @required)
//
// `@preconcurrency` relaxes the isolation requirements for these Objective-C protocols so the
// @MainActor methods can satisfy the nonisolated requirements. Per the ImageCaptureCore headers,
// device delegate callbacks occur on the main thread, so touching MainActor-isolated state here
// is safe. (No `assumeIsolated` / closure capture, so no Sendable crossing for the non-Sendable
// IC types — which is what keeps this Swift 6-clean.)

extension ScannerController: @preconcurrency ICDeviceBrowserDelegate {

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        discoveredDevices.append(scanner)
        if connectedDevice == nil {
            connect(to: scanner)
        }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let scanner = device as? ICScannerDevice {
            discoveredDevices.removeAll { $0 === scanner }
        }
    }

    /// Local (USB/FireWire) device enumeration finished — if nothing showed up, say so.
    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        if discoveredDevices.isEmpty {
            status = .error("No scanners found. Is the V500 connected and its Epson ICA driver installed?")
        }
    }
}

// MARK: - ICScannerDeviceDelegate (extends ICDeviceDelegate)

extension ScannerController: @preconcurrency ICScannerDeviceDelegate {

    // --- @required ICDeviceDelegate methods ---

    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            status = .error("Open session failed: \(error.localizedDescription)")
        }
        // Wait for deviceDidBecomeReady before configuring.
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if connectedDevice === device { status = .idle }
    }

    public func didRemove(_ device: ICDevice) {
        if let scanner = device as? ICScannerDevice {
            discoveredDevices.removeAll { $0 === scanner }
            if connectedDevice === scanner {
                connectedDevice = nil
                status = .idle
            }
        }
    }

    // --- @optional ICDeviceDelegate / ICScannerDeviceDelegate methods ---

    /// THE go-signal: the device is ready to configure/scan.
    public func deviceDidBecomeReady(_ device: ICDevice) {
        guard let scanner = device as? ICScannerDevice else { return }
        availableUnitTypes = Self.functionalUnitTypes(from: scanner.availableFunctionalUnitTypes)
        status = .ready
        onDeviceReady?()
    }

    public func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let error { lastScanError = error.localizedDescription }
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        if let error {
            status = .error("Selecting functional unit failed: \(error.localizedDescription)")
            return
        }
        // Both the `functionalUnit` param and `selectedFunctionalUnit` are non-optional in Swift
        // but can be nil at runtime in this callback. Prefer the param, fall back to the property,
        // and publish only if we actually have a unit.
        if let unit = Self.optionalUnit(functionalUnit) ?? Self.optionalUnit(scanner.selectedFunctionalUnit) {
            publishSummary(for: unit)
        }
        status = .ready
        onUnitSelected?()
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
        if let error {
            status = .error("Overview scan failed: \(error.localizedDescription)")
            return
        }
        guard let unit = Self.optionalUnit(scanner.selectedFunctionalUnit) else {
            status = .error("Functional unit unavailable after overview.")
            return
        }
        if let cg = unit.overviewImage {
            overviewImage = cg
            overviewPixelSize = CGSize(width: cg.width, height: cg.height)
            let ps = unit.physicalSize
            overviewPhysicalSize = CGSize(width: ps.width, height: ps.height)
            onOverviewCaptured?(cg)
        }
        status = .ready
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        print("[FreeScan] didScanTo: \(url.path)")
        lastScanURL = url
        status = .done
        onScanComplete?(url)
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        print("[FreeScan] didCompleteScanWithError: \(error.map { $0.localizedDescription } ?? "no error")")
        if let error {
            status = .error("Scan failed: \(error.localizedDescription)")
        } else if lastScanURL != nil {
            status = .done
        }
    }
}
