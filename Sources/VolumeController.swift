import Foundation
import AppKit
import CoreAudio
import AudioToolbox

// MARK: - Audio Device Info

enum VolumeControlMethod: String {
    case coreAudioMaster    = "CoreAudio Master"
    case coreAudioChannel   = "CoreAudio Channel"
    case virtualMaster      = "Virtual Master"
    case appleScript        = "AppleScript"
    case mediaKeys          = "Media Keys"
    case none               = "None"
}

struct AudioDeviceInfo {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    let transportType: UInt32
    let hasVolumeScalar: Bool       // element 0
    let hasChannelVolume: Bool      // elements 1, 2
    let hasVirtualMaster: Bool
    let hasMute: Bool
    let isVolumeSettable: Bool
    let isMuteSettable: Bool
    let outputStreamCount: Int

    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:      return "Built-in"
        case kAudioDeviceTransportTypeUSB:          return "USB"
        case kAudioDeviceTransportTypeBluetooth:    return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:  return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI:         return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:  return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:      return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt:  return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual:      return "Virtual"
        case kAudioDeviceTransportTypeAggregate:    return "Aggregate"
        default:                                     return "Unknown"
        }
    }

    var bestVolumeMethod: VolumeControlMethod {
        if hasVolumeScalar && isVolumeSettable { return .coreAudioMaster }
        if hasChannelVolume { return .coreAudioChannel }
        if hasVirtualMaster { return .virtualMaster }
        return .appleScript
    }

    var volumeIcon: String {
        if hasVolumeScalar || hasChannelVolume || hasVirtualMaster { return "✅" }
        return "❌"
    }

    var isDefault: Bool { return false } // set dynamically
}

// MARK: - Volume Change Delegate

protocol VolumeChangeDelegate: AnyObject {
    func volumeDidChange(volume: Float, muted: Bool)
    func audioDeviceDidChange(deviceName: String, method: VolumeControlMethod)
}

// MARK: - Volume Controller

class VolumeController {
    weak var delegate: VolumeChangeDelegate?

    private(set) var activeDeviceID: AudioDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var activeDeviceInfo: AudioDeviceInfo?
    private(set) var allOutputDevices: [AudioDeviceInfo] = []
    private(set) var volumeMethod: VolumeControlMethod = .none

    // Mute simulation state (A5)
    private var simulatedMute: Bool = false
    private var volumeBeforeMute: Float = 0.0

    // Rate limiting (A7)
    private var lastAppleScriptTime: TimeInterval = 0
    private let appleScriptMinInterval: TimeInterval = 0.05  // 20/sec max
    private var pendingAppleScriptVolume: Float?
    private var appleScriptTimer: Timer?

    // Listeners (A2, A3)
    private var deviceListenerInstalled = false
    private var volumeListenerInstalled = false
    private var muteListenerInstalled = false

    init() {
        refreshAllDevices()
        installDeviceChangeListener()
        installSleepWakeListener()
    }

    deinit {
        removeVolumeListeners()
    }

    // MARK: - Public API

    /// Get current volume (0.0 - 1.0)
    func getVolume() -> Float {
        if simulatedMute { return 0.0 }
        switch volumeMethod {
        case .coreAudioMaster:  return getCoreAudioVolume(element: 0)
        case .coreAudioChannel: return getCoreAudioChannelAverage()
        case .virtualMaster:    return getVirtualMasterVolume()
        case .appleScript:      return getAppleScriptVolume()
        case .mediaKeys, .none: return 0.5
        }
    }

    /// Set volume (0.0 - 1.0)
    func setVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        if simulatedMute {
            simulatedMute = false
        }
        switch volumeMethod {
        case .coreAudioMaster:  setCoreAudioVolume(clamped, element: 0)
        case .coreAudioChannel: setCoreAudioChannelVolume(clamped)
        case .virtualMaster:    setVirtualMasterVolume(clamped)
        case .appleScript:      setAppleScriptVolumeThrottled(clamped)
        case .mediaKeys, .none: break
        }
    }

    /// Adjust volume by a delta (-1.0 to 1.0)
    func adjustVolume(by delta: Float) {
        if simulatedMute && delta > 0 {
            // Un-mute on volume up
            simulatedMute = false
            let restored = max(0.01, volumeBeforeMute)
            setVolume(restored + delta)
            return
        }
        let current = getVolume()
        setVolume(current + delta)
    }

    /// Get mute state
    func isMuted() -> Bool {
        if simulatedMute { return true }
        guard let info = activeDeviceInfo else { return false }
        if info.hasMute && info.isMuteSettable {
            return getCoreAudioMute()
        }
        // Check if volume is essentially zero
        return getVolume() < 0.001
    }

    /// Toggle mute (A5: simulation for devices without hardware mute)
    func toggleMute() {
        guard let info = activeDeviceInfo else { return }
        if info.hasMute && info.isMuteSettable {
            setCoreAudioMute(!getCoreAudioMute())
        } else if volumeMethod == .appleScript {
            toggleAppleScriptMute()
        } else {
            // Mute simulation: save current volume → set to 0 → restore on un-mute
            if simulatedMute {
                simulatedMute = false
                setVolume(max(0.01, volumeBeforeMute))
            } else {
                volumeBeforeMute = getVolume()
                simulatedMute = true
                setVolume(0.0)
            }
        }
    }

    /// Set mute state
    func setMute(_ mute: Bool) {
        guard let info = activeDeviceInfo else { return }
        if info.hasMute && info.isMuteSettable {
            setCoreAudioMute(mute)
        } else if volumeMethod == .appleScript {
            setAppleScriptMute(mute)
        } else {
            if mute && !simulatedMute {
                volumeBeforeMute = getVolume()
                simulatedMute = true
                setVolume(0.0)
            } else if !mute && simulatedMute {
                simulatedMute = false
                setVolume(max(0.01, volumeBeforeMute))
            }
        }
    }

    /// Get device name for display
    var activeDeviceName: String {
        return activeDeviceInfo?.name ?? "Unknown"
    }

    // MARK: - Device Enumeration (A4)

    /// Refresh all devices and re-detect capabilities
    func refreshAllDevices() {
        let previousDeviceID = activeDeviceID
        allOutputDevices = enumerateOutputDevices()
        activeDeviceID = getDefaultOutputDeviceID()
        activeDeviceInfo = probeDevice(activeDeviceID)

        // Determine best volume method
        if let info = activeDeviceInfo {
            volumeMethod = info.bestVolumeMethod
        } else {
            volumeMethod = .appleScript
        }

        // Install volume/mute listeners on the new active device
        removeVolumeListeners()
        installVolumeListeners()

        let methodStr = volumeMethod.rawValue
        let deviceName = activeDeviceInfo?.name ?? "Unknown"
        let transport = activeDeviceInfo?.transportName ?? "?"
        NSLog("Audio: default device=\(activeDeviceID) \"\(deviceName)\" transport=\(transport) method=\(methodStr)")

        // Log all devices
        for dev in allOutputDevices {
            let isDefault = dev.deviceID == activeDeviceID ? " [DEFAULT]" : ""
            NSLog("  Device \(dev.deviceID): \"\(dev.name)\" \(dev.transportName) vol=\(dev.volumeIcon) method=\(dev.bestVolumeMethod.rawValue)\(isDefault)")
        }

        if previousDeviceID != activeDeviceID {
            simulatedMute = false
            DispatchQueue.main.async {
                self.delegate?.audioDeviceDidChange(deviceName: deviceName, method: self.volumeMethod)
            }
        }
    }

    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func enumerateOutputDevices() -> [AudioDeviceInfo] {
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, 0, nil, &devicesSize)
        let deviceCount = Int(devicesSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, 0, nil, &devicesSize, &devices)

        var result: [AudioDeviceInfo] = []
        for dev in devices {
            // Check output stream count
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize)
            let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
            guard streamCount > 0 else { continue }

            if let info = probeDevice(dev) {
                result.append(info)
            }
        }
        return result
    }

    /// Full capability probe for a single device (A4 + A10)
    private func probeDevice(_ deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName)
        let uid = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)

        // Transport type
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport)

        // Volume scalar (element 0 = master)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        let hasVolScalar = AudioObjectHasProperty(deviceID, &volAddr)

        // Channel volume (elements 1, 2)
        volAddr.mElement = 1
        let hasCh1 = AudioObjectHasProperty(deviceID, &volAddr)
        volAddr.mElement = 2
        let hasCh2 = AudioObjectHasProperty(deviceID, &volAddr)
        let hasChannelVolume = hasCh1 || hasCh2

        // Virtual master volume (Tier 1b) — uses AudioHardwareService API
        var vmAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var hasVirtualMaster = false
        var vmVol: Float32 = 0
        var vmSize = UInt32(MemoryLayout<Float32>.size)
        let vmStatus = AudioObjectGetPropertyData(deviceID, &vmAddr, 0, nil, &vmSize, &vmVol)
        if vmStatus == noErr {
            hasVirtualMaster = true
        }

        // Mute
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMute = AudioObjectHasProperty(deviceID, &muteAddr)

        // Settability check (A10)
        var isVolumeSettable: DarwinBoolean = false
        if hasVolScalar {
            var setAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 0
            )
            AudioObjectIsPropertySettable(deviceID, &setAddr, &isVolumeSettable)
        } else if hasVirtualMaster {
            AudioObjectIsPropertySettable(deviceID, &vmAddr, &isVolumeSettable)
        } else if hasChannelVolume {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 1
            )
            AudioObjectIsPropertySettable(deviceID, &chAddr, &isVolumeSettable)
        }

        var isMuteSettable: DarwinBoolean = false
        if hasMute {
            AudioObjectIsPropertySettable(deviceID, &muteAddr, &isMuteSettable)
        }

        // Output stream count
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
        let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size

        return AudioDeviceInfo(
            deviceID: deviceID,
            name: name as String,
            uid: uid as String,
            transportType: transport,
            hasVolumeScalar: hasVolScalar,
            hasChannelVolume: hasChannelVolume,
            hasVirtualMaster: hasVirtualMaster,
            hasMute: hasMute,
            isVolumeSettable: isVolumeSettable.boolValue,
            isMuteSettable: isMuteSettable.boolValue,
            outputStreamCount: streamCount
        )
    }

    // MARK: - Device Change Listener (A2)

    private func installDeviceChangeListener() {
        guard !deviceListenerInstalled else { return }

        // Listen for default output device changes
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDevAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            NSLog("Audio: default output device changed")
            self?.refreshAllDevices()
        }

        // Listen for device list changes (connect/disconnect)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            NSLog("Audio: device list changed")
            self?.refreshAllDevices()
        }

        deviceListenerInstalled = true
        NSLog("Audio: device change listeners installed")
    }

    // MARK: - Volume Change Listener (A3)

    private func installVolumeListeners() {
        guard activeDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        // Listen for volume changes
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        if AudioObjectHasProperty(activeDeviceID, &volAddr) {
            AudioObjectAddPropertyListenerBlock(activeDeviceID, &volAddr, DispatchQueue.main) { [weak self] _, _ in
                self?.onExternalVolumeChange()
            }
            volumeListenerInstalled = true
        }

        // Listen for mute changes
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(activeDeviceID, &muteAddr) {
            AudioObjectAddPropertyListenerBlock(activeDeviceID, &muteAddr, DispatchQueue.main) { [weak self] _, _ in
                self?.onExternalVolumeChange()
            }
            muteListenerInstalled = true
        }
    }

    private func removeVolumeListeners() {
        guard activeDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        if volumeListenerInstalled {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 0
            )
            AudioObjectRemovePropertyListenerBlock(activeDeviceID, &volAddr, DispatchQueue.main, { _, _ in })
            volumeListenerInstalled = false
        }

        if muteListenerInstalled {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(activeDeviceID, &muteAddr, DispatchQueue.main, { _, _ in })
            muteListenerInstalled = false
        }
    }

    private func onExternalVolumeChange() {
        let vol = getVolume()
        let muted = isMuted()
        delegate?.volumeDidChange(volume: vol, muted: muted)
    }

    // MARK: - Sleep/Wake Handling (A8)

    private func installSleepWakeListener() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSLog("Audio: system woke from sleep, re-detecting devices")
            // Delay slightly — audio subsystem needs time to reinitialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refreshAllDevices()
            }
        }
    }

    // MARK: - Tier 1: CoreAudio Direct Volume

    private func getCoreAudioVolume(element: UInt32) -> Float {
        var volume: Float32 = 0.0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        let status = AudioObjectGetPropertyData(activeDeviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : 0.5
    }

    private func setCoreAudioVolume(_ volume: Float, element: UInt32) {
        var vol = Float32(volume)
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        AudioObjectSetPropertyData(activeDeviceID, &address, 0, nil, size, &vol)
    }

    // MARK: - Tier 1 Channel Volume with L/R Balance Preservation (A6)

    private func getCoreAudioChannelAverage() -> Float {
        var total: Float = 0
        var count: Float = 0
        for ch: UInt32 in [1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(activeDeviceID, &address) {
                var vol: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(activeDeviceID, &address, 0, nil, &size, &vol) == noErr {
                    total += vol
                    count += 1
                }
            }
        }
        return count > 0 ? total / count : 0.5
    }

    private func setCoreAudioChannelVolume(_ volume: Float) {
        // Read current L/R to preserve balance ratio (A6)
        var chVols: [UInt32: Float] = [:]
        for ch: UInt32 in [1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(activeDeviceID, &address) {
                var vol: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(activeDeviceID, &address, 0, nil, &size, &vol) == noErr {
                    chVols[ch] = vol
                }
            }
        }

        let currentAvg = chVols.values.reduce(0, +) / max(1, Float(chVols.count))
        let delta = volume - currentAvg

        // Apply delta to each channel, preserving relative balance
        let size = UInt32(MemoryLayout<Float32>.size)
        for (ch, oldVol) in chVols {
            var newVol = Float32(max(0.0, min(1.0, oldVol + delta)))
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            AudioObjectSetPropertyData(activeDeviceID, &address, 0, nil, size, &newVol)
        }
    }

    // MARK: - Tier 1b: Virtual Master Volume (A1)

    private func getVirtualMasterVolume() -> Float {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(activeDeviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : 0.5
    }

    private func setVirtualMasterVolume(_ volume: Float) {
        var vol = Float32(volume)
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(activeDeviceID, &address, 0, nil, size, &vol)
    }

    // MARK: - CoreAudio Mute

    private func getCoreAudioMute() -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(activeDeviceID, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    private func setCoreAudioMute(_ mute: Bool) {
        var muted: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(activeDeviceID, &address, 0, nil, size, &muted)
    }

    // MARK: - Tier 2: AppleScript (with rate limiting — A7)

    private func getAppleScriptVolume() -> Float {
        let script = NSAppleScript(source: "output volume of (get volume settings)")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let val = result?.int32Value {
            return Float(val) / 100.0
        }
        return 0.5
    }

    private func setAppleScriptVolumeThrottled(_ volume: Float) {
        pendingAppleScriptVolume = volume

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastAppleScriptTime

        if elapsed >= appleScriptMinInterval {
            flushAppleScriptVolume()
        } else {
            // Schedule flush after remaining interval
            appleScriptTimer?.invalidate()
            let remaining = appleScriptMinInterval - elapsed
            appleScriptTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                self?.flushAppleScriptVolume()
            }
        }
    }

    private func flushAppleScriptVolume() {
        guard let volume = pendingAppleScriptVolume else { return }
        pendingAppleScriptVolume = nil
        lastAppleScriptTime = ProcessInfo.processInfo.systemUptime

        let intVol = Int(volume * 100)
        let script = NSAppleScript(source: "set volume output volume \(intVol)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    private func getAppleScriptMute() -> Bool {
        let script = NSAppleScript(source: "output muted of (get volume settings)")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        return result?.booleanValue ?? false
    }

    private func toggleAppleScriptMute() {
        let muted = getAppleScriptMute()
        setAppleScriptMute(!muted)
    }

    private func setAppleScriptMute(_ mute: Bool) {
        let script = NSAppleScript(source: "set volume output muted \(mute)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    // MARK: - Helpers

    private func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return "Unknown"
        }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr) == noErr else {
            return "Unknown"
        }
        let cfStr = ptr.load(as: CFString.self)
        return cfStr as String
    }
}
