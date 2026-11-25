import Foundation
import CoreAudio

/// One row in the Settings window's knob picker.
struct PowerMateDeviceChoice: Identifiable, Hashable {
    let identity: String
    let displayName: String
    let connected: Bool
    var id: String { identity }
}

/// Observable mirror of the app's settings for the Settings window.
/// AppDelegate remains the source of truth for machine-wide settings.
/// Per-knob values are read from `PowerMateDeviceStore` for `selectedIdentity`.
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    // Which knob the window is editing
    @Published var knownDevices: [PowerMateDeviceChoice] = []
    @Published var selectedIdentity: String?

    // Modes
    @Published var enabledModes: [KnobMode] = []
    @Published var currentMode: KnobMode = .volume

    // Knob
    @Published var stepSize: Float = 0.03
    @Published var ledMode: LEDMode = .followLevel
    @Published var longPressThreshold: Double = 0.5
    @Published var doubleTapInterval: Double = 0.3

    // Audio
    @Published var allOutputDevices: [AudioDeviceInfo] = []
    @Published var activeDeviceID: AudioDeviceID = 0
    @Published var activeDeviceName: String = ""
    @Published var volumeMethod: VolumeControlMethod = .none
    @Published var volumeSnapValue: Float = 0.20

    // Displays
    @Published var ddcEnabled: Bool = true
    @Published var syncDisplays: Bool = true
    @Published var brightnessSnapValue: Float = 0.67
    @Published var brightnessMethod: BrightnessMethod = .none
    @Published var activeDisplayName: String = ""

    // MIDI
    @Published var midiCCNumber: UInt8 = 1
    @Published var midiChannel: UInt8 = 0

    // General
    @Published var launchAtLogin: Bool = false

    private init() {}

    func selectDevice(_ identity: String) {
        selectedIdentity = identity
        AppDelegate.shared?.settingsIdentity = identity
        refresh()
    }

    /// Re-read settings. Per-knob fields come from the selected identity;
    /// display and login fields stay machine-wide.
    func refresh() {
        guard let app = AppDelegate.shared else { return }
        let connected = app.connectedPowerMates()
        var listed = PowerMateDeviceStore.shared.knownDevices()
        for device in connected where !listed.contains(where: { $0.identity == device.identity }) {
            listed.append((identity: device.identity, displayName: device.displayName))
        }
        knownDevices = listed.map { item in
            PowerMateDeviceChoice(
                identity: item.identity,
                displayName: item.displayName,
                connected: connected.contains { $0.identity == item.identity }
            )
        }
        if selectedIdentity == nil || !knownDevices.contains(where: { $0.identity == selectedIdentity }) {
            selectedIdentity = app.settingsIdentity ?? knownDevices.first?.identity
            if app.settingsIdentity == nil {
                app.settingsIdentity = selectedIdentity
            }
        }

        let record = selectedIdentity.map { PowerMateDeviceStore.shared.record(for: $0) }
            ?? PowerMateDeviceStore.shared.template
        enabledModes = record.modes
        currentMode = record.mode
        stepSize = record.stepSize
        ledMode = record.ledFollowsLevel ? .followLevel : staticLEDMode(fromBrightness: record.ledBrightness)
        longPressThreshold = record.longPressThreshold
        doubleTapInterval = record.doubleTapInterval
        volumeSnapValue = record.volumeSnapValue
        brightnessSnapValue = record.brightnessSnapValue
        midiCCNumber = UInt8(clamping: record.midiCCNumber)
        midiChannel = UInt8(clamping: record.midiChannel)

        allOutputDevices = app.volumeController.allOutputDevices
        activeDeviceID = resolvedOutputID(record, app: app)
        activeDeviceName = app.volumeController.activeDeviceName
        volumeMethod = app.volumeController.volumeMethod

        ddcEnabled = app.brightnessController.ddcController.isEnabled
        syncDisplays = app.brightnessController.syncDisplays
        brightnessMethod = app.brightnessController.method
        activeDisplayName = app.brightnessController.activeDisplayName

        launchAtLogin = app.launchAtLogin
    }

    private func resolvedOutputID(_ record: PowerMateDeviceRecord, app: AppDelegate) -> AudioDeviceID {
        guard let uid = record.outputUID, !uid.isEmpty else {
            return app.volumeController.activeDeviceID
        }
        if uid == PowerMateDeviceStore.appleMusicUID { return 9999 }
        return app.volumeController.allOutputDevices.first { $0.uid == uid }?.deviceID
            ?? app.volumeController.activeDeviceID
    }

    // MARK: - Writes (forward to AppDelegate mutators)

    func setModeEnabled(_ mode: KnobMode, _ enabled: Bool) {
        AppDelegate.shared?.setModeEnabled(mode, enabled)
    }

    func setActiveDevice(_ deviceID: AudioDeviceID) {
        AppDelegate.shared?.setActiveDevice(deviceID)
    }

    func setStepSize(_ value: Float) {
        AppDelegate.shared?.setStepSize(value)
    }

    func setVolumeSnap(_ value: Float) {
        AppDelegate.shared?.setVolumeSnap(value)
    }

    func setBrightnessSnap(_ value: Float) {
        AppDelegate.shared?.setBrightnessSnap(value)
    }

    func setLEDMode(_ mode: LEDMode) {
        AppDelegate.shared?.setLEDMode(mode)
    }

    func setMIDICC(_ cc: UInt8) {
        AppDelegate.shared?.setMIDICC(cc)
    }

    func setMIDIChannel(_ channel: UInt8) {
        AppDelegate.shared?.setMIDIChannel(channel)
    }

    func setDDCEnabled(_ enabled: Bool) {
        AppDelegate.shared?.setDDCEnabled(enabled)
    }

    func setSyncDisplays(_ enabled: Bool) {
        AppDelegate.shared?.setSyncDisplays(enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        AppDelegate.shared?.setLaunchAtLogin(enabled)
    }

    func setLongPressThreshold(_ seconds: Double) {
        AppDelegate.shared?.setLongPressThreshold(seconds)
    }

    func setDoubleTapInterval(_ seconds: Double) {
        AppDelegate.shared?.setDoubleTapInterval(seconds)
    }

    // MARK: - Helpers

    /// Reconstruct the static LED mode from the brightness stored on the knob.
    private func staticLEDMode(fromBrightness brightness: UInt8) -> LEDMode {
        switch brightness {
        case 0: return .off
        case 1..<128: return .dim
        default: return .bright
        }
    }
}