import SwiftUI
import FreeScanCore

/// Interactive tone-curve editor. A diagonal spline through draggable control points (Catmull-Rom,
/// mirrored exactly by `ToneCurve.value`). The grid is drawn in a `Canvas`; control points are
/// SwiftUI circles carrying their own `DragGesture` (free hit-testing). Edits rebuild the curve
/// and call `onChange` so the preview re-renders.
struct CurveEditorView: View {
    @Binding var curve: ToneCurve
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, _ in
                    drawGrid(ctx, size)
                    drawSpline(ctx, size)
                }
                ForEach(curve.points.indices, id: \.self) { i in
                    pointView(at: i, size: size)
                }
            }
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                addPoint(at: location, size: size)
            }
        }
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        var p = Path()
        let divisions = 4
        for i in 0...divisions {
            let x = size.width * CGFloat(i) / CGFloat(divisions)
            let y = size.height * CGFloat(i) / CGFloat(divisions)
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(p, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
    }

    private func drawSpline(_ ctx: GraphicsContext, _ size: CGSize) {
        let steps = 128
        var path = Path()
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let v = curve.value(at: t)
            let pt = CGPoint(x: CGFloat(t) * size.width, y: (1 - CGFloat(v)) * size.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
    }

    // MARK: Control points

    private func pointView(at index: Int, size: CGSize) -> some View {
        let pt = curve.points[index]
        let pos = CGPoint(x: CGFloat(pt.input) * size.width, y: (1 - CGFloat(pt.output)) * size.height)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 12, height: 12)
            .position(pos)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        var points = curve.points
                        var np = points[index]
                        np.input = min(max(Float(value.location.x / size.width), 0), 1)
                        np.output = min(max(Float(1 - value.location.y / size.height), 0), 1)
                        // Keep endpoints pinned on the input axis.
                        if index == 0 { np.input = 0 }
                        if index == points.count - 1 { np.input = 1 }
                        points[index] = np
                        curve = ToneCurve(points: points)
                        onChange()
                    }
            )
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        let input = Float(location.x / size.width)
        // Don't add near existing points or the endpoints.
        guard curve.points.allSatisfy({ abs($0.input - input) > 0.05 }) else { return }
        let output = curve.value(at: input)
        var points = curve.points
        points.append(ToneCurvePoint(input: input, output: output))
        curve = ToneCurve(points: points)
        onChange()
    }
}
