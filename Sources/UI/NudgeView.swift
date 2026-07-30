import SwiftUI

/// Clicky-style nudge: translucent idle pill at the top edge; black notch
/// expansion with a state label (left) and animated dots (right) when active.
struct NudgeView: View {
    @ObservedObject var appState: AppState
    let metrics: NotchMetrics

    private static let listeningTeal = Color(red: 0.29, green: 0.87, blue: 0.83)
    private static let thinkingPurple = Color(red: 0.72, green: 0.45, blue: 0.95)

    init(appState: AppState, metrics: NotchMetrics) {
        self.appState = appState
        self.metrics = metrics
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if case .idle = appState.hudState {
                    if metrics.hasNotch {
                        idleNotchShelf
                            .transition(.opacity)
                    } else {
                        idlePill
                            .transition(.opacity)
                    }
                } else {
                    expansion
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: NudgeLayout.containerWidth, height: NudgeLayout.containerHeight, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.hudState)
    }

    // MARK: - Idle

    /// Notched screens: no pill — the notch itself just reads slightly
    /// wider, like HeyClicky at rest.
    private var idleNotchShelf: some View {
        // Measured from HeyClicky: idle bar = notch + ~35pt per side, flush
        // with the notch bottom (no lip).
        NudgeNotchShape(topCornerRadius: 6, bottomCornerRadius: 12)
            .fill(Color.black)
            .frame(width: metrics.notchWidth + 72, height: metrics.notchHeight + 1)
    }

    private var idlePill: some View {
        Capsule()
            .fill(Color.white.opacity(0.16))
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
            .frame(width: 68, height: 9)
            .padding(.top, metrics.hasNotch ? metrics.notchHeight + 2 : 4)
    }

    // MARK: - Active expansion

    private var expansionWidth: CGFloat {
        metrics.hasNotch ? metrics.notchWidth + 60 : 200
    }

    private var expansion: some View {
        ZStack {
            NudgeNotchShape(
                topCornerRadius: metrics.hasNotch ? 8 : 0,
                bottomCornerRadius: 14
            )
            .fill(Color.black)

            HStack(spacing: 0) {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                // Keep the physical notch area empty.
                Color.clear.frame(width: metrics.notchWidth)
                dots
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
            }
            // Center content in the sliver below the hardware notch on
            // notched screens; vertically centered on notchless displays.
            .padding(.top, metrics.hasNotch ? metrics.notchHeight * 0.35 : 0)
        }
        .frame(width: expansionWidth, height: metrics.expansionHeight)
        .clipShape(NudgeNotchShape(
            topCornerRadius: metrics.hasNotch ? 8 : 0,
            bottomCornerRadius: 14
        ))
    }

    @ViewBuilder
    private var label: some View {
        switch appState.hudState {
        case .recording:
            Text("Listening")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        case .transcribing:
            Text("Thinking")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        case .error(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var dots: some View {
        switch appState.hudState {
        case .recording:
            NudgeBarsView(level: appState.audioLevel, color: Self.listeningTeal)
        case .transcribing:
            NudgePulseDotsView(color: Self.thinkingPurple)
        case .error:
            NudgePulseDotsView(color: Color(red: 1.0, green: 0.42, blue: 0.42))
        case .idle:
            EmptyView()
        }
    }
}

/// Five mini bars driven by live mic level (Listening state).
struct NudgeBarsView: View {
    var level: Float
    var color: Color

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(index))
                    .animation(.spring(response: 0.15, dampingFraction: 0.6), value: level)
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 3
        let center: CGFloat = 2
        let attenuation = max(0, 1.0 - abs(CGFloat(index) - center) * 0.3)
        let active = max(CGFloat(level), 0.12)
        let jitter = CGFloat.random(in: 0.85...1.15)
        return min(base + active * 9 * attenuation * jitter, 12)
    }
}

/// Three softly pulsing dots (Thinking / error states).
struct NudgePulseDotsView: View {
    var color: Color
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .opacity(pulsing ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}
