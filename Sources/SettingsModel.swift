import Foundation
import CoreAudio

/// Observable mirror of the app's settings for the Settings window.
/// AppDelegate remains the source of truth: every write forwards to an
/// AppDelegate mutator (which persists + applies side effects) and then
/// `refresh()` re-reads state so all @Published values stay in sync.
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

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

    /// Re-read all settings from AppDelegate. Called after every mutation and
    /// on device/connection delegate callbacks so the window stays live.
    func refresh() {
        guard let app = AppDelegate.shared else { return }
        enabledModes = app.enabledModes
        currentMode = app.currentMode
        stepSize = app.stepSize
        ledMode = app.ledFollowsLevel ? .followLevel : staticLEDMode(fromBrightness: app.powerMateLEDBrightness)
        longPressThreshold = app.longPressThreshold
        doubleTapInterval = app.doubleTapInterval

        allOutputDevices = app.volumeController.allOutputDevices
        activeDeviceID = app.volumeController.activeDeviceID
        activeDeviceName = app.volumeController.activeDeviceName
        volumeMethod = app.volumeController.volumeMethod
        volumeSnapValue = app.volumeSnapValue

        ddcEnabled = app.brightnessController.ddcController.isEnabled
        syncDisplays = app.brightnessController.syncDisplays
        brightnessSnapValue = app.brightnessSnapValue
        brightnessMethod = app.brightnessController.method
        activeDisplayName = app.brightnessController.activeDisplayName

        midiCCNumber = app.midiController.ccNumber
        midiChannel = app.midiController.channel

        launchAtLogin = app.launchAtLogin
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

    /// Reconstruct the static LED mode from the raw brightness value kept by
    /// PowerMateManager (used when ledFollowsLevel is off).
    private func staticLEDMode(fromBrightness brightness: UInt8) -> LEDMode {
        switch brightness {
        case 0: return .off
        case 1..<128: return .dim
        default: return .bright
        }
    }
}