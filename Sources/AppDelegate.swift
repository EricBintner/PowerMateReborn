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

    // Snap-to-value state (single tap toggles), per knob.
    private var volumeBeforeSnap: [String: Float] = [:]
    private var brightnessBeforeSnap: [String: Float] = [:]
    private(set) var volumeSnapValue: Float = 0.20      // 20%
    private(set) var brightnessSnapValue: Float = 0.67  // 67%

    private let deviceStore = PowerMateDeviceStore.shared
    /// Knob that last sent an event. The menu bar shows this knob's mode.
    private var focusedIdentity: String?
    /// Knob the Settings window is editing. Nil means the migration template.
    var settingsIdentity: String?

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
        // The log file runs on across launches and updates. Mark where each
        // run starts and which version wrote it, so a report's log can be read.
        NSLog("Launch: PowerMateReborn %@ (%@), macOS %@",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
              ProcessInfo.processInfo.operatingSystemVersionString)

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
        customEngine.volumeController = volumeController
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
        powerMate.setAllLEDBrightness(0)
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
        let focusedName = focusedIdentity.map { deviceStore.record(for: $0).displayName }
        let statusTitle = powerMate.isConnected ? "\(focusedName ?? "PowerMate") Connected" : "PowerMate Disconnected"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        let dotColor: NSColor = powerMate.isConnected ? .systemGreen : .systemGray
        if let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            // Drawn (non-symbol) image so the color sticks. macOS 27 also keeps
            // non-symbol menu images visible for apps built on pre-27 SDKs.
            let dot = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                dotColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            dot.accessibilityDescription = powerMate.isConnected ? "Connected" : "Disconnected"
            statusMenuItem.image = dot
            keepImageVisible(statusMenuItem)
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
                keepImageVisible(item)
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
        setAlignmentSpacer(muteItem, matching: "speaker.wave.2.fill")
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
            setAlignmentSpacer(warnItem, matching: "sun.max.fill")
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
        setAlignmentSpacer(settingsItem, matching: "gearshape")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About PowerMate...", action: #selector(showAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        setAlignmentSpacer(aboutItem, matching: "info.circle")
        menu.addItem(aboutItem)

        // Report Issue (above Check for Updates, matching the About dialog entry point)
        let reportItem = NSMenuItem(title: "Report Issue...", action: #selector(showIssueReporter), keyEquivalent: "")
        reportItem.target = self
        setAlignmentSpacer(reportItem, matching: "exclamationmark.bubble.fill")
        menu.addItem(reportItem)

        // Add update check menu item
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        if updaterController == nil {
            updateItem.isEnabled = false
        }
        setAlignmentSpacer(updateItem, matching: "arrow.down.circle")
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Quit PowerMate", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        setAlignmentSpacer(quitItem, matching: "power.circle")
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuLevels()
    }

    // macOS 27 hides menu item images by default: symbol images for apps built
    // on the 26 SDK, every image for apps built on the 27 SDK.

    /// Blank image the size of a symbol, so a title lines up with the iconned
    /// items around it. Skipped on macOS 27+, where those icons are hidden.
    private func setAlignmentSpacer(_ item: NSMenuItem, matching symbolName: String) {
        if #available(macOS 27, *) { return }
        if let templateImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            item.image = NSImage(size: templateImg.size)
        }
    }

    /// Keep an icon that carries information (connection state, mode) visible
    /// on macOS 27+. `preferredImageVisibility` only exists in the macOS 27 SDK;
    /// AccessoryAccess is new in that SDK, so it gates the call until we build
    /// with Xcode 27.
    private func keepImageVisible(_ item: NSMenuItem) {
        #if canImport(AccessoryAccess)
        if #available(macOS 27, *) {
            item.preferredImageVisibility = .visible
        }
        #endif
    }

    private func refreshMenu() {
        buildMenu()
    }

    // MARK: - Mode Switching

    private func cycleMode(identity: String) {
        var next = KnobMode.volume
        updateIdentity(identity) { rec in
            let modes = rec.modes
            guard modes.count > 1 else { next = rec.mode; return }
            if let idx = modes.firstIndex(of: rec.mode) {
                next = modes[(idx + 1) % modes.count]
            } else {
                next = modes[0]
            }
            rec.currentMode = next.rawValue
        }
        NSLog("Mode switched to: \(next.rawValue)")
        updateStatusDisplay()
        applyLED(identity: identity)
        refreshMenu()
        flashLED(identity: identity)
        SettingsModel.shared.refresh()
    }

    private func flashLED(identity: String) {
        let savedBrightness = powerMate.ledBrightness(for: identity)
        powerMate.setLEDBrightness(255, for: identity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.powerMate.setLEDBrightness(0, for: identity)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.powerMate.setLEDBrightness(255, for: identity)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self else { return }
                    let rec = self.deviceStore.record(for: identity)
                    if rec.ledFollowsLevel {
                        self.applyLED(identity: identity)
                    } else {
                        self.powerMate.setLEDBrightness(savedBrightness, for: identity)
                    }
                }
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func switchToMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = KnobMode(rawValue: rawValue) else { return }
        if let identity = focusedIdentity {
            updateIdentity(identity) { $0.currentMode = mode.rawValue }
            applyLED(identity: identity)
        } else {
            deviceStore.updateTemplate { $0.currentMode = mode.rawValue }
            mirror(deviceStore.template)
        }
        NSLog("Mode switched to: %@", mode.rawValue)
        updateStatusDisplay()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    @objc private func toggleMuteClicked() {
        if let identity = focusedIdentity {
            applyKnobOutput(deviceStore.record(for: identity))
        }
        volumeController.toggleMute()
        if let identity = focusedIdentity {
            applyLED(identity: identity)
        }
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
        var changed = false
        updateEditing { rec in
            var modes = rec.modes
            if enabled {
                if !modes.contains(mode) {
                    modes.append(mode)
                    changed = true
                }
            } else if modes.count > 1, modes.contains(mode) {
                modes.removeAll { $0 == mode }
                changed = true
                if rec.mode == mode {
                    rec.currentMode = modes[0].rawValue
                }
            }
            rec.enabledModes = modes.map(\.rawValue)
        }
        guard changed else { return }
        if let id = editingIdentity(), id == focusedIdentity {
            updateStatusDisplay()
            applyLED(identity: id)
        }
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func setActiveDevice(_ deviceID: AudioDeviceID) {
        let alreadyPinned = editingRecord().outputUID != nil
        if deviceID == volumeController.activeDeviceID && alreadyPinned { return }
        volumeController.setActiveDevice(deviceID)
        let uid: String?
        if deviceID == 9999 {
            uid = PowerMateDeviceStore.appleMusicUID
        } else {
            uid = volumeController.allOutputDevices.first(where: { $0.deviceID == deviceID })?.uid
        }
        guard let uid, !uid.isEmpty else { return }
        updateEditing { $0.outputUID = uid }
        NSLog("Audio: knob %@ pinned to %@", editingIdentity() ?? "template", uid)
        if let id = editingIdentity() {
            applyLED(identity: id)
        }
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func setStepSize(_ value: Float) {
        guard value != editingRecord().stepSize else { return }
        updateEditing { $0.stepSize = value }
        SettingsModel.shared.refresh()
    }

    func setVolumeSnap(_ value: Float) {
        guard value != editingRecord().volumeSnapValue else { return }
        updateEditing { $0.volumeSnapValue = value }
        SettingsModel.shared.refresh()
    }

    func setBrightnessSnap(_ value: Float) {
        guard value != editingRecord().brightnessSnapValue else { return }
        updateEditing { $0.brightnessSnapValue = value }
        SettingsModel.shared.refresh()
    }

    func setLEDMode(_ mode: LEDMode) {
        let follows: Bool
        let brightness: UInt8
        switch mode {
        case .followLevel:
            follows = true
            brightness = editingRecord().ledBrightness
        case .off:
            follows = false
            brightness = 0
        case .dim:
            follows = false
            brightness = 64
        case .bright:
            follows = false
            brightness = 255
        }
        updateEditing {
            $0.ledFollowsLevel = follows
            if !follows { $0.ledBrightness = brightness }
        }
        if let id = editingIdentity(), powerMate.connectedDevices().contains(where: { $0.identity == id }) {
            if follows {
                applyLED(identity: id)
            } else {
                powerMate.setLEDBrightness(brightness, for: id)
            }
        }
        SettingsModel.shared.refresh()
    }

    func setMIDICC(_ cc: UInt8) {
        guard Int(cc) != editingRecord().midiCCNumber else { return }
        updateEditing { $0.midiCCNumber = Int(cc) }
        NSLog("MIDI: CC number changed to %d", cc)
        SettingsModel.shared.refresh()
    }

    func setMIDIChannel(_ channel: UInt8) {  // channel is 0-indexed
        guard Int(channel) != editingRecord().midiChannel else { return }
        updateEditing { $0.midiChannel = Int(channel) }
        NSLog("MIDI: channel changed to %d (0-based)", channel)
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
        updateEditing { $0.longPressThreshold = seconds }
        SettingsModel.shared.refresh()
    }

    func setDoubleTapInterval(_ seconds: Double) {
        updateEditing { $0.doubleTapInterval = seconds }
        SettingsModel.shared.refresh()
    }

    // Read accessors for the Settings window (powerMate is private).
    // These follow the knob the window is editing, not the menu-bar focus.
    var longPressThreshold: Double { editingRecord().longPressThreshold }
    var doubleTapInterval: Double { editingRecord().doubleTapInterval }
    var powerMateLEDBrightness: UInt8 { editingRecord().ledBrightness }

    func connectedPowerMates() -> [(identity: String, displayName: String)] {
        powerMate.connectedDevices()
    }

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
        if let logoPath = AppResources.path(forResource: "logo", ofType: "svg"),
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
        // Tall enough for the whole form: at 620 the intro and the buttons
        // were cut off.
        window.setContentSize(NSSize(width: 560, height: 720))
        window.contentMinSize = NSSize(width: 520, height: 700)
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

        let vol = volumeController.getVolume()
        let br = brightnessController.getCurrentBrightness()
        let ddcEnabled = brightnessController.ddcController.isEnabled

        var lines = [
            "App: PowerMateReborn \(version) (\(build))",
            "OS: \(osString)",
        ]
        lines += IssueReporter.knobLines(usbConnected: powerMate.isUSBConnected,
                                         bluetooth: powerMate.bluetoothStatus)
        lines += [
            "Mode: \(currentMode.rawValue)",
            "Volume: \(Int(vol * 100))% via \(volumeController.activeDeviceName) (\(volumeController.volumeMethod.rawValue))",
            "Brightness: \(Int(br * 100))% via \(brightnessController.method.rawValue), DDC/CI \(ddcEnabled ? "enabled" : "disabled")",
            "Display: \(brightnessController.activeDisplayName)",
        ]
        return lines.joined(separator: "\n")
    }

    /// The report form's starting answer to "which PowerMate do you have":
    /// whatever is connected right now, or nothing.
    func connectedKnobForReport() -> IssueReporter.Knob? {
        return IssueReporter.Knob(usbConnected: powerMate.isUSBConnected,
                                  bluetoothConnected: powerMate.bluetoothStatus?.isConnected ?? false)
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
        if let logoPath = AppResources.path(forResource: "logo", ofType: "svg"),
           let logoImg = NSImage(contentsOfFile: logoPath) {
            alert.icon = logoImg
        }
        
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 8
        
        // 1. PowerMate device image
        if let iconPath = AppResources.path(forResource: "griffin-technology-powermate-mac-os9", ofType: "png"),
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

    // MARK: - Per-knob records

    /// Copy a knob's record into the fields the menu bar reads.
    private func mirror(_ record: PowerMateDeviceRecord) {
        currentMode = record.mode
        enabledModes = record.modes
        stepSize = record.stepSize
        ledFollowsLevel = record.ledFollowsLevel
        volumeSnapValue = record.volumeSnapValue
        brightnessSnapValue = record.brightnessSnapValue
        midiController.ccNumber = UInt8(clamping: record.midiCCNumber)
        midiController.channel = UInt8(clamping: record.midiChannel)
    }

    private func focus(_ identity: String) {
        let changed = focusedIdentity != identity
        focusedIdentity = identity
        mirror(deviceStore.record(for: identity))
        if settingsIdentity == nil {
            settingsIdentity = identity
        }
        if changed {
            updateStatusDisplay()
            refreshMenu()
        }
    }

    private func editingIdentity() -> String? {
        settingsIdentity ?? focusedIdentity
    }

    private func editingRecord() -> PowerMateDeviceRecord {
        if let id = editingIdentity() {
            return deviceStore.record(for: id)
        }
        return deviceStore.template
    }

    private func updateEditing(_ body: (inout PowerMateDeviceRecord) -> Void) {
        if let id = editingIdentity() {
            deviceStore.update(identity: id, body)
            if id == focusedIdentity {
                mirror(deviceStore.record(for: id))
            }
        } else {
            deviceStore.updateTemplate(body)
            mirror(deviceStore.template)
        }
    }

    private func updateIdentity(_ identity: String, _ body: (inout PowerMateDeviceRecord) -> Void) {
        deviceStore.update(identity: identity, body)
        if identity == focusedIdentity {
            mirror(deviceStore.record(for: identity))
        }
    }

    /// Point volume control at this knob's output. No-op when the knob still
    /// follows the shared system-default routing map.
    private func applyKnobOutput(_ record: PowerMateDeviceRecord) {
        guard let uid = record.outputUID, !uid.isEmpty else { return }
        if uid == PowerMateDeviceStore.appleMusicUID {
            if volumeController.activeDeviceID != 9999 {
                volumeController.setActiveDevice(9999)
            }
            return
        }
        if let dev = volumeController.allOutputDevices.first(where: { $0.uid == uid }),
           dev.deviceID != volumeController.activeDeviceID {
            volumeController.setActiveDevice(dev.deviceID)
        }
    }

    private func applyMIDI(_ record: PowerMateDeviceRecord) {
        let cc = UInt8(clamping: record.midiCCNumber)
        let channel = UInt8(clamping: record.midiChannel)
        if midiController.ccNumber != cc { midiController.ccNumber = cc }
        if midiController.channel != channel { midiController.channel = channel }
    }

    // MARK: - LED Helpers

    private func applyLED(identity: String) {
        let rec = deviceStore.record(for: identity)
        guard rec.ledFollowsLevel else {
            powerMate.setLEDBrightness(rec.ledBrightness, for: identity)
            return
        }

        var level: Float = 0
        switch rec.mode {
        case .volume:
            level = volumeController.isMuted() ? 0 : volumeController.getVolume()
        case .brightness:
            level = brightnessController.getCurrentBrightness()
        case .midi:
            level = midiController.ccLevel
        case .custom:
            if customEngine.activeProfile?.rotateLeft.type == .volume {
                level = volumeController.isMuted() ? 0 : volumeController.getVolume()
            } else {
                level = 0.5
            }
        }
        let ledVal = UInt8(max(0, min(255, level * 255)))
        powerMate.setLEDBrightness(ledVal, for: identity)
    }

    private func applyConnectedLEDs() {
        for device in powerMate.connectedDevices() {
            let rec = deviceStore.record(for: device.identity)
            guard rec.ledFollowsLevel else { continue }
            applyLED(identity: device.identity)
        }
    }

    // MARK: - PowerMateDelegate

    func powerMateDidConnect(identity: String, displayName: String) {
        NSLog("PowerMate connected %@ (%@)", displayName, identity)
        let rec = deviceStore.ensure(identity: identity, displayName: displayName)
        focus(identity)
        applyMIDI(rec)
        if rec.outputUID != nil {
            applyKnobOutput(rec)
        }
        applyLED(identity: identity)
        updateStatusDisplay()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func powerMateDidDisconnect(identity: String) {
        NSLog("PowerMate disconnected %@", identity)
        if focusedIdentity == identity, let other = powerMate.connectedDevices().first {
            focus(other.identity)
        }
        updateStatusDisplay()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    func powerMateDidRotate(delta: Int, identity: String) {
        focus(identity)
        let rec = deviceStore.record(for: identity)
        applyMIDI(rec)
        let adjustment = Float(delta) * rec.stepSize

        switch rec.mode {
        case .volume:
            applyKnobOutput(rec)
            volumeController.adjustVolume(by: adjustment)
            osd.showVolume(level: volumeController.getVolume(), muted: volumeController.isMuted())
        case .brightness:
            brightnessController.updateTargetDisplay()
            brightnessController.adjustBrightness(by: adjustment)
            osd.showBrightness(level: brightnessController.getCurrentBrightness())
        case .midi:
            midiController.adjustCC(by: adjustment)
        case .custom:
            if let profile = customEngine.activeProfile {
                let action = delta > 0 ? profile.rotateRight : profile.rotateLeft
                if action.type == .volume { applyKnobOutput(rec) }
            }
            customEngine.handleRotation(delta: delta, stepSize: rec.stepSize)
        }
        applyLED(identity: identity)
        updateMenuLevels()
    }

    func powerMateButtonPressed(identity: String) {
        focus(identity)
        let rec = deviceStore.record(for: identity)
        applyMIDI(rec)
        NSLog("Button: single press [%@] %@", rec.currentMode, identity)
        switch rec.mode {
        case .volume:
            applyKnobOutput(rec)
            if let saved = volumeBeforeSnap[identity] {
                volumeController.setVolume(saved)
                volumeBeforeSnap[identity] = nil
                NSLog("Volume: restored to %.0f%%", saved * 100)
            } else {
                volumeBeforeSnap[identity] = volumeController.getVolume()
                volumeController.setVolume(rec.volumeSnapValue)
                NSLog("Volume: snapped to %.0f%%", rec.volumeSnapValue * 100)
            }
            osd.showVolume(level: volumeController.getVolume(), muted: volumeController.isMuted())

        case .brightness:
            if let saved = brightnessBeforeSnap[identity] {
                brightnessController.setBrightness(saved)
                brightnessBeforeSnap[identity] = nil
                NSLog("Brightness: restored to %.0f%%", saved * 100)
            } else {
                brightnessBeforeSnap[identity] = brightnessController.getCurrentBrightness()
                brightnessController.setBrightness(rec.brightnessSnapValue)
                NSLog("Brightness: night mode %.0f%%", rec.brightnessSnapValue * 100)
            }
            osd.showBrightness(level: brightnessController.getCurrentBrightness())

        case .midi:
            midiController.toggleNote()
        case .custom:
            if customEngine.activeProfile?.singleClick.type == .volume {
                applyKnobOutput(rec)
            }
            customEngine.handleSingleTap()
        }
        applyLED(identity: identity)
        refreshMenu()
    }

    func powerMateButtonDoubleTapped(identity: String) {
        focus(identity)
        let rec = deviceStore.record(for: identity)
        applyMIDI(rec)
        NSLog("Button: double tap [%@] %@", rec.currentMode, identity)
        switch rec.mode {
        case .volume:
            applyKnobOutput(rec)
            volumeController.toggleMute()
            osd.showVolume(level: volumeController.getVolume(), muted: volumeController.isMuted())
        case .brightness:
            brightnessController.sleepDisplay()
        case .midi:
            midiController.toggleNote()
        case .custom:
            if customEngine.activeProfile?.doubleClick.type == .volume {
                applyKnobOutput(rec)
            }
            customEngine.handleDoubleTap()
        }
        applyLED(identity: identity)
        refreshMenu()
    }

    func powerMateButtonLongPressed(identity: String) {
        focus(identity)
        let rec = deviceStore.record(for: identity)
        if rec.mode == .custom {
            if let profile = customEngine.activeProfile,
               profile.overrideLongPress,
               profile.longPressAction.type == .volume {
                applyKnobOutput(rec)
            }
            if customEngine.handleLongPress() {
                NSLog("Button: long press consumed by Custom profile")
                return
            }
        }
        NSLog("Button: long press -> cycle mode")
        cycleMode(identity: identity)
    }

    func powerMateButtonReleased(identity: String) {
        let rec = deviceStore.record(for: identity)
        if rec.mode == .custom {
            customEngine.handleButtonReleased()
        }
    }

    // MARK: - VolumeChangeDelegate

    func volumeDidChange(volume: Float, muted: Bool) {
        // External volume change (keyboard, Control Center, another app)
        applyConnectedLEDs()
        updateMenuLevels()
        SettingsModel.shared.refresh()
    }

    func audioDeviceDidChange(deviceName: String, method: VolumeControlMethod) {
        NSLog("Audio device changed to: \(deviceName) (\(method.rawValue))")

        if let identity = focusedIdentity {
            let rec = deviceStore.record(for: identity)
            if let uid = rec.outputUID, !uid.isEmpty {
                let wanted: AudioDeviceID? = uid == PowerMateDeviceStore.appleMusicUID
                    ? 9999
                    : volumeController.allOutputDevices.first(where: { $0.uid == uid })?.deviceID
                if let wanted, wanted != volumeController.activeDeviceID {
                    NSLog("Audio: re-applying knob output %@", uid)
                    volumeController.setActiveDevice(wanted)
                }
                applyConnectedLEDs()
                refreshMenu()
                SettingsModel.shared.refresh()
                return
            }
        }

        // Knob has no output of its own: keep the shared default-device map.
        if let prefs = UserDefaults.standard.dictionary(forKey: "powermate.deviceRouting") as? [String: String],
           let currentUID = volumeController.activeDeviceInfo?.uid,
           let preferredUID = prefs[currentUID] {
            if let preferred = volumeController.allOutputDevices.first(where: { $0.uid == preferredUID }),
               preferred.deviceID != volumeController.activeDeviceID {
                NSLog("Audio: applying saved routing -> %@ (%@)", preferred.name, preferredUID)
                volumeController.setActiveDevice(preferred.deviceID)
            }
        }

        applyConnectedLEDs()
        refreshMenu()
        SettingsModel.shared.refresh()
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        let d = UserDefaults.standard
        // Per-knob values live in PowerMateDeviceStore. Mirror the template
        // until a knob connects and replaces the menu-bar focus.
        mirror(deviceStore.template)
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
        NSLog("Settings: template mode=%@ step=%.0f%% led=%d login=%d ddc=%d midi=CC%d/ch%d knobs=%d", currentMode.rawValue, stepSize * 100, ledFollowsLevel, launchAtLogin, brightnessController.ddcController.isEnabled, midiController.ccNumber, midiController.channel + 1, deviceStore.records.count)
    }

    /// Save settings. Also called from the SIGTERM/SIGINT dispatch handler in
    /// main.swift, so it must be callable outside this class.
    func saveSettings() {
        deviceStore.save()
    }
}
