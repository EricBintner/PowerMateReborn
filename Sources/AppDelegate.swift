import AppKit
import Foundation

// MARK: - Knob Modes

enum KnobMode: String, CaseIterable {
    case volume = "Volume"
    case brightness = "Brightness"
    case custom = "Custom"

    var icon: String {
        switch self {
        case .volume:     return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .custom:     return "slider.horizontal.3"
        }
    }

    var menuBarIcon: String {
        switch self {
        case .volume:     return "dial.medium.fill"
        case .brightness: return "dial.medium.fill"
        case .custom:     return "dial.medium.fill"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, PowerMateDelegate, VolumeChangeDelegate {
    private var statusItem: NSStatusItem!
    private var powerMate = PowerMateHID()
    private var volumeController = VolumeController()
    private var brightnessController = BrightnessController()

    // Multi-mode
    private var currentMode: KnobMode = .volume
    private var enabledModes: [KnobMode] = [.volume, .brightness]

    // Settings
    private var stepSize: Float = 0.03  // 3% per rotation tick
    private var ledFollowsLevel: Bool = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        volumeController.delegate = self
        powerMate.delegate = self
        powerMate.start()
        updateStatusDisplay()
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerMate.setLEDBrightness(0)
        powerMate.stop()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "PM"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            NSLog("Menu: statusItem created, button frame=%@", NSStringFromRect(button.frame))
        } else {
            NSLog("Menu: ERROR - statusItem.button is nil!")
        }

        updateStatusDisplay()
        buildMenu()
    }

    private func updateStatusDisplay() {
        guard let button = statusItem.button else { return }

        if !powerMate.isConnected {
            button.title = "PM:--"
            button.image = nil
        } else {
            switch currentMode {
            case .volume:     button.title = "PM:VOL"
            case .brightness: button.title = "PM:BRT"
            case .custom:     button.title = "PM:CUS"
            }
            button.image = NSImage(systemSymbolName: currentMode.icon, accessibilityDescription: nil)
        }
        NSLog("Menu: title='%@' connected=%d", button.title, powerMate.isConnected)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Connection status
        let statusTitle = powerMate.isConnected ? "[*] PowerMate Connected" : "[ ] PowerMate Disconnected"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Current mode indicator
        let modeItem = NSMenuItem(title: "Mode: \(currentMode.rawValue)", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        if let img = NSImage(systemSymbolName: currentMode.icon, accessibilityDescription: nil) {
            modeItem.image = img
        }
        menu.addItem(modeItem)

        let hintItem = NSMenuItem(title: "  Long-press knob to switch modes", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(NSMenuItem.separator())

        // Level display based on mode
        switch currentMode {
        case .volume:
            let vol = volumeController.getVolume()
            let volItem = NSMenuItem(title: "Volume: \(Int(vol * 100))%", action: nil, keyEquivalent: "")
            volItem.isEnabled = false
            volItem.tag = 100
            menu.addItem(volItem)

            let muteItem = NSMenuItem(title: volumeController.isMuted() ? "Muted [on]" : "Mute", action: #selector(toggleMuteClicked), keyEquivalent: "m")
            muteItem.target = self
            menu.addItem(muteItem)

            // Audio device info
            let deviceName = volumeController.activeDeviceName
            let method = volumeController.volumeMethod.rawValue
            let isSW = volumeController.isSoftwareVolume
            let deviceTag = isSW ? "SW" : "HW"
            let deviceInfoItem = NSMenuItem(title: "  [\(deviceTag)] \(deviceName) (\(method))", action: nil, keyEquivalent: "")
            deviceInfoItem.isEnabled = false
            menu.addItem(deviceInfoItem)
            if isSW {
                let swNote = NSMenuItem(title: "  (i) No native volume -- using software control", action: nil, keyEquivalent: "")
                swNote.isEnabled = false
                menu.addItem(swNote)
            }

        case .brightness:
            let br = brightnessController.getCurrentBrightness()
            let brItem = NSMenuItem(title: "Brightness: \(Int(br * 100))%", action: nil, keyEquivalent: "")
            brItem.isEnabled = false
            brItem.tag = 100
            menu.addItem(brItem)

            if !brightnessController.isAvailable {
                let warnItem = NSMenuItem(title: "  (!) Brightness control unavailable", action: nil, keyEquivalent: "")
                warnItem.isEnabled = false
                menu.addItem(warnItem)
            }

        case .custom:
            let customItem = NSMenuItem(title: "Custom mode (coming soon)", action: nil, keyEquivalent: "")
            customItem.isEnabled = false
            menu.addItem(customItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Audio device picker submenu (A9)
        let deviceMenu = NSMenu()
        let defaultID = volumeController.activeDeviceID
        for dev in volumeController.allOutputDevices {
            let isActive = dev.deviceID == defaultID
            let prefix = isActive ? "[*] " : "    "
            let volIcon = (dev.hasVolumeScalar || dev.hasChannelVolume || dev.hasVirtualMaster) ? ">>" : "--"
            let item = NSMenuItem(
                title: "\(prefix)\(volIcon) \(dev.name) — \(dev.transportName)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            if isActive {
                let methodNote = NSMenuItem(title: "      Control: \(dev.bestVolumeMethod.rawValue)", action: nil, keyEquivalent: "")
                methodNote.isEnabled = false
                deviceMenu.addItem(item)
                deviceMenu.addItem(methodNote)
            } else {
                deviceMenu.addItem(item)
            }
        }
        let deviceItem = NSMenuItem(title: "Audio Devices", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

        // Enabled modes submenu
        let modesMenu = NSMenu()
        for mode in KnobMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(toggleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = enabledModes.contains(mode) ? .on : .off
            if let img = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil) {
                item.image = img
            }
            modesMenu.addItem(item)
        }
        let modesItem = NSMenuItem(title: "Enabled Modes", action: nil, keyEquivalent: "")
        modesItem.submenu = modesMenu
        menu.addItem(modesItem)

        // Sensitivity submenu
        let sensitivityMenu = NSMenu()
        for (label, value) in [("Low (1%)", Float(0.01)), ("Medium (3%)", Float(0.03)), ("High (5%)", Float(0.05)), ("Very High (8%)", Float(0.08))] {
            let item = NSMenuItem(title: label, action: #selector(sensitivityChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            if abs(stepSize - value) < 0.001 {
                item.state = .on
            }
            sensitivityMenu.addItem(item)
        }
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)

        // LED submenu
        let ledMenu = NSMenu()
        let ledFollowItem = NSMenuItem(title: "Follow Level", action: #selector(ledFollowLevel(_:)), keyEquivalent: "")
        ledFollowItem.target = self
        ledFollowItem.state = ledFollowsLevel ? .on : .off
        ledMenu.addItem(ledFollowItem)
        ledMenu.addItem(NSMenuItem.separator())

        for (title, action) in [("Off", #selector(ledOff)), ("Dim", #selector(ledDim)), ("Bright", #selector(ledBright)), ("Breathe (slow fade in/out)", #selector(ledPulse))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            ledMenu.addItem(item)
        }

        let ledItem = NSMenuItem(title: "LED", action: nil, keyEquivalent: "")
        ledItem.submenu = ledMenu
        menu.addItem(ledItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit PowerMate Driver", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshMenu() {
        buildMenu()
    }

    // MARK: - Mode Switching

    private func cycleMode() {
        guard enabledModes.count > 1 else { return }
        if let idx = enabledModes.firstIndex(of: currentMode) {
            let nextIdx = (idx + 1) % enabledModes.count
            currentMode = enabledModes[nextIdx]
        } else {
            currentMode = enabledModes[0]
        }
        NSLog("Mode switched to: \(currentMode.rawValue)")
        updateStatusDisplay()
        updateLEDForLevel()
        refreshMenu()

        // Flash LED briefly to indicate mode switch
        flashLEDForModeSwitch()
    }

    private func flashLEDForModeSwitch() {
        let savedBrightness = powerMate.ledBrightness
        powerMate.setLEDBrightness(255)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.powerMate.setLEDBrightness(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.powerMate.setLEDBrightness(255)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self else { return }
                    if self.ledFollowsLevel {
                        self.updateLEDForLevel()
                    } else {
                        self.powerMate.setLEDBrightness(savedBrightness)
                    }
                }
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleMuteClicked() {
        volumeController.toggleMute()
        updateLEDForLevel()
        refreshMenu()
    }

    @objc private func toggleMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = KnobMode(rawValue: rawValue) else { return }

        if enabledModes.contains(mode) {
            // Don't allow disabling the last mode or the current mode
            if enabledModes.count > 1 {
                enabledModes.removeAll { $0 == mode }
                if currentMode == mode {
                    currentMode = enabledModes[0]
                    updateStatusDisplay()
                    updateLEDForLevel()
                }
            }
        } else {
            enabledModes.append(mode)
        }
        refreshMenu()
    }

    @objc private func sensitivityChanged(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Float {
            stepSize = value
        }
        refreshMenu()
    }

    @objc private func ledFollowLevel(_ sender: NSMenuItem) {
        ledFollowsLevel.toggle()
        if ledFollowsLevel { updateLEDForLevel() }
        refreshMenu()
    }

    @objc private func ledOff() {
        ledFollowsLevel = false
        powerMate.setLEDBrightness(0)
        refreshMenu()
    }

    @objc private func ledDim() {
        ledFollowsLevel = false
        powerMate.setLEDBrightness(64)
        refreshMenu()
    }

    @objc private func ledBright() {
        ledFollowsLevel = false
        powerMate.setLEDBrightness(255)
        refreshMenu()
    }

    @objc private func ledPulse() {
        ledFollowsLevel = false
        powerMate.setLEDPulse(speed: 12, brightness: 255)
        refreshMenu()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - LED Helpers

    private func updateLEDForLevel() {
        guard ledFollowsLevel else { return }

        var level: Float = 0
        switch currentMode {
        case .volume:
            level = volumeController.isMuted() ? 0 : volumeController.getVolume()
        case .brightness:
            level = brightnessController.getCurrentBrightness()
        case .custom:
            level = 0.5
        }
        let ledVal = UInt8(max(0, min(255, level * 255)))
        powerMate.setLEDBrightness(ledVal)
    }

    // MARK: - PowerMateDelegate

    func powerMateDidConnect() {
        NSLog("PowerMate connected")
        updateStatusDisplay()
        refreshMenu()
        updateLEDForLevel()
    }

    func powerMateDidDisconnect() {
        NSLog("PowerMate disconnected")
        updateStatusDisplay()
        refreshMenu()
    }

    func powerMateDidRotate(delta: Int) {
        let adjustment = Float(delta) * stepSize

        switch currentMode {
        case .volume:
            volumeController.adjustVolume(by: adjustment)
            let vol = volumeController.getVolume()
            NSLog("Volume: \(Int(vol * 100))%% (delta: \(delta))")

        case .brightness:
            brightnessController.adjustBrightness(by: adjustment)
            let br = brightnessController.getCurrentBrightness()
            NSLog("Brightness: \(Int(br * 100))%% (delta: \(delta))")

        case .custom:
            NSLog("Custom mode rotation: \(delta)")
        }

        updateLEDForLevel()

        // Live-update menu if open
        if let levelItem = statusItem.menu?.item(withTag: 100) {
            switch currentMode {
            case .volume:
                levelItem.title = "Volume: \(Int(volumeController.getVolume() * 100))%"
            case .brightness:
                levelItem.title = "Brightness: \(Int(brightnessController.getCurrentBrightness() * 100))%"
            case .custom:
                break
            }
        }
    }

    func powerMateButtonPressed() {
        NSLog("PowerMate short press — mode action")
        switch currentMode {
        case .volume:
            volumeController.toggleMute()
            NSLog("Mute toggled: \(volumeController.isMuted())")
        case .brightness:
            brightnessController.sleepDisplay()
            NSLog("Display sleep triggered")
        case .custom:
            NSLog("Custom button action (not yet implemented)")
        }
        updateLEDForLevel()
        refreshMenu()
    }

    func powerMateButtonLongPressed() {
        NSLog("PowerMate long press — cycling mode")
        cycleMode()
    }

    // MARK: - VolumeChangeDelegate

    func volumeDidChange(volume: Float, muted: Bool) {
        // External volume change (keyboard, Control Center, another app)
        updateLEDForLevel()
        if let levelItem = statusItem.menu?.item(withTag: 100), currentMode == .volume {
            levelItem.title = "Volume: \(Int(volume * 100))%"
        }
    }

    func audioDeviceDidChange(deviceName: String, method: VolumeControlMethod) {
        NSLog("Audio device changed to: \(deviceName) (\(method.rawValue))")
        updateLEDForLevel()
        refreshMenu()
    }
}
