import Cocoa
import SwiftUI

class HUDWindowController {
    static let shared = HUDWindowController()
    
    private var window: NSWindow?
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    func show(appState: AppState) {
        if window == nil {
            let view = NSHostingView(rootView: HUDView(appState: appState))
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 250, height: 60),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            // `.statusBar` makes it stay on top of EVERYTHING, even fullscreen apps
            win.level = .statusBar
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            win.hidesOnDeactivate = false
            win.isReleasedWhenClosed = false
            win.contentView = view
            self.window = win
        }
        
        reposition()
        window?.orderFront(nil)
    }
    
    @objc private func reposition() {
        // Fallback to first screen if main is nil at launch
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        
        if let win = window, let screen = targetScreen {
            // Using screen.frame instead of visibleFrame ensures it is perfectly physically centered 
            // regardless of where the macOS Dock is placed.
            let screenRect = screen.frame
            let x = screenRect.midX - (win.frame.width / 2)
            
            let y: CGFloat
            if AppSettings.shared.hudPosition == "top" {
                // Position right below the notch/menu bar (lowered slightly more)
                y = screenRect.maxY - win.frame.height - 45
            } else {
                // Position closer to the bottom edge (moved down ~1-2cm)
                y = screenRect.minY + 30
            }
            
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
    
    func hide() {
        window?.orderOut(nil)
    }
}
