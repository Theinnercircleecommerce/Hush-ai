import Cocoa
import ApplicationServices

class PasteService {
    static func paste(text: String, simulateReturn: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Wait a tiny bit for the clipboard to be ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            
            // 0x09 is the keycode for 'v'
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            
            let flags: CGEventFlags = .maskCommand
            vDown?.flags = flags
            vUp?.flags = flags
            
            vDown?.post(tap: .cgAnnotatedSessionEventTap)
            vUp?.post(tap: .cgAnnotatedSessionEventTap)
            
            if simulateReturn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // 0x24 is the keycode for Return
                    let returnDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
                    let returnUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
                    
                    returnDown?.post(tap: .cgAnnotatedSessionEventTap)
                    returnUp?.post(tap: .cgAnnotatedSessionEventTap)
                }
            }
        }
    }
    
    static func isAccessibilityEnabled() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        return AXIsProcessTrustedWithOptions(options)
    }
}
