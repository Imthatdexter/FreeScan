import Foundation
import CoreGraphics
import ImageIO
import SwiftUI
import FreeScanCore

/// App-level state: owns the scanner controller, the user's scan settings, the frame selections,
/// the tone curve, and the derived live preview. Bridges scanner callbacks into the SwiftUI world.
@MainActor
@Observable
public final class ScanDocument {

    public let scanner = ScannerController()

    public var settings = ScanSettings()
    public var selections: [CropRect] = []
    public var activeSelectionID: UUID?
    public var curve: ToneCurve = .defaultContrast
    /// Preview view transform: zoom (1.0 = fit), pan offset, and rotation in quarter-turns CCW
    /// (0/1/2/3). Rotation also rotates the exported scan so saved files match the view.
    public var zoom: CGFloat = 1.0
    public var panOffset: CGSize = .zero
    public var rotationSteps: Int = 0
    /// Auto-derived levels (Dmin/Dmax) for the PREVIEW, computed from the prescan. The final
    /// scan recomputes its own levels from its own histogram (the two captures are exposed
    /// differently), so this is only for the live preview.
    public var previewLevels: ColorNegativeLevels?

    public var processedPreview: CGImage?      // prescan → positive, after inversion + curve
    public var lastProcessedURL: URL?
    public var exportError: String?
    public var isProcessing = false

    private var pendingOutputURL: URL?
    private var batchQueue: [(crop: CropRect, url: URL)] = []

    public init() {
        scanner.onDeviceReady = { [weak self] in self?.selectFilmUnit() }   // auto-select on launch
        scanner.onOverviewCaptured = { [weak self] _ in self?.handleOverview() }
        scanner.onScanComplete = { [weak self] url in self?.handleScanComplete(url) }
    }

    // MARK: Selections

    public var activeSelection: CropRect? {
        if let id = activeSelectionID, let s = selections.first(where: { $0.id == id }) { return s }
        return selections.first
    }

    public func addSelection() {
        let r = defaultCropRect()
        let crop = CropRect(rect: r)
        selections.append(crop)
        activeSelectionID = crop.id
    }

    public func removeSelection(_ id: UUID) {
        selections.removeAll { $0.id == id }
        if activeSelectionID == id { activeSelectionID = selections.first?.id }
    }

    private func defaultCropRect() -> CGRect {
        let phys = scanner.overviewPhysicalSize
        guard phys.width > 0, phys.height > 0 else { return CGRect(x: 0, y: 0, width: 0.9, height: 1.4) }
        // A 3:2 frame centered in the area.
        let w = min(phys.width * 0.9, 1.42)
        let h = w * 2.0 / 3.0
        let x = (phys.width - w) / 2
        let y = (phys.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Workflow

    public func start() {
        cleanupOldTempScans()
        scanner.startBrowsing()
    }

    /// Remove leftover raw scan files the scanner wrote to the temp dir on previous runs.
    private func cleanupOldTempScans() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("FreeScan-") && url.pathExtension.lowercased() == "tiff" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func selectFilmUnit() { scanner.selectUnit(for: settings.filmType) }

    public func prescan() { scanner.requestOverview() }

    // MARK: View transform (zoom / pan / rotate)

    public func rotateCCW() { rotationSteps = (rotationSteps + 1) % 4 }
    public func rotateCW() { rotationSteps = (rotationSteps + 3) % 4 }
    public func resetView() { zoom = 1.0; panOffset = .zero; rotationSteps = 0 }
    public func fitToWindow() { zoom = 1.0; panOffset = .zero }

    /// Call when the film type changes: re-select the unit, re-derive preview levels, refresh.
    public func filmTypeChanged() {
        selectFilmUnit()
        if let cg = scanner.overviewImage {
            previewLevels = FilmProcessing.autoLevels(for: settings.filmType, from: cg)
        }
        recompute()
    }

    /// Re-run the preview pipeline (call when curve/levels change). The overview is a raw
    /// negative, so the preview DOES invert it.
    public func recompute() {
        guard let cg = scanner.overviewImage else { processedPreview = nil; return }
        processedPreview = FilmProcessing.processAndRender(
            cg, filmType: settings.filmType, levels: previewLevels,
            curve: curve, bitsPerComponent: 8, invert: true
        )
    }

    /// Re-derive auto levels from the current prescan histogram (color or B&W).
    public func recomputeAutoLevels() {
        guard let cg = scanner.overviewImage else { return }
        previewLevels = FilmProcessing.autoLevels(for: settings.filmType, from: cg)
        recompute()
    }

    /// Kick a final scan of the active selection; the result is processed + exported on completion.
    public func scan(to outputURL: URL) {
        guard let active = activeSelection else { exportError = "No frame selected."; return }
        print("[FreeScan] scan requested → \(outputURL.path); crop inches=\(active.rect), \(settings.resolution) dpi, \(settings.bitDepth.displayName), \(settings.outputFormat.uti)")
        pendingOutputURL = outputURL
        scanner.startScan(settings: settings, crop: active)
    }

    /// Batch: scan every marked frame in sequence into `directory`, one file each.
    public func scanAll(into directory: URL, baseName: String) {
        guard !selections.isEmpty else { exportError = "No frames marked."; return }
        let ext = settings.outputFormat.rawValue
        batchQueue = selections.enumerated().map { (i, crop) in
            (crop, directory.appendingPathComponent("\(baseName)-\(String(format: "%02d", i + 1)).\(ext)"))
        }
        runNextBatchItem()
    }

    private func runNextBatchItem() {
        guard !batchQueue.isEmpty else { return }
        let item = batchQueue.removeFirst()
        pendingOutputURL = item.url
        scanner.startScan(settings: settings, crop: item.crop)
    }

    // MARK: Callbacks

    private func handleOverview() {
        guard let cg = scanner.overviewImage else { return }
        if selections.isEmpty {
            let crop = CropRect(rect: defaultCropRect())
            selections = [crop]
            activeSelectionID = crop.id
        }
        previewLevels = FilmProcessing.autoLevels(for: settings.filmType, from: cg)
        recompute()
    }

    private func handleScanComplete(_ scanURL: URL) {
        guard let outputURL = pendingOutputURL else { return }
        pendingOutputURL = nil
        isProcessing = true

        // Snapshot the Sendable settings; the heavy CGImage decode/render/write stays entirely off
        // the main actor so the UI (and the progress overlay) keep responding, even for a ~350 MB
        // 16-bit scan.
        let filmType = settings.filmType
        let bits = settings.bitDepth.bitsPerChannel
        let fmt = settings.outputFormat
        let dpi = UInt(max(settings.resolution, 72))
        let curve = self.curve
        let saveRaw = settings.saveRawScan
        let rotationSteps = self.rotationSteps
        let rawURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + "-RAW")
            .appendingPathExtension(outputURL.pathExtension)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let src = CGImageSourceCreateWithURL(scanURL as CFURL, nil),
                  let scanned = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                try? FileManager.default.removeItem(at: scanURL)
                await self?.processingFailed("Could not read the scanned file at \(scanURL.path).")
                return
            }
            // Optional archival RAW (the unprocessed, driver-delivered scan) alongside the output.
            if saveRaw {
                try? ImageExporter.write(scanned, to: rawURL, format: .tiff, dpi: dpi)
            }
            // The Epson ICA driver delivers the full-scan file already inverted to a positive, so
            // invert=false: desaturate (B&W) + curve, then rotate to match the view orientation.
            guard let processed = FilmProcessing.processAndRender(
                scanned, filmType: filmType, levels: nil, curve: curve,
                bitsPerComponent: bits, invert: false,
                rotationQuarterTurnsCCW: rotationSteps
            ) else {
                try? FileManager.default.removeItem(at: scanURL)
                await self?.processingFailed("Image processing failed (try a lower DPI or 8-bit).")
                return
            }
            do {
                try ImageExporter.write(processed, to: outputURL, format: fmt, dpi: dpi)
                try? FileManager.default.removeItem(at: scanURL)   // clean up the scanner's temp file
                print("[FreeScan] wrote processed scan to \(outputURL.path)")
                await self?.processingSucceeded(outputURL)
            } catch {
                await self?.processingFailed(error.localizedDescription)
            }
        }
    }

    @MainActor private func processingSucceeded(_ url: URL) {
        lastProcessedURL = url
        exportError = nil
        isProcessing = false
        if !batchQueue.isEmpty { runNextBatchItem() }
    }

    @MainActor private func processingFailed(_ message: String) {
        exportError = message
        isProcessing = false
    }
}
