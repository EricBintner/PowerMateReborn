import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI

// MARK: - Knob Modes

enum KnobMode: String, CaseIterable {
    case volume = "Volume"
    case brightness = "Brightness"
    case midi = "MIDI"
    case custom = "Custom"

    var icon: String {
        switch self {
        case .volume:     return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .midi:       return "pianokeys"
        case .custom:     return "slider.horizontal.3"
        }
    }

    var menuBarImage: NSImage {
        switch self {
        case .volume:     return MenuBarIcon.volume()
        case .brightness: return MenuBarIcon.brightness()
        case .midi:       return MenuBarIcon.custom()  // reuse for now
        case .custom:     return MenuBarIcon.custom()
        }
    }
}

/// LED behavior as a single setting (Settings window). Consolidates the old
/// menu's Follow Level toggle + Off/Dim/Brightness static actions.
enum LEDMode: Equatable {
    case followLevel
    case off
    case dim
    case bright
}

class AppDelegate: NSObject, NSApplicationDelegate, PowerMateDelegate, VolumeChangeDelegate, SPUUpdaterDelegate {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var powerMate = PowerMateManager()
    private(set) var volumeController = VolumeController()
    private(set) var brightnessController = BrightnessController()
    private(set) var midiController = MIDIController()
    private let customEngine = CustomModeEngine.shared
    private var updaterController: SPUStandardUpdaterController!
    private let osd = OSDOverlay()

    // Multi-mode
    private(set) var currentMode: KnobMode = .volume
    private(set) var enabledModes: [KnobMode] = [.volume, .brightness]

    // Settings
    private(set) var stepSize: Float = 0.03  // 3% per rotation tick
    private(set) var ledFollowsLevel: Bool = true

    // Launch at login
    private(set) var launchAtLogin: Bool = false

    // Snap-to-value state (double-tap toggles)
    private var volumeBeforeSnap: Float?
    private var brightnessBeforeSnap: Float?
    private(set) var volumeSnapValue: Float = 0.20      // 20%
    private(set) var brightnessSnapValue: Float = 0.67  // 67%

    // UI Window Controllers
    private var settingsWindowController: NSWindowController?
    private var issueReportWindowController: NSWindowController?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture stderr (all NSLog output) to a file so issue reports can include logs.
        // Keep this first: transports log connection events right after this.
        AppLogCapture.start()

        // Only initialize Sparkle when running inside a proper .app bundle AND
        // the update feed is fully configured. Starting the updater with a
        // placeholder or missing SUPublicEDKey produces a blocking "Unable to
        // Check For Updates" error sheet at launch (issue #1), so verify the
        // EdDSA key looks real (non-placeholder base64, 43 chars + padding)
        // before handing Sparkle control.
        if Bundle.main.bundleURL.pathExtension == "app", isSparkleConfigured {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        
        loadSettings()
        setupMenuBar()
        volumeController.delegate = self
        let usbTransport = PowerMateUSBTransport()
        let bleTransport = PowerMateBLETransport()
        powerMate.addTransport(usbTransport)
        powerMate.addTransport(bleTransport)
        powerMate.delegate = self
        powerMate.start()
        updateStatusDisplay()
    }

    func applicationWillTerminate(_ notification: Notification) {
        brightnessController.restoreGamma()
        customEngine.shutdown()
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
            button.setAccessibilityLabel("PowerMate Disconnected")
        } else {
            button.image = currentMode.menuBarImage
            button.setAccessibilityLabel("PowerMate: \(currentMode.rawValue) Mode")
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
        if let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: powerMate.isConnected ? "Connected" : "Disconnected") {
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
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Quick Start Guide") {
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
        // Use an empty image to perfectly align the text with the item above it
        if let templateImg = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil) {
            muteItem.image = NSImage(size: templateImg.size)
        }
        muteItem.target = self
        menu.addItem(muteItem)

        let br = brightnessController.getCurrentBrightness()
        let brMethod = brightnessController.method
        let brSuffix = brMethod.isSoftware ? "  [Software]" : ""
        let displayName = brightnessController.activeDisplayName
        let brLabel = NSMenuItem(title: "Brightness: \(Int(br * 100))%\(brSuffix) — \(displayName)", action: nil, keyEquivalent: "")
        brLabel.tag = 101
        // Use warning icon when using software/gamma dimming
        let brIcon = brMethod.isSoftware ? "sun.max.trianglebadge.exclamationmark" : "sun.max.fill"
        if let img = NSImage(systemSymbolName: brIcon, accessibilityDescription: nil) ??
           NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) {
            brLabel.image = img
        }
        menu.addItem(brLabel)

        // Brightness warning when using software dimming
        if brMethod.isSoftware {
            let warnItem = NSMenuItem(title: "Using software dimming (backlight unchanged)", action: nil, keyEquivalent: "")
            // Use an empty image to perfectly align the text with the item above it
            if let templateImg = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) {
                warnItem.image = NSImage(size: templateImg.size)
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            warnItem.attributedTitle = NSAttributedString(string: warnItem.title, attributes: attrs)
            menu.addItem(warnItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Settings — all advanced configuration lives in the Settings window.
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) {
            settingsItem.image = NSImage(size: templateImg.size)
        }
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About PowerMate...", action: #selector(showAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) {
            aboutItem.image = NSImage(size: templateImg.size)
        }
        menu.addItem(aboutItem)

        // Report Issue (above Check for Updates, matching the About dialog entry point)
        let reportItem = NSMenuItem(title: "Report Issue...", action: #selector(showIssueReporter), keyEquivalent: "")
        reportItem.target = self
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: nil) {
            reportItem.image = NSImage(size: templateImg.size)
        }
        menu.addItem(reportItem)

        // Add update check menu item
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        if updaterController == nil {
            updateItem.isEnabled = false
        }
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) {
            updateItem.image = NSImage(size: templateImg.size)
        }
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Quit PowerMate", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "power.circle", accessibilityDescription: nil) {
            quitItem.image = NSImage(size: templateImg.size)
        }
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

    @objc private func toggleMuteClicked() {
        volumeController.toggleMute()
        updateLEDForLevel()
        refreshMenu()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Settings Mutators
    // Single entry points for changing settings (used by the Settings window).
    // Each: apply -> persist -> side effects -> refresh menu/state as needed ->
    // notify SettingsModel so the Settings window re-syncs.

    func setModeEnabled(_ mode: KnobMode, _ enabled: Bool) {
        if enabled {
            if !enabledModes.contains(mode) {
                enabledModes.append(mode)
            }
        } else if enabledModes.count > 1, enabledModes.contains(mode) {
            // Don't allow disabling the last enabled mode
            enabledModes.removeAll { $0 == mode }
            if currentMode == mode {
                currentMode = enabledModes[0]
                updateStatusDisplay()
                updateLEDForLevel()
            }
        } else {
            return  // last enabled mode: refuse
        }
        saveSettings()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func setActiveDevice(_ deviceID: AudioDeviceID) {
        guard deviceID != volumeController.activeDeviceID else { return }
        volumeController.setActiveDevice(deviceID)
        // Remember this preference: "when current default is X, use device Y"
        let defaultID = volumeController.allOutputDevices.first(where: {
            // Find the actual system default (before our redirect)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var sysDefault = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &sysDefault)
            return $0.deviceID == sysDefault
        })?.uid ?? ""
        if !defaultID.isEmpty {
            var prefs = UserDefaults.standard.dictionary(forKey: "powermate.deviceRouting") as? [String: String] ?? [:]
            let targetUID = volumeController.allOutputDevices.first(where: { $0.deviceID == deviceID })?.uid ?? ""
            if !targetUID.isEmpty {
                prefs[defaultID] = targetUID
                UserDefaults.standard.set(prefs, forKey: "powermate.deviceRouting")
                NSLog("Audio: remembered routing %@ -> %@", defaultID, targetUID)
            }
        }
        NSLog("Audio device switched to ID %d", deviceID)
        updateLEDForLevel()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func setStepSize(_ value: Float) {
        guard value != stepSize else { return }
        stepSize = value
        saveSettings()
        SettingsModel.shared.refresh()
    }

    func setVolumeSnap(_ value: Float) {
        guard value != volumeSnapValue else { return }
        volumeSnapValue = value
        saveSettings()
        SettingsModel.shared.refresh()
    }

    func setBrightnessSnap(_ value: Float) {
        guard value != brightnessSnapValue else { return }
        brightnessSnapValue = value
        saveSettings()
        SettingsModel.shared.refresh()
    }

    func setLEDMode(_ mode: LEDMode) {
        switch mode {
        case .followLevel:
            ledFollowsLevel = true
            updateLEDForLevel()
        case .off:
            ledFollowsLevel = false
            powerMate.setLEDBrightness(0)
        case .dim:
            ledFollowsLevel = false
            powerMate.setLEDBrightness(64)
        case .bright:
            ledFollowsLevel = false
            powerMate.setLEDBrightness(255)
        }
        saveSettings()
        SettingsModel.shared.refresh()
    }

    func setMIDICC(_ cc: UInt8) {
        guard cc != midiController.ccNumber else { return }
        midiController.ccNumber = cc
        NSLog("MIDI: CC number changed to %d", cc)
        saveSettings()
        SettingsModel.shared.refresh()
    }

    func setMIDIChannel(_ channel: UInt8) {  // channel is 0-indexed
        guard channel != midiController.channel else { return }
        midiController.channel = channel
        NSLog("MIDI: channel changed to %d (0-based)", channel)
        saveSettings()
        SettingsModel.shared.refresh()
    }

    func setDDCEnabled(_ enabled: Bool) {
        guard enabled != brightnessController.ddcController.isEnabled else { return }
        brightnessController.ddcController.isEnabled = enabled
        NSLog("DDC/CI: %@", enabled ? "enabled" : "disabled")
        if enabled {
            brightnessController.reprobeDisplays(force: true)
        }
        UserDefaults.standard.set(enabled, forKey: "powermate.ddc.enabled")
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func setSyncDisplays(_ enabled: Bool) {
        guard enabled != brightnessController.syncDisplays else { return }
        brightnessController.syncDisplays = enabled
        NSLog("Brightness: Sync %@", enabled ? "ON" : "OFF")
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin else { return }
        launchAtLogin = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
                NSLog("Launch at login: enabled")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("Launch at login: disabled")
            }
        } catch {
            NSLog("Launch at login failed: %@", error.localizedDescription)
            launchAtLogin = !enabled  // revert on failure
        }
        SettingsModel.shared.refresh()
    }

    func setLongPressThreshold(_ seconds: Double) {
        powerMate.longPressThreshold = seconds
        UserDefaults.standard.set(seconds, forKey: "powermate.longPressThreshold")
        SettingsModel.shared.refresh()
    }

    func setDoubleTapInterval(_ seconds: Double) {
        powerMate.doubleTapInterval = seconds
        UserDefaults.standard.set(seconds, forKey: "powermate.doubleTapInterval")
        SettingsModel.shared.refresh()
    }

    // Read accessors for the Settings window (powerMate is private)
    var longPressThreshold: Double { powerMate.longPressThreshold }
    var doubleTapInterval: Double { powerMate.doubleTapInterval }
    var powerMateLEDBrightness: UInt8 { powerMate.ledBrightness }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// True when the Sparkle update feed is configured with a real (non-placeholder)
    /// EdDSA public key and feed URL. Used to decide whether starting the updater is safe.
    private var isSparkleConfigured: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let edKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            NSLog("Sparkle: update feed not configured — updater disabled")
            return false
        }
        let trimmedFeed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFeed.isEmpty, trimmedFeed.hasPrefix("https://") else {
            NSLog("Sparkle: SUFeedURL invalid — updater disabled")
            return false
        }
        let trimmedKey = edKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ed25519 public keys are 32 bytes -> 43 base64 chars + '=' padding.
        // Reject empty/placeholder keys ("REPLACE_WITH_YOUR_EDDSA_PUBLIC_KEY" etc.).
        guard trimmedKey.count == 44, trimmedKey.hasSuffix("="),
              !trimmedKey.uppercased().contains("REPLACE_WITH") else {
            NSLog("Sparkle: SUPublicEDKey missing or placeholder — updater disabled")
            return false
        }
        return true
    }

    @objc private func showAboutWindow() {
        let alert = NSAlert()
        alert.messageText = "PowerMateReborn"
        alert.alertStyle = .informational
        
        // Set custom icon (logo) at the top
        if let logoPath = Bundle.module.path(forResource: "logo", ofType: "svg") ?? Bundle.main.path(forResource: "logo", ofType: "svg"),
           let logoImg = NSImage(contentsOfFile: logoPath) {
            alert.icon = logoImg
        }

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 8
        
        // Version info
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.isEditable = false
        versionLabel.isSelectable = false
        versionLabel.drawsBackground = false
        versionLabel.isBordered = false
        container.addArrangedSubview(versionLabel)
        
        // Device status
        let connected = powerMate.isConnected
        let deviceStatus = connected ? "🟢 PowerMate Connected" : "⚪️ PowerMate Disconnected"
        let statusLabel = NSTextField(labelWithString: deviceStatus)
        statusLabel.font = NSFont.boldSystemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.drawsBackground = false
        statusLabel.isBordered = false
        container.addArrangedSubview(statusLabel)
        
        // Audio info
        let audioInfo = "Audio: \(volumeController.activeDeviceName) (\(volumeController.volumeMethod.rawValue))"
        let audioLabel = NSTextField(labelWithString: audioInfo)
        audioLabel.font = NSFont.systemFont(ofSize: 12)
        audioLabel.textColor = .secondaryLabelColor
        audioLabel.alignment = .center
        audioLabel.isEditable = false
        audioLabel.isSelectable = false
        audioLabel.drawsBackground = false
        audioLabel.isBordered = false
        container.addArrangedSubview(audioLabel)
        
        // Brightness info
        let brightnessInfo = "Brightness: \(brightnessController.method.rawValue)"
        let brightnessLabel = NSTextField(labelWithString: brightnessInfo)
        brightnessLabel.font = NSFont.systemFont(ofSize: 12)
        brightnessLabel.textColor = .secondaryLabelColor
        brightnessLabel.alignment = .center
        brightnessLabel.isEditable = false
        brightnessLabel.isSelectable = false
        brightnessLabel.drawsBackground = false
        brightnessLabel.isBordered = false
        container.addArrangedSubview(brightnessLabel)
        
        // Tip about multi-display
        let tipLabel = NSTextField(wrappingLabelWithString: "Tip: By default, the knob dims all displays together. You can uncheck 'Sync All Displays' in the menu to control each monitor individually based on mouse location.")
        tipLabel.font = NSFont.systemFont(ofSize: 11)
        tipLabel.textColor = .secondaryLabelColor
        tipLabel.alignment = .center
        tipLabel.isEditable = false
        tipLabel.isSelectable = false
        tipLabel.drawsBackground = false
        tipLabel.isBordered = false
        tipLabel.maximumNumberOfLines = 0
        tipLabel.lineBreakMode = .byWordWrapping
        tipLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(tipLabel)
        NSLayoutConstraint.activate([
            tipLabel.widthAnchor.constraint(equalToConstant: 300)
        ])
        
        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(spacer)
        NSLayoutConstraint.activate([
            spacer.heightAnchor.constraint(equalToConstant: 4)
        ])
        
        // Report Issue button (opens the prefilled report window)
        let issueButton = NSButton(title: "Report Issue...", target: self, action: #selector(showIssueReporter))
        issueButton.bezelStyle = .rounded
        container.addArrangedSubview(issueButton)
        
        // Add padding
        container.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        container.layoutSubtreeIfNeeded()
        
        let requiredSize = container.fittingSize
        
        // Wrap the container in an explicit fixed-size NSView. 
        // NSAlert requires the accessoryView to have a fully specified frame.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: requiredSize.height))
        container.frame = wrapper.bounds
        container.autoresizingMask = [.width, .height]
        wrapper.addSubview(container)
        
        alert.accessoryView = wrapper
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showIssueReporter() {
        // If invoked from inside a modal alert (the About dialog's button), end the
        // modal session first so the report window is actually interactive. Ordering
        // the panel out async lets the session tear down before the window hides.
        if let modalAlert = NSApp.modalWindow {
            NSApp.stopModal()
            DispatchQueue.main.async { modalAlert.orderOut(nil) }
        }

        // Always build a fresh window: the snapshot and log tail should reflect
        // the state at the moment the user reports the issue.
        issueReportWindowController?.close()
        let reportView = IssueReportView()
        let hostingController = NSHostingController(rootView: reportView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Report Issue"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 620))
        window.minSize = NSSize(width: 480, height: 480)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        issueReportWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Snapshot of app + device state included in issue reports.
    func systemInfoForReport() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion)\(osVersion.patchVersion > 0 ? ".\(osVersion.patchVersion)" : "")"

        let connected = powerMate.isConnected
        let deviceLine = connected ? "Connected" : "Disconnected"

        let vol = volumeController.getVolume()
        let br = brightnessController.getCurrentBrightness()
        let ddcEnabled = brightnessController.ddcController.isEnabled

        var lines = [
            "App: PowerMateReborn \(version) (\(build))",
            "OS: \(osString)",
            "Device: PowerMate \(deviceLine)",
            "Mode: \(currentMode.rawValue)",
            "Volume: \(Int(vol * 100))% via \(volumeController.activeDeviceName) (\(volumeController.volumeMethod.rawValue))",
            "Brightness: \(Int(br * 100))% via \(brightnessController.method.rawValue), DDC/CI \(ddcEnabled ? "enabled" : "disabled")",
            "Display: \(brightnessController.activeDisplayName)",
        ]
        if connected, let transport = powerMate.activeTransportName() {
            lines.append("Transport: \(transport)")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func showSettings() {
        // Always build a fresh view so every section reflects current state.
        settingsWindowController?.close()
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.minSize = NSSize(width: 560, height: 460)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showQuickStart() {
        let alert = NSAlert()
        alert.messageText = "Quick Start"
        alert.alertStyle = .informational
        
        // Set custom icon (logo) at the top
        if let logoPath = Bundle.module.path(forResource: "logo", ofType: "svg") ?? Bundle.main.path(forResource: "logo", ofType: "svg"),
           let logoImg = NSImage(contentsOfFile: logoPath) {
            alert.icon = logoImg
        }
        
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 8
        
        // 1. PowerMate device image
        if let iconPath = Bundle.module.path(forResource: "griffin-technology-powermate-mac-os9", ofType: "png") ?? Bundle.main.path(forResource: "griffin-technology-powermate-mac-os9", ofType: "png"),
           let img = NSImage(contentsOfFile: iconPath) {
            let imageView = NSImageView(image: img)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 300),
                imageView.heightAnchor.constraint(equalToConstant: 80)
            ])
            container.addArrangedSubview(imageView)
        }
        
        // 2. Grid Table for Controls
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        
        let actions = [
            ("Turn knob", "Adjust volume or brightness"),
            ("Press down", "Snap to preset level (toggle)"),
            ("Double-tap", "Mute audio or sleep display"),
            ("Press & hold", "Cycle modes (Vol / Bright / MIDI)")
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
        let footer = NSTextField(wrappingLabelWithString: "You can configure the active mode, output device, and rotation sensitivity using this menu.")
        footer.font = NSFont.systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.isEditable = false
        footer.isSelectable = false
        footer.drawsBackground = false
        footer.isBordered = false
        footer.maximumNumberOfLines = 0
        footer.lineBreakMode = .byWordWrapping
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(footer)
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: 480)
        ])
        
        // Add padding
        container.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        container.layoutSubtreeIfNeeded()
        
        let requiredSize = container.fittingSize
        
        // Wrap the container in an explicit fixed-size NSView. 
        // NSAlert requires the accessoryView to have a fully specified frame.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: requiredSize.height))
        container.frame = wrapper.bounds
        container.autoresizingMask = [.width, .height]
        wrapper.addSubview(container)
        
        alert.accessoryView = wrapper
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
        case .midi:
            level = midiController.ccLevel
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
        SettingsModel.shared.refresh()
    }

    func powerMateDidDisconnect() {
        NSLog("PowerMate disconnected")
        updateStatusDisplay()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func powerMateDidRotate(delta: Int) {
        let adjustment = Float(delta) * stepSize

        switch currentMode {
        case .volume:
            volumeController.adjustVolume(by: adjustment)
            osd.showVolume(level: volumeController.getVolume(), muted: volumeController.isMuted())
        case .brightness:
            brightnessController.updateTargetDisplay()
            brightnessController.adjustBrightness(by: adjustment)
            osd.showBrightness(level: brightnessController.getCurrentBrightness())
        case .midi:
            midiController.adjustCC(by: adjustment)
        case .custom:
            customEngine.handleRotation(delta: delta, stepSize: stepSize)
        }
        updateLEDForLevel()
        updateMenuLevels()
    }

    func powerMateButtonPressed() {
        NSLog("Button: single press [%@]", currentMode.rawValue)
        switch currentMode {
        case .volume:
            // Tap = snap to preset (20%), tap again = restore
            if let saved = volumeBeforeSnap {
                volumeController.setVolume(saved)
                volumeBeforeSnap = nil
                NSLog("Volume: restored to %.0f%%", saved * 100)
            } else {
                volumeBeforeSnap = volumeController.getVolume()
                volumeController.setVolume(volumeSnapValue)
                NSLog("Volume: snapped to %.0f%%", volumeSnapValue * 100)
            }
            osd.showVolume(level: volumeController.getVolume(), muted: volumeController.isMuted())

        case .brightness:
            // Tap = snap to the configured brightness level, tap again = restore
            if let saved = brightnessBeforeSnap {
                brightnessController.setBrightness(saved)
                brightnessBeforeSnap = nil
                NSLog("Brightness: restored to %.0f%%", saved * 100)
            } else {
                brightnessBeforeSnap = brightnessController.getCurrentBrightness()
                brightnessController.setBrightness(brightnessSnapValue)
                NSLog("Brightness: night mode %.0f%%", brightnessSnapValue * 100)
            }
            osd.showBrightness(level: brightnessController.getCurrentBrightness())

        case .midi:
            midiController.toggleNote()
        case .custom:
            customEngine.handleSingleTap()
        }
        updateLEDForLevel()
        refreshMenu()
    }

    func powerMateButtonDoubleTapped() {
        NSLog("Button: double tap [%@]", currentMode.rawValue)
        switch currentMode {
        case .volume:
            volumeController.toggleMute()
            osd.showVolume(level: volumeController.getVolume(), muted: volumeController.isMuted())
        case .brightness:
            brightnessController.sleepDisplay()
        case .midi:
            midiController.toggleNote()
        case .custom:
            customEngine.handleDoubleTap()
        }
        updateLEDForLevel()
        refreshMenu()
    }

    func powerMateButtonLongPressed() {
        // In Custom mode, the engine may override the long press
        if currentMode == .custom && customEngine.handleLongPress() {
            NSLog("Button: long press consumed by Custom profile")
            return
        }
        NSLog("Button: long press -> cycle mode")
        cycleMode()
    }

    func powerMateButtonReleased() {
        // Forward raw release to the custom engine for extended press support
        if currentMode == .custom {
            customEngine.handleButtonReleased()
        }
    }

    // MARK: - VolumeChangeDelegate

    func volumeDidChange(volume: Float, muted: Bool) {
        // External volume change (keyboard, Control Center, another app)
        updateLEDForLevel()
        updateMenuLevels()
        SettingsModel.shared.refresh()
    }

    func audioDeviceDidChange(deviceName: String, method: VolumeControlMethod) {
        NSLog("Audio device changed to: \(deviceName) (\(method.rawValue))")

        // Apply saved per-device routing preference
        if let prefs = UserDefaults.standard.dictionary(forKey: "powermate.deviceRouting") as? [String: String],
           let currentUID = volumeController.activeDeviceInfo?.uid,
           let preferredUID = prefs[currentUID] {
            // Find device with that UID
            if let preferred = volumeController.allOutputDevices.first(where: { $0.uid == preferredUID }),
               preferred.deviceID != volumeController.activeDeviceID {
                NSLog("Audio: applying saved routing -> %@ (%@)", preferred.name, preferredUID)
                volumeController.setActiveDevice(preferred.deviceID)
            }
        }

        updateLEDForLevel()
        refreshMenu()
        SettingsModel.shared.refresh()
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
        // MIDI settings
        if d.object(forKey: "powermate.midi.ccNumber") != nil {
            midiController.ccNumber = UInt8(d.integer(forKey: "powermate.midi.ccNumber"))
        }
        if d.object(forKey: "powermate.midi.channel") != nil {
            midiController.channel = UInt8(d.integer(forKey: "powermate.midi.channel"))
        }
        // DDC/CI enabled. States were probed during BrightnessController.init
        // with DDC defaulted on; re-probe so a saved "disabled" setting takes
        // effect for methods already cached as DDC.
        if d.object(forKey: "powermate.ddc.enabled") != nil {
            let savedEnabled = d.bool(forKey: "powermate.ddc.enabled")
            if savedEnabled != brightnessController.ddcController.isEnabled {
                brightnessController.ddcController.isEnabled = savedEnabled
                brightnessController.reprobeDisplays(force: true)
            }
        }
        // Sync launch-at-login with actual SMAppService status
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        NSLog("Settings: mode=%@ step=%.0f%% led=%d login=%d ddc=%d midi=CC%d/ch%d", currentMode.rawValue, stepSize * 100, ledFollowsLevel, launchAtLogin, brightnessController.ddcController.isEnabled, midiController.ccNumber, midiController.channel + 1)
    }

    /// Save settings. Also called from the SIGTERM/SIGINT dispatch handler in
    /// main.swift, so it must be callable outside this class.
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(currentMode.rawValue, forKey: "powermate.currentMode")
        d.set(enabledModes.map { $0.rawValue }, forKey: "powermate.enabledModes")
        d.set(stepSize, forKey: "powermate.stepSize")
        d.set(ledFollowsLevel, forKey: "powermate.ledFollowsLevel")
        d.set(powerMate.longPressThreshold, forKey: "powermate.longPressThreshold")
        d.set(powerMate.doubleTapInterval, forKey: "powermate.doubleTapInterval")
        d.set(volumeSnapValue, forKey: "powermate.volume.snapValue")
        d.set(brightnessSnapValue, forKey: "powermate.brightness.snapValue")
        d.set(Int(midiController.ccNumber), forKey: "powermate.midi.ccNumber")
        d.set(Int(midiController.channel), forKey: "powermate.midi.channel")
    }
}
