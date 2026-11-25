import Foundation

/// Settings that belong to one PowerMate identity (a USB hub, a Mac port, or
/// one Bluetooth peripheral). Machine-wide settings stay in AppDelegate.
struct PowerMateDeviceRecord: Codable, Equatable {
    var displayName: String
    var currentMode: String
    var enabledModes: [String]
    var stepSize: Float
    var ledFollowsLevel: Bool
    /// Static LED level used when `ledFollowsLevel` is false.
    var ledBrightness: UInt8
    var longPressThreshold: Double
    var doubleTapInterval: Double
    var volumeSnapValue: Float
    var brightnessSnapValue: Float
    var midiCCNumber: Int
    var midiChannel: Int
    /// CoreAudio device UID, or "apple-music". Nil keeps the shared
    /// system-default routing map.
    var outputUID: String?

    static func factory() -> PowerMateDeviceRecord {
        PowerMateDeviceRecord(
            displayName: "PowerMate",
            currentMode: KnobMode.volume.rawValue,
            enabledModes: [KnobMode.volume.rawValue, KnobMode.brightness.rawValue],
            stepSize: 0.03,
            ledFollowsLevel: true,
            ledBrightness: 0,
            longPressThreshold: 0.5,
            doubleTapInterval: 0.3,
            volumeSnapValue: 0.20,
            brightnessSnapValue: 0.67,
            midiCCNumber: 1,
            midiChannel: 0,
            outputUID: nil
        )
    }

    var mode: KnobMode {
        KnobMode(rawValue: currentMode) ?? .volume
    }

    var modes: [KnobMode] {
        let parsed = enabledModes.compactMap { KnobMode(rawValue: $0) }
        return parsed.isEmpty ? [.volume] : parsed
    }
}

/// Persists per-knob records under `powermate.devices`. The first launch
/// copies the old global keys into `template`; every new identity starts as
/// a copy of that template, not of another knob's later edits.
final class PowerMateDeviceStore {
    static let shared = PowerMateDeviceStore()
    static let appleMusicUID = "apple-music"

    private let defaultsKey = "powermate.devices"

    private(set) var template: PowerMateDeviceRecord
    private(set) var records: [String: PowerMateDeviceRecord] = [:]

    private struct Blob: Codable {
        var template: PowerMateDeviceRecord
        var records: [String: PowerMateDeviceRecord]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            template = blob.template
            records = blob.records
        } else {
            template = Self.templateFromLegacyDefaults()
            save()
        }
    }

    func record(for identity: String) -> PowerMateDeviceRecord {
        records[identity] ?? template
    }

    /// Insert a record for a newly seen device, or refresh the stored display name.
    @discardableResult
    func ensure(identity: String, displayName: String) -> PowerMateDeviceRecord {
        if var existing = records[identity] {
            existing.displayName = displayName
            records[identity] = existing
            save()
            return existing
        }
        var created = template
        created.displayName = displayName
        records[identity] = created
        save()
        NSLog("Settings: new knob %@ (%@) from template", displayName, identity)
        return created
    }

    func update(identity: String, _ body: (inout PowerMateDeviceRecord) -> Void) {
        var rec = records[identity] ?? template
        body(&rec)
        records[identity] = rec
        save()
    }

    func updateTemplate(_ body: (inout PowerMateDeviceRecord) -> Void) {
        body(&template)
        save()
    }

    func knownDevices() -> [(identity: String, displayName: String)] {
        records.map { ($0.key, $0.value.displayName) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func save() {
        let blob = Blob(template: template, records: records)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Legacy migration

    /// One-time read of the pre-per-knob keys. Left in place so an older
    /// build can still see them; new writes go only to `powermate.devices`.
    private static func templateFromLegacyDefaults() -> PowerMateDeviceRecord {
        let d = UserDefaults.standard
        var record = PowerMateDeviceRecord.factory()
        if let mode = d.string(forKey: "powermate.currentMode"), KnobMode(rawValue: mode) != nil {
            record.currentMode = mode
        }
        if let modes = d.array(forKey: "powermate.enabledModes") as? [String] {
            let parsed = modes.filter { KnobMode(rawValue: $0) != nil }
            if !parsed.isEmpty { record.enabledModes = parsed }
        }
        if d.object(forKey: "powermate.stepSize") != nil {
            record.stepSize = d.float(forKey: "powermate.stepSize")
        }
        if d.object(forKey: "powermate.ledFollowsLevel") != nil {
            record.ledFollowsLevel = d.bool(forKey: "powermate.ledFollowsLevel")
        }
        if d.object(forKey: "powermate.longPressThreshold") != nil {
            record.longPressThreshold = d.double(forKey: "powermate.longPressThreshold")
        }
        if d.object(forKey: "powermate.doubleTapInterval") != nil {
            record.doubleTapInterval = d.double(forKey: "powermate.doubleTapInterval")
        }
        if d.object(forKey: "powermate.volume.snapValue") != nil {
            record.volumeSnapValue = d.float(forKey: "powermate.volume.snapValue")
        }
        if d.object(forKey: "powermate.brightness.snapValue") != nil {
            record.brightnessSnapValue = d.float(forKey: "powermate.brightness.snapValue")
        }
        if d.object(forKey: "powermate.midi.ccNumber") != nil {
            record.midiCCNumber = d.integer(forKey: "powermate.midi.ccNumber")
        }
        if d.object(forKey: "powermate.midi.channel") != nil {
            record.midiChannel = d.integer(forKey: "powermate.midi.channel")
        }
        return record
    }
}
