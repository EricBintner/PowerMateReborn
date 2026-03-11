import AppKit
import Foundation
import CoreGraphics
import CoreMIDI

// MARK: - Codable Models

enum CodableActionType: String, Codable, CaseIterable, Identifiable {
    case unassigned
    case scroll
    case keyboard
    case media
    case midiCC
    case midiNote
    case osc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unassigned: return "Unassigned"
        case .scroll:     return "Scroll"
        case .keyboard:   return "Keyboard Shortcut"
        case .media:      return "Media Control"
        case .midiCC:     return "MIDI CC (Continuous)"
        case .midiNote:   return "MIDI Note"
        case .osc:        return "OSC Message"
        }
    }
}

enum CodableHoldBehavior: String, Codable, CaseIterable, Identifiable {
    case longPress
    case extendedPress
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .longPress:     return "Long Press (Trigger after delay)"
        case .extendedPress: return "Extended Press (Hold to sustain)"
        }
    }
}

enum ScrollDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

enum MediaCommand: String, Codable, CaseIterable {
    case playPause = "Play/Pause"
    case nextTrack = "Next"
    case prevTrack = "Prev"
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16 = 0
    var modifiers: UInt64 = 0  // CGEventFlags raw value
    var displayString: String = ""
}

struct MIDICCConfig: Codable, Equatable {
    var ccNumber: UInt8 = 1
    var channel: UInt8 = 0   // 0-indexed
}

struct MIDINoteConfig: Codable, Equatable {
    var noteNumber: UInt8 = 60
    var velocity: UInt8 = 127
    var channel: UInt8 = 0
}

struct OSCConfig: Codable, Equatable {
    var path: String = "/trigger"
    var host: String = "127.0.0.1"
    var port: UInt16 = 8000
}

struct CodableActionConfig: Codable, Equatable {
    var type: CodableActionType = .unassigned

    // Type-specific parameters (only the relevant one is used)
    var scrollDirection: ScrollDirection = .up
    var mediaCommand: MediaCommand = .playPause
    var keyboardShortcut: KeyboardShortcut = KeyboardShortcut()
    var midiCC: MIDICCConfig = MIDICCConfig()
    var midiNote: MIDINoteConfig = MIDINoteConfig()
    var osc: OSCConfig = OSCConfig()
}

struct CodableAppProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var isGlobal: Bool = false
    var bundleIdentifier: String?
    var iconName: String = "app"

    var rotateLeft: CodableActionConfig = CodableActionConfig(type: .unassigned)
    var rotateRight: CodableActionConfig = CodableActionConfig(type: .unassigned)
    var singleClick: CodableActionConfig = CodableActionConfig(type: .unassigned)
    var doubleClick: CodableActionConfig = CodableActionConfig(type: .unassigned)

    var overrideLongPress: Bool = false
    var holdBehavior: CodableHoldBehavior = .longPress
    var longPressAction: CodableActionConfig = CodableActionConfig(type: .unassigned)
}

// MARK: - Custom Mode Engine

class CustomModeEngine: ObservableObject {
    static let shared = CustomModeEngine()

    @Published var profiles: [CodableAppProfile] = []
    @Published var activeProfileID: UUID?

    private var frontmostObserver: Any?
    private var currentBundleID: String?

    let oscController = OSCController()
    let midiController = MIDIController()

    // Extended press state
    private(set) var extendedPressActive: Bool = false
    private var extendedPressAction: CodableActionConfig?

    // CC accumulator for continuous rotation actions
    private var ccAccumulators: [UInt8: Float] = [:]  // ccNumber -> current 0-127 float

    init() {
        loadProfiles()
        if profiles.isEmpty {
            profiles = [defaultGlobalProfile()]
            saveProfiles()
        }
        startAppObserver()
        resolveActiveProfile()
    }

    // MARK: - Profile Management

    private func defaultGlobalProfile() -> CodableAppProfile {
        var p = CodableAppProfile(name: "Global Default", isGlobal: true, iconName: "globe")
        p.rotateLeft = CodableActionConfig(type: .scroll, scrollDirection: .up)
        p.rotateRight = CodableActionConfig(type: .scroll, scrollDirection: .down)
        p.singleClick = CodableActionConfig(type: .media, mediaCommand: .playPause)
        return p
    }

    func addProfile(name: String, bundleIdentifier: String, iconName: String = "app") {
        let profile = CodableAppProfile(
            name: name,
            bundleIdentifier: bundleIdentifier,
            iconName: iconName
        )
        profiles.append(profile)
        saveProfiles()
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id && !$0.isGlobal }
        saveProfiles()
    }

    func updateProfile(_ profile: CodableAppProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            saveProfiles()
        }
    }

    var globalProfile: CodableAppProfile? {
        profiles.first(where: { $0.isGlobal })
    }

    var activeProfile: CodableAppProfile? {
        if let id = activeProfileID {
            return profiles.first(where: { $0.id == id })
        }
        return globalProfile
    }

    // MARK: - App Observation

    private func startAppObserver() {
        frontmostObserver = NSWorkspace.shared.observe(
            \.frontmostApplication,
            options: [.new]
        ) { [weak self] workspace, change in
            DispatchQueue.main.async {
                self?.onFrontmostAppChanged()
            }
        }
        // Also observe via notification for reliability
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onFrontmostAppChanged()
        }
    }

    private func onFrontmostAppChanged() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        guard bundleID != currentBundleID else { return }
        currentBundleID = bundleID
        resolveActiveProfile()
    }

    private func resolveActiveProfile() {
        let bundleID = currentBundleID ?? ""

        // Find a profile matching the frontmost app
        if let match = profiles.first(where: {
            !$0.isGlobal && $0.bundleIdentifier == bundleID
        }) {
            if activeProfileID != match.id {
                activeProfileID = match.id
                NSLog("Custom: activated profile '%@' for %@", match.name, bundleID)
            }
        } else {
            // Fall back to global
            if let global = globalProfile, activeProfileID != global.id {
                activeProfileID = global.id
                NSLog("Custom: using Global Default for %@", bundleID)
            }
        }
    }

    // MARK: - Gesture Dispatch

    func handleRotation(delta: Int, stepSize: Float) {
        guard let profile = activeProfile else { return }
        let action = delta > 0 ? profile.rotateRight : profile.rotateLeft
        let magnitude = abs(delta)

        for _ in 0..<magnitude {
            executeAction(action, rotationDelta: delta > 0 ? 1 : -1, stepSize: stepSize)
        }
    }

    func handleSingleTap() {
        guard let profile = activeProfile else { return }
        executeAction(profile.singleClick)
    }

    func handleDoubleTap() {
        guard let profile = activeProfile else { return }
        executeAction(profile.doubleClick)
    }

    /// Returns true if the long press was consumed by a custom override (caller should NOT cycle modes)
    func handleLongPress() -> Bool {
        guard let profile = activeProfile, profile.overrideLongPress else {
            return false
        }

        let action = profile.longPressAction
        guard action.type != .unassigned else { return false }

        if profile.holdBehavior == .extendedPress {
            // Extended press: start sustaining
            extendedPressActive = true
            extendedPressAction = action
            executeExtendedPressStart(action)
        } else {
            // Long press: fire once
            executeAction(action)
        }
        return true
    }

    func handleButtonReleased() {
        guard extendedPressActive, let action = extendedPressAction else { return }
        extendedPressActive = false
        extendedPressAction = nil
        executeExtendedPressEnd(action)
    }

    /// Whether the current profile overrides global mode cycling
    var longPressOverridesModeCycle: Bool {
        guard let profile = activeProfile else { return false }
        return profile.overrideLongPress && profile.longPressAction.type != .unassigned
    }

    // MARK: - Action Execution

    private func executeAction(_ action: CodableActionConfig, rotationDelta: Int = 0, stepSize: Float = 0.03) {
        switch action.type {
        case .unassigned:
            break

        case .scroll:
            executeScroll(action.scrollDirection, magnitude: rotationDelta != 0 ? 3 : 10)

        case .keyboard:
            executeKeyboardShortcut(action.keyboardShortcut)

        case .media:
            executeMediaCommand(action.mediaCommand)

        case .midiCC:
            executeMIDICC(action.midiCC, delta: stepSize * Float(rotationDelta != 0 ? rotationDelta : 1))

        case .midiNote:
            executeMIDINoteToggle(action.midiNote)

        case .osc:
            if rotationDelta != 0 {
                // For rotation: send float value based on accumulated CC
                let cc = action.midiCC.ccNumber
                let current = ccAccumulators[cc] ?? 64.0
                let newVal = max(0, min(127, current + Float(rotationDelta) * stepSize * 127.0))
                ccAccumulators[cc] = newVal
                oscController.sendFloat(action.osc.path, value: newVal / 127.0, host: action.osc.host, port: action.osc.port)
            } else {
                // For button press: send trigger
                oscController.sendTrigger(action.osc.path, host: action.osc.host, port: action.osc.port)
            }
        }
    }

    // MARK: - Scroll

    private func executeScroll(_ direction: ScrollDirection, magnitude: Int) {
        var dx: Int32 = 0
        var dy: Int32 = 0

        switch direction {
        case .up:    dy = Int32(magnitude)
        case .down:  dy = Int32(-magnitude)
        case .left:  dx = Int32(magnitude)
        case .right: dx = Int32(-magnitude)
        }

        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Keyboard Shortcut

    private func executeKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        guard shortcut.keyCode != 0 || shortcut.modifiers != 0 else { return }

        let flags = CGEventFlags(rawValue: shortcut.modifiers)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cgSessionEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Media Keys

    private func executeMediaCommand(_ command: MediaCommand) {
        let keyCode: Int64
        switch command {
        case .playPause: keyCode = Int64(NX_KEYTYPE_PLAY)
        case .nextTrack: keyCode = Int64(NX_KEYTYPE_NEXT)
        case .prevTrack: keyCode = Int64(NX_KEYTYPE_PREVIOUS)
        }

        func postMediaKey(_ keyCode: Int64, down: Bool) {
            let flags: Int64 = down ? 0xa00 : 0xb00
            let data1 = (keyCode << 16) | (flags << 16)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(data1),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cgSessionEventTap)
        }

        postMediaKey(keyCode, down: true)
        postMediaKey(keyCode, down: false)
    }

    // MARK: - MIDI

    private func executeMIDICC(_ config: MIDICCConfig, delta: Float) {
        let cc = config.ccNumber
        let current = ccAccumulators[cc] ?? 64.0
        let newVal = max(0, min(127, current + delta * 127.0))
        ccAccumulators[cc] = newVal

        let saved = (midiController.ccNumber, midiController.channel)
        midiController.ccNumber = cc
        midiController.channel = config.channel
        midiController.setCC(UInt8(newVal))
        midiController.ccNumber = saved.0
        midiController.channel = saved.1
    }

    private func executeMIDINoteToggle(_ config: MIDINoteConfig) {
        let saved = (midiController.noteNumber, midiController.noteVelocity, midiController.channel)
        midiController.noteNumber = config.noteNumber
        midiController.noteVelocity = config.velocity
        midiController.channel = config.channel
        midiController.toggleNote()
        midiController.noteNumber = saved.0
        midiController.noteVelocity = saved.1
        midiController.channel = saved.2
    }

    private func executeMIDINoteOn(_ config: MIDINoteConfig) {
        let saved = (midiController.noteNumber, midiController.noteVelocity, midiController.channel)
        midiController.noteNumber = config.noteNumber
        midiController.noteVelocity = config.velocity
        midiController.channel = config.channel
        midiController.sendNoteOn()
        midiController.noteNumber = saved.0
        midiController.noteVelocity = saved.1
        midiController.channel = saved.2
    }

    private func executeMIDINoteOff(_ config: MIDINoteConfig) {
        let saved = (midiController.noteNumber, midiController.noteVelocity, midiController.channel)
        midiController.noteNumber = config.noteNumber
        midiController.noteVelocity = config.velocity
        midiController.channel = config.channel
        midiController.sendNoteOff()
        midiController.noteNumber = saved.0
        midiController.noteVelocity = saved.1
        midiController.channel = saved.2
    }

    // MARK: - Extended Press (Sustain)

    private func executeExtendedPressStart(_ action: CodableActionConfig) {
        NSLog("Custom: extended press START — %@", action.type.rawValue)
        switch action.type {
        case .keyboard:
            // Hold key down
            let shortcut = action.keyboardShortcut
            let flags = CGEventFlags(rawValue: shortcut.modifiers)
            if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true) {
                keyDown.flags = flags
                keyDown.post(tap: .cgSessionEventTap)
            }
        case .midiNote:
            executeMIDINoteOn(action.midiNote)
        case .osc:
            oscController.sendFloat(action.osc.path, value: 1.0, host: action.osc.host, port: action.osc.port)
        default:
            executeAction(action)
        }
    }

    private func executeExtendedPressEnd(_ action: CodableActionConfig) {
        NSLog("Custom: extended press END — %@", action.type.rawValue)
        switch action.type {
        case .keyboard:
            // Release key
            let shortcut = action.keyboardShortcut
            let flags = CGEventFlags(rawValue: UInt64(shortcut.modifiers))
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) {
                keyUp.flags = flags
                keyUp.post(tap: .cgSessionEventTap)
            }
        case .midiNote:
            executeMIDINoteOff(action.midiNote)
        case .osc:
            oscController.sendFloat(action.osc.path, value: 0.0, host: action.osc.host, port: action.osc.port)
        default:
            break
        }
    }

    // MARK: - Persistence

    private let profilesKey = "powermate.custom.profiles"

    func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: profilesKey)
            NSLog("Custom: saved %d profiles", profiles.count)
        } catch {
            NSLog("Custom: failed to save profiles: %@", error.localizedDescription)
        }
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return }
        do {
            profiles = try JSONDecoder().decode([CodableAppProfile].self, from: data)
            NSLog("Custom: loaded %d profiles", profiles.count)
        } catch {
            NSLog("Custom: failed to load profiles: %@", error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        oscController.shutdown()
        if extendedPressActive, let action = extendedPressAction {
            executeExtendedPressEnd(action)
        }
    }
}
