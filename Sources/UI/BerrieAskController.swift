import Cocoa
import SwiftUI

/// "Ask Berrie…" — a one-line text box next to Berrie for when talking out
/// loud isn't an option. Enter sends it through the same brain and voice as
/// ⌥⇧ (with a screenshot, so "what's this?" still works); Esc closes.
@MainActor
final class BerrieAskController {
    static let shared = BerrieAskController()

    private static let size = CGSize(width: 340, height: 44)
    private var panel: AskPanel?
    private let model = AskModel()

    var panelWindows: [NSWindow] { panel.map { [$0] } ?? [] }

    private init() {}

    func show(near berrie: NSRect?) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        model.text = ""
        let screen = NSScreen.screens.first { berrie.map($0.frame.intersects) ?? false } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        // Above Berrie, right-aligned with him; clamped onto the screen.
        var origin = CGPoint(x: (berrie?.maxX ?? visible.midX) - Self.size.width,
                             y: (berrie?.maxY ?? visible.midY) + 8)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> AskPanel {
        let panel = AskPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        let hosting = NSHostingView(rootView: AskView(model: model, onSubmit: { [weak self] text in
            self?.close()
            TalkSession.shared.askTyped(text)
        }, onCancel: { [weak self] in self?.close() }))
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

private final class AskModel: ObservableObject {
    @Published var text = ""
    @Published var focusToken = 0
}

private struct AskView: View {
    @ObservedObject var model: AskModel
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Ask Berrie…", text: $model.text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundColor(.white)
            .focused($focused)
            .onSubmit {
                let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onSubmit(text) }
            }
            .onExitCommand { onCancel() }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black))
            .onChange(of: model.focusToken) { _ in focused = true }
            .onAppear { focused = true }
    }
}

/// Non-activating but key-capable, so you can type without Berrie stealing
/// focus from the app you were in.
private final class AskPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)   // click elsewhere = never mind
    }
}
