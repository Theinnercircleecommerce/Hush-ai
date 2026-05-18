import SwiftUI
class AppDelegate: NSObject, NSApplicationDelegate { }
@main
struct TestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { Text("Hi") } }
}
