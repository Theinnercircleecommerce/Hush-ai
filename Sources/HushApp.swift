import SwiftUI

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Button("Ask Berrie…") { BerrieAskController.shared.show(near: BerrieController.shared.panelFrame) }
            Button("Dashboard…") { BrainShell.openBoard() }
            Divider()
            Button("Check for Updates…") { BrainShell.checkForUpdates() }
            Divider()
            Button("Quit Berrie") { BrainShell.quit() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenOnboarding"))) { _ in
                openWindow(id: "onboarding")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.forEach { if $0.title != "" { $0.makeKeyAndOrderFront(nil) } }
                }
            }
        } label: {
            Image(nsImage: BerrieView.menuBarImage)
        }

        Window("Welcome to Berrie", id: "onboarding") {
            OnboardingView()
                .frame(width: 500, height: 400)
        }
        .windowResizability(.contentSize)
        .onChange(of: settings.showInDock) { newValue in
            appDelegate.updateActivationPolicy(showInDock: newValue)
        }
    }
}
