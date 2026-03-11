import Foundation
import CoreMIDI

/// Basic MIDI controller for PowerMate.
/// Knob rotation sends CC messages, button press sends note on/off.
/// Creates a virtual MIDI source that any DAW can receive from.
class MIDIController {
    private var midiClient: MIDIClientRef = 0
    private var midiSource: MIDIEndpointRef = 0
    private(set) var isAvailable: Bool = false

    // MIDI parameters (configurable)
    var channel: UInt8 = 0          // MIDI channel 1 (0-indexed)
    var ccNumber: UInt8 = 1         // CC #1 (Mod Wheel) — common default
    var noteNumber: UInt8 = 60      // Middle C for button press
    var noteVelocity: UInt8 = 127   // Full velocity

    // Current CC value (0-127), tracks knob position
    private(set) var ccValue: UInt8 = 64  // Start at center

    // Note state for toggle behavior
    private var noteIsOn: Bool = false

    init() {
        setupMIDI()
    }

    deinit {
        if midiSource != 0 {
            MIDIEndpointDispose(midiSource)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }

    // MARK: - Setup

    private func setupMIDI() {
        var status = MIDIClientCreateWithBlock("PowerMateReborn" as CFString, &midiClient) { notification in
            NSLog("MIDI: notification type=%d", notification.pointee.messageID.rawValue)
        }

        guard status == noErr else {
            NSLog("MIDI: failed to create client (err=%d)", status)
            return
        }

        status = MIDISourceCreate(midiClient, "PowerMate Knob" as CFString, &midiSource)
        guard status == noErr else {
            NSLog("MIDI: failed to create source (err=%d)", status)
            return
        }

        isAvailable = true
        NSLog("MIDI: virtual source 'PowerMate Knob' created (CC#%d, ch%d)", ccNumber, channel + 1)
    }

    // MARK: - Public API

    /// Adjust CC value by a delta (from knob rotation). Delta is in float steps.
    func adjustCC(by delta: Float) {
        let newVal = Float(ccValue) + delta * 127.0
        ccValue = UInt8(max(0, min(127, Int(newVal))))
        sendCC(ccNumber, value: ccValue)
    }

    /// Set CC value directly (0-127)
    func setCC(_ value: UInt8) {
        ccValue = value
        sendCC(ccNumber, value: ccValue)
    }

    /// Send a note-on (button press)
    func sendNoteOn() {
        noteIsOn = true
        sendNote(noteNumber, velocity: noteVelocity, on: true)
    }

    /// Send a note-off (button release)
    func sendNoteOff() {
        noteIsOn = false
        sendNote(noteNumber, velocity: 0, on: false)
    }

    /// Toggle note on/off (for single press behavior)
    func toggleNote() {
        if noteIsOn {
            sendNoteOff()
        } else {
            sendNoteOn()
        }
    }

    /// Current CC value as a 0.0-1.0 float (for LED tracking)
    var ccLevel: Float {
        return Float(ccValue) / 127.0
    }

    // MARK: - MIDI Message Sending

    private func sendCC(_ cc: UInt8, value: UInt8) {
        guard isAvailable else { return }
        let status: UInt8 = 0xB0 | (channel & 0x0F)  // Control Change
        sendMessage([status, cc, value])
    }

    private func sendNote(_ note: UInt8, velocity: UInt8, on: Bool) {
        guard isAvailable else { return }
        let status: UInt8 = (on ? 0x90 : 0x80) | (channel & 0x0F)
        sendMessage([status, note, velocity])
    }

    private func sendMessage(_ bytes: [UInt8]) {
        guard isAvailable else { return }

        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)

        let status = MIDIReceived(midiSource, &packetList)
        if status != noErr {
            NSLog("MIDI: send failed (err=%d)", status)
        }
    }
}
