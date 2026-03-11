import AppKit
import Foundation

// Signal handler for clean exit (restoring gamma)
func signalHandler(signal: Int32) {
    if let delegate = AppDelegate.shared {
        delegate.brightnessController.restoreGamma()
        NSLog("PowerMateDriver: Caught signal %d, restored gamma.", signal)
    }
    exit(signal)
}

// Trap SIGINT and SIGTERM
signal(SIGINT, signalHandler)
signal(SIGTERM, signalHandler)

// Create the application
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no dock icon

let delegate = AppDelegate()
app.delegate = delegate

app.run()
