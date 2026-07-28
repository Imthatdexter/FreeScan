import SwiftUI
import FreeScanCore

/// The main two-pane window: a left tool panel and a large prescan/preview pane on the right.
public struct ContentView: View {
    @State private var document = ScanDocument()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Left tool panel. zIndex(1) keeps it above the preview's (clipped) overflow for both
            // rendering and hit-testing, so its buttons stay clickable when the preview is zoomed.
            ScrollView {
                SettingsPanel(document: document)
                    .padding()
            }
            .frame(width: 320)
            .background(.regularMaterial)
            .zIndex(1)

            Divider()

            // Right preview pane.
            PrescanView(document: document)
                .clipped()   // keep a zoomed/panned preview from overflowing onto the controls
        }
        .frame(minWidth: 1000, minHeight: 680)
        .navigationSubtitle(statusSubtitle)
        .overlay { if document.isProcessing { ProcessingOverlay() } }
        .onAppear { document.start() }
        .onDisappear { document.scanner.stop() }
    }

    private var statusSubtitle: String {
        switch document.scanner.status {
        case .idle: return "Idle"
        case .browsing: return "Looking for scanners…"
        case .openingSession: return "Opening session…"
        case .ready: return "Ready — \(document.scanner.connectedDeviceName ?? "scanner")"
        case .selectingFunctionalUnit: return "Selecting functional unit…"
        case .overviewing: return "Prescanning…"
        case .scanning: return "Scanning… (the transparency unit can take 1–3 min, especially the first scan — lamp warm-up)"
        case .done: return "Done"
        case .error(let m): return "Error: \(m)"
        }
    }
}

/// Modal-style overlay shown while a scan is being processed/saved (work runs off the main actor,
/// so this animates instead of freezing).
struct ProcessingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Processing & saving…").font(.headline)
                Text("Large 16-bit scans can take a while.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
