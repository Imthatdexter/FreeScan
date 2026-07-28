import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FreeScanCore

/// Left-side controls: film type, bit depth, resolution, output format, tone curve, and the
/// prescan/scan actions.
struct SettingsPanel: View {
    @Bindable var document: ScanDocument

    /// Curated DPI presets. The V500 reports every integer DPI as "supported" (50–6400 in 1-dpi
    /// steps), so we deliberately do NOT expose the full set — just these standard stops,
    /// clamped to the unit's maximum. The slider snaps to these via `nearestAllowed`.
    private let resolutionPresets: [Int] = [50, 100, 300, 400, 600, 900, 1200, 1900, 2400, 3200, 6400]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            // MARK: Scanner / device
            Section("Scanner") {
                deviceRow
                HStack {
                    Button("Select film unit") { document.selectFilmUnit() }
                        .disabled(document.scanner.status != .ready)
                    Button("Prescan") { document.prescan() }
                        .disabled(!canPrescan)
                }
            }

            // MARK: Film type
            Section("Film type") {
                Picker("Type", selection: $document.settings.filmType) {
                    ForEach(FilmType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: document.settings.filmType) { _, _ in
                    document.filmTypeChanged()
                }
                if document.settings.filmType == .colorNegative {
                    Button("Re-sample orange mask") { document.recomputeAutoLevels() }
                }
            }

            // MARK: Resolution
            Section("Resolution") {
                Picker("Preset", selection: $document.settings.resolution) {
                    ForEach(allowedResolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                HStack {
                    Slider(value: Binding(
                        get: { Double(document.settings.resolution) },
                        set: { document.settings.resolution = nearestAllowed(Int($0)) }
                    ), in: resolutionRange)
                    Text("\(document.settings.resolution) dpi").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }

            // MARK: Bit depth + format
            Section("Output") {
                Picker("Bit depth", selection: $document.settings.bitDepth) {
                    ForEach(bitDepthOptions, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: document.settings.bitDepth) { _, _ in clampFormat() }

                Picker("Format", selection: $document.settings.outputFormat) {
                    ForEach(OutputFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: document.settings.outputFormat) { _, _ in clampFormat() }

                if document.settings.bitDepth == .sixteenBit && document.settings.outputFormat == .jpeg {
                    Text("JPEG is 8-bit only — the scan will be downconverted on export.")
                        .font(.caption).foregroundStyle(.orange)
                }

                Toggle("Also save unprocessed (RAW) scan", isOn: $document.settings.saveRawScan)
                    .help("Writes the driver-delivered scan alongside the processed file as <name>-RAW.tiff, for archiving.")
            }

            // MARK: Gradation (histogram + curve)
            Section("Gradation") {
                HistogramView(document: document).frame(height: 80)
                CurveEditorView(curve: $document.curve) { document.recompute() }
                    .frame(height: 180)
            }

            // MARK: Frames
            Section("Frames") {
                if document.selections.isEmpty {
                    Text("No frames yet — prescan, then add a frame.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(document.selections.enumerated()), id: \.element.id) { idx, sel in
                    HStack {
                        Image(systemName: sel.id == document.activeSelectionID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(sel.id == document.activeSelectionID ? Color.accentColor : Color.secondary)
                        Text("Frame \(idx + 1)").font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            document.removeSelection(sel.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this frame")
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { document.activeSelectionID = sel.id }
                }
                Button { document.addSelection() } label: {
                    Label("Add frame", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(document.scanner.overviewPixelSize == .zero)
                Text("Click a frame (here or in the preview) to activate it. Drag inside a frame to move it; drag its corners to resize.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // MARK: Scan
            Section("Scan") {
                ScanButton(document: document)
                BatchButton(document: document)
                    .disabled(document.selections.count < 2)
                if let err = document.exportError { Text(err).font(.caption).foregroundStyle(.red) }
                if let url = document.lastProcessedURL {
                    Text("Saved: \(url.lastPathComponent)").font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: Derived

    private var deviceRow: some View {
        VStack(alignment: .leading) {
            Text(document.scanner.connectedDeviceName ?? "No scanner").bold()
            if let s = document.scanner.unitSummary {
                Text("\(s.nativeXResolution) × \(s.nativeYResolution) dpi native; \(s.supportedBitDepths.map(String.init).joined(separator: "/"))-bit")
                    .font(.caption).foregroundStyle(.secondary)
                if !s.isNegativeTransparency && !s.isPositiveTransparency {
                    Text("No transparency unit — using flatbed fallback.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var allowedResolutions: [Int] {
        let maxDpi = document.scanner.unitSummary?.supportedResolutions.max() ?? 6400
        return resolutionPresets.filter { $0 <= maxDpi }
    }

    /// Prescan is allowed whenever a device is connected and not actively busy. (Previously this
    /// was gated on an overview already existing — a chicken-and-egg bug that blocked the first
    /// prescan.)
    private var canPrescan: Bool {
        guard document.scanner.connectedDevice != nil else { return false }
        switch document.scanner.status {
        case .overviewing, .scanning, .selectingFunctionalUnit, .openingSession, .browsing:
            return false
        default:
            return true
        }
    }

    private var resolutionRange: ClosedRange<Double> {
        let lo = allowedResolutions.first.map(Double.init) ?? 50
        let hi = allowedResolutions.last.map(Double.init) ?? 6400
        return lo...hi
    }

    private func nearestAllowed(_ value: Int) -> Int {
        let allowed = allowedResolutions
        guard let nearest = allowed.min(by: { abs($0 - value) < abs($1 - value) }) else { return value }
        return nearest
    }

    private var bitDepthOptions: [BitDepthOption] {
        let supports16 = document.scanner.unitSummary?.supports16Bit ?? true
        return supports16 ? [.eightBit, .sixteenBit] : [.eightBit]
    }

    /// JPEG can't hold 16-bit: if that combo is selected, drop to 8-bit.
    private func clampFormat() {
        if document.settings.outputFormat == .jpeg && document.settings.bitDepth == .sixteenBit {
            document.settings.bitDepth = .eightBit
        }
    }
}

/// Presents an NSSavePanel for the output path, then kicks the final scan.
struct ScanButton: View {
    let document: ScanDocument

    var body: some View {
        Button {
            presentSavePanel()
        } label: {
            Label(document.isProcessing ? "Processing…" : "Scan frame", systemImage: "camera.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(document.activeSelection == nil || document.isProcessing)
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Save scanned frame"
        panel.prompt = "Scan"
        panel.allowedContentTypes = [document.settings.outputFormat.utType]
        let ext = document.settings.outputFormat.rawValue
        panel.nameFieldStringValue = "FreeScan-frame.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.scan(to: url)
    }
}

/// Batch: pick an output directory, then scan every marked frame into it in sequence.
struct BatchButton: View {
    let document: ScanDocument

    var body: some View {
        Button {
            presentFolderPanel()
        } label: {
            Label("Scan all \(document.selections.count) frames", systemImage: "rectangle.stack.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .disabled(document.isProcessing)
    }

    private func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the scanned frames"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.scanAll(into: url, baseName: "FreeScan-frame")
    }
}
