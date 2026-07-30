import SwiftUI
import AppKit

/// Fixed outer dimensions of the transparent nudge panel. The panel never
/// resizes; the SwiftUI content inside animates within this canvas.
enum NudgeLayout {
    static let containerWidth: CGFloat = 600
    static let containerHeight: CGFloat = 70
}

/// Physical notch measurements for a given screen.
struct NotchMetrics {
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchMetrics(hasNotch: true, notchWidth: width, notchHeight: topInset)
        }
        // Notchless display (external monitor / older Mac): the expansion
        // renders as a free-standing rounded bar of this virtual size.
        return NotchMetrics(hasNotch: false, notchWidth: 180, notchHeight: 0)
    }

    /// Height of the black expansion bar content.
    var expansionHeight: CGFloat {
        hasNotch ? notchHeight + 8 : 34
    }
}

/// Outline of the widened notch: square top edge that flares out of the
/// screen top, rounded lower corners — same silhouette as the hardware notch.
struct NudgeNotchShape: Shape {
    var topCornerRadius: CGFloat = 8
    var bottomCornerRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Start at top-left, on the screen's top edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Flare inward-downward from the top edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        // Left side down.
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        // Bottom-left rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        // Bottom-right rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        // Right side up.
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        // Flare back out to the top edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
