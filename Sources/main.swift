import AppKit

// Create the application
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no dock icon

let delegate = AppDelegate()
app.delegate = delegate

app.run()
