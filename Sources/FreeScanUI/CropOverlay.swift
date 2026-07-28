import SwiftUI
import CoreGraphics
import FreeScanCore

/// Draggable frame-selection overlay. Selections are stored in **inches** (scanner space); this
/// view converts to/from the displayed frame. Gestures report in the untransformed "preview"
/// coordinate space, so under zoom/rotation each drag delta is divided by `zoom` and un-rotated
/// before being scaled to inches — keeping the crop physically correct regardless of the view
/// transform.
///
/// The box, the move hit-area, and the corner handles are all drawn in one shared overlay space
/// (origin top-left), so they line up exactly. Dragging is anchored to the rect captured at drag
/// start (so it can't run away), and positions are clamped to the physical scan area.
struct CropOverlay: View {
    let document: ScanDocument
    let displayedSize: CGSize
    let zoom: CGFloat
    let rotationSteps: Int

    /// Active drag state: the crop id and its inch-rect at the moment the drag began.
    @State private var dragStart: (id: UUID, inch: CGRect)?

    private var physical: CGSize { document.scanner.overviewPhysicalSize }

    /// Inches per aspect-fit view point (x/y), assuming the overlay exactly covers the aspect-fit image.
    private var inX: CGFloat { displayedSize.width > 0 ? physical.width / displayedSize.width : 0 }
    private var inY: CGFloat { displayedSize.height > 0 ? physical.height / displayedSize.height : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(document.selections) { crop in
                selectionLayer(for: crop)
            }
        }
        .frame(width: displayedSize.width, height: displayedSize.height)
    }

    // MARK: Per-selection layer

    @ViewBuilder
    private func selectionLayer(for crop: CropRect) -> some View {
        if let vr = viewRect(for: crop) {
            selectionContent(crop, vr: vr)
        }
    }

    @ViewBuilder
    private func selectionContent(_ crop: CropRect, vr: CGRect) -> some View {
        let isActive = crop.id == document.activeSelectionID

        // Move hit-area (covers the box). Drawn first so it's behind the border.
        Color.clear
            .contentShape(Rectangle())
            .frame(width: vr.width, height: vr.height)
            .position(x: vr.midX, y: vr.midY)
            .gesture(moveGesture(for: crop))
            .onTapGesture { document.activeSelectionID = crop.id }

        // Border + rule-of-thirds guides (non-interactive).
        ZStack {
            Rectangle()
                .stroke(isActive ? Color.accentColor : Color.red,
                        lineWidth: isActive ? 2 : 2)
            if isActive { thirdsPath(vr.size).stroke(Color.white.opacity(0.25), lineWidth: 0.5) }
        }
        .frame(width: vr.width, height: vr.height)
        .position(x: vr.midX, y: vr.midY)
        .allowsHitTesting(false)

        // Corner handles (active selection only).
        if isActive {
            ForEach(Handle.allCases) { handle in
                let p = handle.point(in: vr)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .position(x: p.x, y: p.y)
                    .gesture(resizeGesture(for: crop, handle: handle))
            }
        }
    }

    private func thirdsPath(_ size: CGSize) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = size.width * CGFloat(i) / 3
            let y = size.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        }
        return p
    }

    // MARK: Gestures (report in the "preview" space; convert through zoom + rotation)

    private func moveGesture(for crop: CropRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("preview"))
            .onChanged { value in
                if dragStart?.id != crop.id { dragStart = (crop.id, inchRect(of: crop)) }
                guard let start = dragStart else { return }
                let d = toInchDelta(value.translation)
                var r = start.inch
                r.origin.x = clamp(start.inch.origin.x + d.width, 0, max(physical.width - start.inch.width, 0))
                r.origin.y = clamp(start.inch.origin.y + d.height, 0, max(physical.height - start.inch.height, 0))
                setInchRect(of: crop, to: r)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(for crop: CropRect, handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("preview"))
            .onChanged { value in
                if dragStart?.id != crop.id { dragStart = (crop.id, inchRect(of: crop)) }
                guard let start = dragStart else { return }
                let startView = viewRect(fromInch: start.inch)
                let corner = handle.point(in: startView)
                let fitDelta = unrotate(CGSize(width: value.translation.width / max(zoom, 1e-6),
                                               height: value.translation.height / max(zoom, 1e-6)))
                let mx = (corner.x + fitDelta.width) * inX   // aspect-fit px → inches
                let my = (corner.y + fitDelta.height) * inY
                let r = rectBetween(handle: handle, movedX: mx, movedY: my, start: start.inch)
                setInchRect(of: crop, to: r)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Convert a screen-space (preview) drag delta to a scanner-inch delta, undoing the zoom and
    /// rotation applied to the view.
    private func toInchDelta(_ screen: CGSize) -> CGSize {
        guard zoom > 0 else { return .zero }
        let perFit = CGSize(width: screen.width / zoom, height: screen.height / zoom) // aspect-fit points
        let unrot = unrotate(perFit)
        return CGSize(width: unrot.width * inX, height: unrot.height * inY)
    }

    /// Undo the view rotation (quarter-turns CCW) on an aspect-fit-space delta.
    private func unrotate(_ s: CGSize) -> CGSize {
        switch ((rotationSteps % 4) + 4) % 4 {
        case 1:  return CGSize(width: s.height, height: -s.width)
        case 2:  return CGSize(width: -s.width, height: -s.height)
        case 3:  return CGSize(width: -s.height, height: s.width)
        default: return s
        }
    }

    /// Rebuild the rect from the moved corner and the (fixed) opposite corner, with normalization,
    /// a minimum size, and bounds clamping.
    private func rectBetween(handle: Handle, movedX: CGFloat, movedY: CGFloat, start: CGRect) -> CGRect {
        let minDim: CGFloat = 0.1
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case .topLeft:     minX = movedX; minY = movedY
        case .topRight:    maxX = movedX; minY = movedY
        case .bottomLeft:  minX = movedX; maxY = movedY
        case .bottomRight: maxX = movedX; maxY = movedY
        }
        minX = clamp(minX, 0, physical.width); maxX = clamp(maxX, 0, physical.width)
        minY = clamp(minY, 0, physical.height); maxY = clamp(maxY, 0, physical.height)
        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                       width: abs(maxX - minX), height: abs(maxY - minY))
        if r.width < minDim {
            r.size.width = minDim
            if handle == .topLeft || handle == .bottomLeft { r.origin.x = max(start.maxX - minDim, 0) }
        }
        if r.height < minDim {
            r.size.height = minDim
            if handle == .topLeft || handle == .topRight { r.origin.y = max(start.maxY - minDim, 0) }
        }
        return r
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }

    // MARK: Conversions (inch ↔ aspect-fit view)

    private func inchRect(of crop: CropRect) -> CGRect {
        document.selections.first { $0.id == crop.id }?.rect ?? .zero
    }

    private func setInchRect(of crop: CropRect, to r: CGRect) {
        guard let idx = document.selections.firstIndex(where: { $0.id == crop.id }) else { return }
        document.selections[idx].rect = r
    }

    private func viewRect(for crop: CropRect) -> CGRect? {
        guard let r = document.selections.first(where: { $0.id == crop.id })?.rect else { return nil }
        guard inX > 0, inY > 0 else { return nil }
        return CGRect(x: r.minX / inX, y: r.minY / inY, width: r.width / inX, height: r.height / inY)
    }

    private func viewRect(fromInch r: CGRect) -> CGRect {
        guard inX > 0, inY > 0 else { return .zero }
        return CGRect(x: r.minX / inX, y: r.minY / inY, width: r.width / inX, height: r.height / inY)
    }
}

private enum Handle: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }
}
