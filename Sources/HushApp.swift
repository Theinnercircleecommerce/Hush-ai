import SwiftUI

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Hush", systemImage: "waveform") {
            Button("Check for Updates...") {
                appDelegate.updaterController.checkForUpdates(nil)
            }

            Divider()

            Button("Quit Hush") {
                NSApplication.shared.terminate(nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenOnboarding"))) { _ in
                openWindow(id: "onboarding")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.forEach { if $0.title != "" { $0.makeKeyAndOrderFront(nil) } }
                }
            }
        }

        Window("Welcome to Hush", id: "onboarding") {
            OnboardingView()
                .frame(width: 500, height: 400)
        }
        .windowResizability(.contentSize)
        .onChange(of: settings.showInDock) { newValue in
            appDelegate.updateActivationPolicy(showInDock: newValue)
        }
    }
}
