import SwiftUI

/// The live stroke for ONE screen, in that screen's view-local (top-left
/// origin) coordinates. The controller owns one of these per panel and
/// feeds it from a 60fps `NSEvent.mouseLocation` sample.
final class StrokeModel: ObservableObject {
    @Published var points: [CGPoint] = []   // view-local coordinates
    func reset() { points.removeAll() }
}

/// Full-screen transparent canvas that draws the teal "circle-to-ask"
/// stroke. Deliberately NOT hit-testable: every point comes from the
/// controller's mouse-location timer, never from a gesture recognizer, so
/// the SwiftUI layer needs no events at all. Blocking the underlying app's
/// drag is done by the panel's content view (see CircleOverlayController).
struct CircleOverlayView: View {
    @ObservedObject var model: StrokeModel

    private static let ink = Color(red: 0.29, green: 0.87, blue: 0.83)

    var body: some View {
        Canvas { context, _ in
            guard model.points.count > 1 else { return }
            var path = Path()
            path.move(to: model.points[0])
            for point in model.points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(Self.ink),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
