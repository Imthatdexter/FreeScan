import SwiftUI
import CoreGraphics
import FreeScanCore

/// Right-hand pane: shows the prescan (or the processed positive preview) with the draggable
/// frame-selection overlay on top.
struct PrescanView: View {
    let document: ScanDocument

    private var displayImage: CGImage? {
        document.processedPreview ?? document.scanner.overviewImage
    }

    private var imagePixelSize: CGSize { document.scanner.overviewPixelSize }

    var body: some View {
        ZStack {
            Color.black
            if let img = displayImage, imagePixelSize != .zero {
                GeometryReader { geo in
                    let fit = aspectFit(imageSize: imagePixelSize, in: geo.size)
                    ZStack {
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                        CropOverlay(document: document, displayedSize: fit)
                            .frame(width: fit.width, height: fit.height)
                    }
                    .frame(width: fit.width, height: fit.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            switch document.scanner.status {
            case .error(let m): Text(m).foregroundStyle(.orange)
            case .browsing, .openingSession: Text("Connecting to scanner…").foregroundStyle(.secondary)
            default: Text("Run a prescan to see the film.").foregroundStyle(.secondary)
            }
        }
    }

    /// The largest frame with the image's aspect ratio that fits in `container`.
    private func aspectFit(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
