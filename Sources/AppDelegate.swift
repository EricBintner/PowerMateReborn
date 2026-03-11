import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import Sparkle

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

    var menuBarImage: NSImage {
        switch self {
        case .volume:     return MenuBarIcon.volume()
        case .brightness: return MenuBarIcon.brightness()
        case .custom:     return MenuBarIcon.custom()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, PowerMateDelegate, VolumeChangeDelegate, SPUUpdaterDelegate {
    private var statusItem: NSStatusItem!
    private var powerMate = PowerMateHID()
    private var volumeController = VolumeController()
    private var brightnessController = BrightnessController()
    private var updaterController: SPUStandardUpdaterController!

    // Multi-mode
    private var currentMode: KnobMode = .volume
    private var enabledModes: [KnobMode] = [.volume, .brightness]

    // Settings
    private var stepSize: Float = 0.03  // 3% per rotation tick
    private var ledFollowsLevel: Bool = true

    // Launch at login
    private var launchAtLogin: Bool = false

    // Snap-to-value state (double-tap toggles)
    private var volumeBeforeSnap: Float?
    private var brightnessBeforeSnap: Float?
    private var volumeSnapValue: Float = 0.20      // 20%
    private var brightnessSnapValue: Float = 0.15  // 15% (night mode)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only initialize Sparkle if running inside a proper .app bundle (prevents errors during `swift run`)
        if Bundle.main.bundleURL.pathExtension == "app" {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        
        loadSettings()
        setupMenuBar()
        volumeController.delegate = self
        powerMate.delegate = self
        powerMate.start()
        updateStatusDisplay()
    }

    func applicationWillTerminate(_ notification: Notification) {
        brightnessController.restoreGamma()
        powerMate.setLEDBrightness(0)
        powerMate.stop()
        saveSettings()
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

        button.title = ""
        if !powerMate.isConnected {
            button.image = MenuBarIcon.disconnected()
        } else {
            button.image = currentMode.menuBarImage
        }
        button.imagePosition = .imageOnly
        NSLog("Menu: title='%@' connected=%d", button.title, powerMate.isConnected)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // --- Connection Status ---
        let statusTitle = powerMate.isConnected ? "PowerMate Connected" : "PowerMate Disconnected"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        let dotColor: NSColor = powerMate.isConnected ? .systemGreen : .systemGray
        if let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            let coloredImage = img.copy() as! NSImage
            coloredImage.isTemplate = false
            coloredImage.lockFocus()
            dotColor.set()
            let rect = NSRect(origin: .zero, size: img.size)
            rect.fill(using: .sourceAtop)
            coloredImage.unlockFocus()
            statusMenuItem.image = coloredImage
        }
        menu.addItem(statusMenuItem)
        
        let hintItem = NSMenuItem(title: "Quick Start Guide", action: #selector(showQuickStart), keyEquivalent: "")
        hintItem.target = self
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) {
            hintItem.image = img
        }
        menu.addItem(hintItem)

        menu.addItem(NSMenuItem.separator())

        // --- Active Mode Selection ---
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        
        for mode in KnobMode.allCases {
            guard enabledModes.contains(mode) else { continue }
            let isCurrent = (mode == currentMode)
            let item = NSMenuItem(title: mode.rawValue, action: #selector(switchToMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            if let img = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil) {
                item.image = img
            }
            if isCurrent { item.state = .on }
            modeMenu.addItem(item)
        }
        
        let modeHeader = NSMenuItem(title: "Active Mode: \(currentMode.rawValue)", action: nil, keyEquivalent: "")
        modeHeader.submenu = modeMenu
        if let img = NSImage(systemSymbolName: currentMode.icon, accessibilityDescription: nil) {
            modeHeader.image = img
        }
        menu.addItem(modeHeader)

        menu.addItem(NSMenuItem.separator())

        // --- Controls Status ---
        let vol = volumeController.getVolume()
        let volLabel = NSMenuItem(title: "Volume: \(Int(vol * 100))%", action: nil, keyEquivalent: "")
        volLabel.tag = 100
        if let img = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil) {
            volLabel.image = img
        }
        menu.addItem(volLabel)

        let muteItem = NSMenuItem(title: volumeController.isMuted() ? "Unmute" : "Mute", action: #selector(toggleMuteClicked), keyEquivalent: "m")
        muteItem.indentationLevel = 3 // Increased indentation further
        muteItem.target = self
        menu.addItem(muteItem)

        let br = brightnessController.getCurrentBrightness()
        let brLabel = NSMenuItem(title: "Brightness: \(Int(br * 100))%", action: nil, keyEquivalent: "")
        brLabel.tag = 101
        if let img = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) {
            brLabel.image = img
        }
        menu.addItem(brLabel)

        menu.addItem(NSMenuItem.separator())

        // --- Settings Submenus ---

        // Output Device Picker
        let deviceMenu = NSMenu()
        deviceMenu.autoenablesItems = false
        let defaultID = volumeController.activeDeviceID
        for dev in volumeController.allOutputDevices {
            let isActive = dev.deviceID == defaultID
            // Clean up name: remove common suffixes for a cleaner native look
            var cleanName = dev.name
            if cleanName.hasSuffix(" Speakers") { cleanName = cleanName.replacingOccurrences(of: " Speakers", with: "") }
            
            let item = NSMenuItem(
                title: cleanName,
                action: #selector(switchAudioDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(dev.deviceID)
            if isActive { item.state = .on }
            
            // Add icon indicating control capability
            let iconName = (dev.hasVolumeScalar || dev.hasChannelVolume || dev.hasVirtualMaster) ? "speaker.wave.2.fill" : "speaker.slash.fill"
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                item.image = img
            }
            
            deviceMenu.addItem(item)
        }
        let deviceItem = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        if let img = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil) {
            deviceItem.image = img
        }
        menu.addItem(deviceItem)

        // Enabled Modes Config
        let modesMenu = NSMenu()
        modesMenu.autoenablesItems = false
        for mode in KnobMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(toggleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = enabledModes.contains(mode) ? .on : .off
            modesMenu.addItem(item)
        }
        let modesItem = NSMenuItem(title: "Enabled Modes", action: nil, keyEquivalent: "")
        modesItem.submenu = modesMenu
        if let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil) {
            modesItem.image = img
        }
        menu.addItem(modesItem)

        // Sensitivity Config
        let sensitivityMenu = NSMenu()
        sensitivityMenu.autoenablesItems = false
        for (label, value) in [("Low (1%)", Float(0.01)), ("Medium (3%)", Float(0.03)), ("High (5%)", Float(0.05)), ("Very High (8%)", Float(0.08))] {
            let item = NSMenuItem(title: label, action: #selector(sensitivityChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            if abs(stepSize - value) < 0.001 { item.state = .on }
            sensitivityMenu.addItem(item)
        }
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = sensitivityMenu
        if let img = NSImage(systemSymbolName: "dial.min", accessibilityDescription: nil) {
            sensitivityItem.image = img
        }
        menu.addItem(sensitivityItem)

        // LED Config
        let ledMenu = NSMenu()
        ledMenu.autoenablesItems = false
        let ledFollowItem = NSMenuItem(title: "Follow Level", action: #selector(ledFollowLevel(_:)), keyEquivalent: "")
        ledFollowItem.target = self
        ledFollowItem.state = ledFollowsLevel ? .on : .off
        ledMenu.addItem(ledFollowItem)
        ledMenu.addItem(NSMenuItem.separator())

        for (title, action) in [("Off", #selector(ledOff)), ("Dim", #selector(ledDim)), ("Bright", #selector(ledBright)), ("Breathe", #selector(ledPulse))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            ledMenu.addItem(item)
        }

        let ledItem = NSMenuItem(title: "LED Effect", action: nil, keyEquivalent: "")
        ledItem.submenu = ledMenu
        if let img = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil) {
            ledItem.image = img
        }
        menu.addItem(ledItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login toggle
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLogin ? .on : .off
        if let img = NSImage(systemSymbolName: "power", accessibilityDescription: nil) {
            loginItem.image = img
        }
        menu.addItem(loginItem)

        // Add update check menu item
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        // About
        let aboutItem = NSMenuItem(title: "About PowerMate...", action: #selector(showAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit PowerMate", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuLevels()
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

    @objc private func switchToMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = KnobMode(rawValue: rawValue) else { return }
        currentMode = mode
        NSLog("Mode switched to: %@", mode.rawValue)
        updateStatusDisplay()
        updateLEDForLevel()
        refreshMenu()
    }

    @objc private func switchAudioDevice(_ sender: NSMenuItem) {
        let deviceID = AudioDeviceID(sender.tag)
        volumeController.setActiveDevice(deviceID)
        NSLog("Audio device switched to ID %d", deviceID)
        updateLEDForLevel()
        refreshMenu()
    }

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

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin.toggle()
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                NSLog("Launch at login: enabled")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("Launch at login: disabled")
            }
        } catch {
            NSLog("Launch at login failed: %@", error.localizedDescription)
            launchAtLogin.toggle() // revert on failure
        }
        refreshMenu()
    }

    @objc private func showAboutWindow() {
        let alert = NSAlert()
        alert.messageText = "PowerMateReborn"
        alert.alertStyle = .informational

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 12

        // Version info
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        container.addArrangedSubview(versionLabel)

        // Device status
        let connected = powerMate.isConnected
        let deviceStatus = connected ? "🟢 PowerMate Connected" : "⚪️ PowerMate Disconnected"
        let statusLabel = NSTextField(labelWithString: deviceStatus)
        statusLabel.font = NSFont.boldSystemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        container.addArrangedSubview(statusLabel)

        // Audio info
        let audioInfo = "Audio: \(volumeController.activeDeviceName) (\(volumeController.volumeMethod.rawValue))"
        let audioLabel = NSTextField(labelWithString: audioInfo)
        audioLabel.font = NSFont.systemFont(ofSize: 12)
        audioLabel.textColor = .secondaryLabelColor
        audioLabel.alignment = .center
        container.addArrangedSubview(audioLabel)

        // Brightness info
        let brightnessInfo = "Brightness: \(brightnessController.method.rawValue)"
        let brightnessLabel = NSTextField(labelWithString: brightnessInfo)
        brightnessLabel.font = NSFont.systemFont(ofSize: 12)
        brightnessLabel.textColor = .secondaryLabelColor
        brightnessLabel.alignment = .center
        container.addArrangedSubview(brightnessLabel)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
        container.addArrangedSubview(spacer)

        // Report Issue button
        let issueButton = NSButton(title: "Report Issue on GitHub", target: self, action: #selector(openGitHubIssues))
        issueButton.bezelStyle = .rounded
        container.addArrangedSubview(issueButton)

        container.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(origin: .zero, size: container.fittingSize)

        alert.accessoryView = container
        
        // Create custom composite icon: Folder + Current Mode Symbol
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        let compositeImage = NSImage(size: NSSize(width: 128, height: 128))
        compositeImage.lockFocus()
        folderIcon.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        
        if let overlay = NSImage(systemSymbolName: currentMode.icon, accessibilityDescription: nil) {
            // Render the overlay symbol purely white
            let overlayImg = NSImage(size: NSSize(width: 64, height: 64))
            overlayImg.lockFocus()
            overlay.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
            NSColor.white.set()
            NSRect(x: 0, y: 0, width: 64, height: 64).fill(using: .sourceAtop)
            overlayImg.unlockFocus()
            
            // Add a drop shadow for depth
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowBlurRadius = 5
            shadow.set()
            
            // Draw centered but slightly lower so it sits naturally on the folder body
            overlayImg.draw(in: NSRect(x: 32, y: 24, width: 64, height: 64))
        }
        compositeImage.unlockFocus()
        alert.icon = compositeImage
        
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openGitHubIssues() {
        if let url = URL(string: "https://github.com/EricBintner/PowerMateReborn/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showQuickStart() {
        let alert = NSAlert()
        alert.messageText = "PowerMate Controls"
        alert.alertStyle = .informational
        
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 10
        
        // 1. Large Custom Image
        if let iconPath = Bundle.module.path(forResource: "powermate", ofType: "png") ?? Bundle.main.path(forResource: "powermate", ofType: "png"),
           let img = NSImage(contentsOfFile: iconPath) {
            let imageView = NSImageView(image: img)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 250),
                imageView.heightAnchor.constraint(equalToConstant: 95)
            ])
            container.addArrangedSubview(imageView)
        }
        
        // 2. Grid Table for Controls
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        
        let actions = [
            ("Turn knob", "Adjust volume or brightness"),
            ("Press down", "Mute audio or sleep display"),
            ("Double-tap", "Snap to preset (20% vol / dim)"),
            ("Press & hold", "Switch between Volume & Brightness")
        ]
        
        for (action, desc) in actions {
            let actionLabel = NSTextField(labelWithString: action)
            actionLabel.font = NSFont.boldSystemFont(ofSize: 13)
            actionLabel.alignment = .right
            actionLabel.isEditable = false
            actionLabel.isSelectable = false
            actionLabel.drawsBackground = false
            actionLabel.isBordered = false
            
            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = NSFont.systemFont(ofSize: 13)
            descLabel.alignment = .left
            descLabel.isEditable = false
            descLabel.isSelectable = false
            descLabel.drawsBackground = false
            descLabel.isBordered = false
            
            grid.addRow(with: [actionLabel, descLabel])
        }
        
        container.addArrangedSubview(grid)
        
        // 3. Footer Text
        let footer = NSTextField(labelWithString: "You can configure the active mode, output device, and rotation sensitivity using this menu.")
        footer.font = NSFont.systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.isEditable = false
        footer.isSelectable = false
        footer.drawsBackground = false
        footer.isBordered = false
        container.addArrangedSubview(footer)
        
        // Add padding
        container.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        container.layoutSubtreeIfNeeded()
        
        let requiredSize = container.fittingSize
        
        // Wrap the container in an explicit fixed-size NSView. 
        // NSAlert requires the accessoryView to have a fully specified frame.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: requiredSize.height))
        container.frame = wrapper.bounds
        container.autoresizingMask = [.width, .height]
        wrapper.addSubview(container)
        
        alert.accessoryView = wrapper
        
        // Hide standard icon since we added a large one to the accessory view
        alert.icon = NSImage(size: NSSize(width: 1, height: 1))
        
        alert.addButton(withTitle: "Got it")
        
        // Ensure the alert appears in front of everything
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        NSLog("Sparkle: Appcast loaded successfully")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Sparkle: Found valid update to version %@", item.versionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("Sparkle: No updates available")
    }

    func updater(_ updater: SPUUpdater, failedToLoadAppcastWithError error: Error) {
        NSLog("Sparkle: Failed to load appcast: %@", error.localizedDescription)
    }

    // MARK: - Menu Helpers

    private func updateMenuLevels() {
        guard let menu = statusItem.menu else { return }
        
        if let volItem = menu.item(withTag: 100) {
            volItem.attributedTitle = attributedLevelTitle(
                "Volume",
                level: volumeController.getVolume(),
                isVirtual: volumeController.isSoftwareVolume,
                isAvailable: true
            )
        }
        
        if let brItem = menu.item(withTag: 101) {
            brItem.attributedTitle = attributedLevelTitle(
                "Brightness",
                level: brightnessController.getCurrentBrightness(),
                isVirtual: brightnessController.isVirtual,
                isAvailable: brightnessController.isAvailable
            )
        }
    }

    private func attributedLevelTitle(_ base: String, level: Float, isVirtual: Bool, isAvailable: Bool) -> NSAttributedString {
        let percentage = "\(Int(level * 100))%"
        let methodText = !isAvailable ? "Unavailable" : (isVirtual ? "Virtual" : "Hardware")
        
        let fullString = "\(base): \(percentage)   \(methodText)"
        
        let attrStr = NSMutableAttributedString(string: fullString)
        let fullRange = NSRange(location: 0, length: attrStr.length)
        
        attrStr.addAttribute(.font, value: NSFont.menuBarFont(ofSize: 0), range: fullRange)
        
        if let range = fullString.range(of: methodText) {
            let nsRange = NSRange(range, in: fullString)
            attrStr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: nsRange)
            attrStr.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: nsRange)
        }
        
        return attrStr
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
        case .brightness:
            brightnessController.adjustBrightness(by: adjustment)
        case .custom:
            break
        }
        updateLEDForLevel()
        updateMenuLevels()
    }

    func powerMateButtonPressed() {
        NSLog("Button: single press [%@]", currentMode.rawValue)
        switch currentMode {
        case .volume:
            volumeController.toggleMute()
        case .brightness:
            brightnessController.sleepDisplay()
        case .custom:
            break
        }
        updateLEDForLevel()
        refreshMenu()
    }

    func powerMateButtonDoubleTapped() {
        NSLog("Button: double tap [%@]", currentMode.rawValue)
        switch currentMode {
        case .volume:
            // Toggle snap-to-value: first double-tap snaps to 20%, second restores
            if let saved = volumeBeforeSnap {
                volumeController.setVolume(saved)
                volumeBeforeSnap = nil
                NSLog("Volume: restored to %.0f%%", saved * 100)
            } else {
                volumeBeforeSnap = volumeController.getVolume()
                volumeController.setVolume(volumeSnapValue)
                NSLog("Volume: snapped to %.0f%%", volumeSnapValue * 100)
            }

        case .brightness:
            // Toggle night mode: first double-tap dims to 15%, second restores
            if let saved = brightnessBeforeSnap {
                brightnessController.setBrightness(saved)
                brightnessBeforeSnap = nil
                NSLog("Brightness: restored to %.0f%%", saved * 100)
            } else {
                brightnessBeforeSnap = brightnessController.getCurrentBrightness()
                brightnessController.setBrightness(brightnessSnapValue)
                NSLog("Brightness: night mode %.0f%%", brightnessSnapValue * 100)
            }

        case .custom:
            break
        }
        updateLEDForLevel()
        refreshMenu()
    }

    func powerMateButtonLongPressed() {
        NSLog("Button: long press -> cycle mode")
        cycleMode()
    }

    // MARK: - VolumeChangeDelegate

    func volumeDidChange(volume: Float, muted: Bool) {
        // External volume change (keyboard, Control Center, another app)
        updateLEDForLevel()
        updateMenuLevels()
    }

    func audioDeviceDidChange(deviceName: String, method: VolumeControlMethod) {
        NSLog("Audio device changed to: \(deviceName) (\(method.rawValue))")
        updateLEDForLevel()
        refreshMenu()
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        let d = UserDefaults.standard
        if let mode = d.string(forKey: "powermate.currentMode"), let m = KnobMode(rawValue: mode) {
            currentMode = m
        }
        if let modes = d.array(forKey: "powermate.enabledModes") as? [String] {
            let parsed = modes.compactMap { KnobMode(rawValue: $0) }
            if !parsed.isEmpty { enabledModes = parsed }
        }
        if d.object(forKey: "powermate.stepSize") != nil {
            stepSize = d.float(forKey: "powermate.stepSize")
        }
        if d.object(forKey: "powermate.ledFollowsLevel") != nil {
            ledFollowsLevel = d.bool(forKey: "powermate.ledFollowsLevel")
        }
        if d.object(forKey: "powermate.longPressThreshold") != nil {
            powerMate.longPressThreshold = d.double(forKey: "powermate.longPressThreshold")
        }
        if d.object(forKey: "powermate.doubleTapInterval") != nil {
            powerMate.doubleTapInterval = d.double(forKey: "powermate.doubleTapInterval")
        }
        if d.object(forKey: "powermate.volume.snapValue") != nil {
            volumeSnapValue = d.float(forKey: "powermate.volume.snapValue")
        }
        if d.object(forKey: "powermate.brightness.snapValue") != nil {
            brightnessSnapValue = d.float(forKey: "powermate.brightness.snapValue")
        }
        // Sync launch-at-login with actual SMAppService status
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        NSLog("Settings: mode=%@ step=%.0f%% led=%d login=%d", currentMode.rawValue, stepSize * 100, ledFollowsLevel, launchAtLogin)
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(currentMode.rawValue, forKey: "powermate.currentMode")
        d.set(enabledModes.map { $0.rawValue }, forKey: "powermate.enabledModes")
        d.set(stepSize, forKey: "powermate.stepSize")
        d.set(ledFollowsLevel, forKey: "powermate.ledFollowsLevel")
        d.set(powerMate.longPressThreshold, forKey: "powermate.longPressThreshold")
        d.set(powerMate.doubleTapInterval, forKey: "powermate.doubleTapInterval")
        d.set(volumeSnapValue, forKey: "powermate.volume.snapValue")
        d.set(brightnessSnapValue, forKey: "powermate.brightness.snapValue")
    }
}
