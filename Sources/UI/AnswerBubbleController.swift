import Cocoa
import SwiftUI

/// A small, click-through bubble that appears next to the cursor and streams
/// the spoken answer's text into view while it is being read aloud. This is
/// the visual half of circle-to-ask: it makes an answer legible even when the
/// TTS key is missing or the speech API fails.
///
/// The panel is created ONCE and reused forever — same pre-warm principle as
/// CircleOverlayController and the nudge. It is never destroyed, only ordered
/// out. It never intercepts clicks (`ignoresMouseEvents = true` always) and is
/// excluded from screen capture via TalkSession's `hushWindows()`.
///
/// Security: the bubble renders screen-derived answer text, so its content is
/// NEVER logged anywhere.
@MainActor
final class AnswerBubbleController {
    static let shared = AnswerBubbleController()

    /// The reusable panel, built lazily on first append and kept forever.
    private var panel: BubblePanel?
    /// The SwiftUI-observed text model. `append` mutates `text`; the hosting
    /// view re-renders and the panel is resized to fit.
    private let model = BubbleModel()
    private var hosting: NSHostingView<BubbleView>?

    /// The screen the bubble was anchored to on the FIRST chunk of this
    /// session. The top-left corner stays fixed there while the text grows
    /// down, so subsequent chunks never make the bubble jump around.
    private var anchorTopLeft: CGPoint?
    private var anchorScreen: NSScreen?

    /// Auto-clear timer. Fires 6s after the LAST append. Guarded by
    /// `generation` so a stale callback from a previous session can never hide
    /// a newer bubble — same house style as CircleOverlayController's
    /// `sessionGeneration`.
    private var autoClearTimer: Timer?
    /// Bumped by every `clear()` (and reused across appends) so a pending fade
    /// or auto-clear is abandoned once a new session begins.
    private var generation = 0

    // MARK: - Layout constants

    private static let maxWidth: CGFloat = 340
    private static let padding: CGFloat = 12
    /// Right-and-below the pointer. AppKit global space is bottom-left origin,
    /// so "below" the cursor is a NEGATIVE y offset.
    private static let cursorOffset = CGPoint(x: 20, y: -30)
    private static let fadeDuration: TimeInterval = 0.3
    private static let autoClearDelay: TimeInterval = 6

    private init() {}

    /// The bubble's window, for excluding Hush's own window from the
    /// screenshots sent to Claude. Empty until the first append builds it.
    var panelWindows: [NSWindow] {
        panel.map { [$0] } ?? []
    }

    // MARK: - API

    /// Append a streamed answer delta. The first chunk of a session positions
    /// and shows the panel; later chunks grow the text live. Every append
    /// resets the 6-second auto-clear timer.
    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }

        ensurePanel()
        guard let panel = panel else { return }

        // First chunk of a fresh session: anchor to the cursor's screen and
        // reveal the panel at full opacity.
        let isFirstChunk = model.text.isEmpty
        if isFirstChunk {
            generation += 1
            establishAnchor()
            model.text = chunk
            layoutAndPosition()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderFront(nil)
        } else {
            model.text += chunk
            layoutAndPosition()
        }

        scheduleAutoClear()
    }

    /// Fade the bubble out over 0.3s, then empty the text. Bumps the
    /// generation so any in-flight auto-clear from this session is cancelled,
    /// and a NEWER session that starts during the fade is never clobbered.
    func clear() {
        generation += 1
        let generation = self.generation
        autoClearTimer?.invalidate()
        autoClearTimer = nil

        guard let panel = panel, !model.text.isEmpty else {
            model.text = ""
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self = self, self.generation == generation else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.model.text = ""
            self.anchorTopLeft = nil
            self.anchorScreen = nil
        }
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: BubbleView(model: model))
        // DO-NOT-REGRESS: every NSHostingView in this project sets this — a
        // stray safe-area inset would offset the bubble's content.
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true

        let panel = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 40))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
    }

    /// Record the top-left anchor and owning screen from the current cursor.
    /// The bubble grows DOWN from this fixed point for the rest of the session.
    private func establishAnchor() {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(cursor, $0.frame) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(cursor) }
            ?? NSScreen.main
        anchorScreen = screen
        // (+20, −30): right of and below the pointer, in AppKit bottom-left
        // global coordinates. This point is the bubble's TOP-LEFT corner.
        anchorTopLeft = CGPoint(x: cursor.x + Self.cursorOffset.x,
                                y: cursor.y + Self.cursorOffset.y)
    }

    /// Size the panel to fit the accumulated text, then place it so its
    /// top-left sits at the anchor, clamped fully onto the anchor's screen.
    private func layoutAndPosition() {
        guard let panel = panel, let hosting = hosting else { return }

        // Fit the hosting view to at most maxWidth, letting height grow.
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: min(max(fitting.width, 1), Self.maxWidth),
            height: max(fitting.height, 1)
        )

        let screenFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let topLeft = anchorTopLeft ?? CGPoint(x: screenFrame.minX, y: screenFrame.maxY)

        // setFrameOrigin takes the bottom-left corner. topLeft.y is the TOP,
        // so the origin's y is topLeft.y − height.
        var originX = topLeft.x
        var originY = topLeft.y - size.height

        // Clamp fully onto the anchor screen's visible frame. Works for
        // displays at negative / non-zero origins — pure arithmetic on the
        // real frame, no assumptions about (0,0).
        if originX + size.width > screenFrame.maxX {
            originX = screenFrame.maxX - size.width
        }
        if originX < screenFrame.minX {
            originX = screenFrame.minX
        }
        if originY < screenFrame.minY {
            originY = screenFrame.minY
        }
        if originY + size.height > screenFrame.maxY {
            originY = screenFrame.maxY - size.height
        }

        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: - Auto-clear

    private func scheduleAutoClear() {
        autoClearTimer?.invalidate()
        let generation = self.generation
        let timer = Timer(timeInterval: Self.autoClearDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.generation == generation else { return }
                self.clear()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoClearTimer = timer
    }
}

// MARK: - Supporting types

/// Streamed answer text the bubble renders. `@Published` so appends re-render.
private final class BubbleModel: ObservableObject {
    @Published var text: String = ""
}

/// The bubble's content: white 13pt text on the notch's dark fill, rounded,
/// padded, capped at 340pt wide.
private struct BubbleView: View {
    @ObservedObject var model: BubbleModel

    var body: some View {
        Text(model.text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: AnswerBubbleController.maxWidthForView, alignment: .leading)
            .padding(AnswerBubbleController.paddingForView)
            // Match the notch panel's fill (NudgeView uses Color.black).
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black)
            )
            .ignoresSafeArea()
    }
}

/// Borderless, non-activating, click-through panel above everything.
private final class BubblePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Subtle shadow per the brief.
        hasShadow = true
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        // Never intercepts clicks — display only, always.
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Layout constants bridged to the private view without exposing the whole type.
extension AnswerBubbleController {
    fileprivate static let maxWidthForView: CGFloat = 340
    fileprivate static let paddingForView: CGFloat = 12
}
