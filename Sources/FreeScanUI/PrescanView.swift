import SwiftUI
import CoreGraphics
import FreeScanCore

/// Right-hand pane: shows the prescan (or processed positive preview) with the draggable
/// frame-selection overlay on top. Supports zoom, pan, and 90° rotation; the overlay's gestures
/// report in the untransformed "preview" coordinate space and convert deltas back to scanner
/// inches so crops stay physically correct under any transform.
struct PrescanView: View {
    let document: ScanDocument
    @State private var panBase: CGSize = .zero

    private var displayImage: CGImage? {
        document.processedPreview ?? document.scanner.overviewImage
    }
    private var imagePixelSize: CGSize { document.scanner.overviewPixelSize }

    var body: some View {
        GeometryReader { geo in
            let fit = aspectFit(imageSize: imagePixelSize, in: geo.size)
            ZStack {
                Color.black
                if let img = displayImage, imagePixelSize != .zero {
                    ZStack {
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                        CropOverlay(document: document, displayedSize: fit,
                                    zoom: document.zoom, rotationSteps: document.rotationSteps)
                            .frame(width: fit.width, height: fit.height)
                    }
                    .scaleEffect(document.zoom)
                    .rotationEffect(.degrees(Double(document.rotationSteps) * 90))
                    .offset(document.panOffset)
                    .gesture(
                        // Pan when dragging empty areas (frame gestures take priority over their rects).
                        DragGesture()
                            .onChanged { value in
                                document.panOffset = CGSize(
                                    width: panBase.width + value.translation.width,
                                    height: panBase.height + value.translation.height
                                )
                            }
                            .onEnded { _ in panBase = document.panOffset }
                    )
                } else {
                    placeholder
                }
            }
            .coordinateSpace(name: "preview")   // untransformed space the overlay gestures use
            .overlay(alignment: .bottomTrailing) { if imagePixelSize != .zero { PrescanToolbar(document: document) } }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "film").font(.system(size: 48)).foregroundStyle(.secondary)
            switch document.scanner.status {
            case .error(let m): Text(m).foregroundStyle(.orange)
            case .browsing, .openingSession: Text("Connecting to scanner…").foregroundStyle(.secondary)
            default: Text("Run a prescan to see the film.").foregroundStyle(.secondary)
            }
        }
    }

    /// Largest frame with the image's aspect ratio that fits in `container`.
    private func aspectFit(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

/// Floating zoom/rotate controls over the preview.
struct PrescanToolbar: View {
    let document: ScanDocument

    var body: some View {
        HStack(spacing: 6) {
            Button { document.rotateCW() } label: { Image(systemName: "rotate.right") }
                .help("Rotate 90° clockwise")
            Button { document.rotateCCW() } label: { Image(systemName: "rotate.left") }
                .help("Rotate 90° counterclockwise")
            Divider().frame(height: 16)
            Button { document.zoom = max(0.5, document.zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Slider(value: Binding(get: { document.zoom }, set: { document.zoom = $0 }), in: 0.5...8)
                .frame(width: 110)
            Button { document.zoom = min(8, document.zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
            Text("\(Int(document.zoom * 100))%").monospacedDigit().frame(width: 42)
            Button { document.fitToWindow() } label: { Image(systemName: "1.magnifyingglass") }
                .help("Fit to window")
            Button { document.resetView() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Reset view (zoom, pan, rotation)")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .buttonStyle(.borderless)
    }
}
