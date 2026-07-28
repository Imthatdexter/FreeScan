import SwiftUI
import CoreGraphics
import FreeScanCore

/// Live RGB histogram of the current preview, drawn with `Canvas` (R/G/B channels, screen-blended).
struct HistogramView: View {
    let document: ScanDocument
    @State private var histogram: Histogram?

    var body: some View {
        Canvas { ctx, size in
            guard let histogram else { return }
            drawChannel(ctx, size: size, counts: histogram.red, color: .red)
            drawChannel(ctx, size: size, counts: histogram.green, color: .green)
            drawChannel(ctx, size: size, counts: histogram.blue, color: .blue)
        }
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onChange(of: document.processedPreview) { _, _ in recompute() }
        .onChange(of: document.scanner.overviewImage) { _, _ in recompute() }
        .onAppear { recompute() }
    }

    private func recompute() {
        let img = document.processedPreview ?? document.scanner.overviewImage
        histogram = img.flatMap { HistogramComputation.compute(from: $0) }
    }

    private func drawChannel(_ ctx: GraphicsContext, size: CGSize, counts: [UInt], color: Color) {
        let maxCount = max(counts.max() ?? 1, 1)
        var path = Path()
        let bw = size.width / CGFloat(counts.count)
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, c) in counts.enumerated() {
            let h = size.height * CGFloat(c) / CGFloat(maxCount)
            path.addLine(to: CGPoint(x: CGFloat(i) * bw, y: size.height - h))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(0.5)))
    }
}
