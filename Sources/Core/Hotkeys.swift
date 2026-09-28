import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.z, modifiers: [.option]))
    /// Hold and ask Berrie a question — no screenshot, no circle.
    static let askBerrie = Self("askBerrie", default: .init(.a, modifiers: [.option]))
}
