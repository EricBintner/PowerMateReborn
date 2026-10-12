import AppKit
import Foundation

// Signal handling for clean exit (restoring gamma).
//
// The old handler ran Swift/ObjC code (restoreGamma, NSLog, exit) directly
// inside the SIGINT/SIGTERM handler — undefined behavior: the handler can
// re-enter locks (malloc, NSLog, the ObjC runtime) held by the interrupted
// thread and deadlock at logout. Instead, block the signals on the main
// thread and let a dispatch source run the cleanup on a normal thread.
var signalSources: [DispatchSourceSignal] = []

func installSignalHandlers() {
    var blockedSignals = sigset_t()
    sigemptyset(&blockedSignals)
    sigaddset(&blockedSignals, SIGINT)
    sigaddset(&blockedSignals, SIGTERM)
    pthread_sigmask(SIG_BLOCK, &blockedSignals, nil)

    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            guard let delegate = AppDelegate.shared else { _exit(sig); return }
            delegate.brightnessController.restoreGamma()
            delegate.saveSettings()
            NSLog("PowerMateDriver: Caught signal %d, restored gamma and settings.", sig)
            _exit(sig)
        }
        source.resume()
        signalSources.append(source)
    }
}

// Install signal handlers BEFORE creating the application: pthread_sigmask
// only affects the calling thread, and threads spawned later inherit the
// mask. AppKit/libdispatch worker threads created before the block would
// receive SIGINT/SIGTERM with default disposition and kill the process
// without cleanup.
installSignalHandlers()

// Create the application
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no dock icon

let delegate = AppDelegate()
app.delegate = delegate

app.run()