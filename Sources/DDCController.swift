import Foundation
import CoreGraphics
import IOKit

/// DDC/CI controller for external monitors on Apple Silicon.
/// Sends DDC commands via IOAVService I2C to control brightness, volume, contrast, etc.
/// VCP codes: 0x10 = brightness, 0x12 = contrast, 0x62 = volume
class DDCController {

    // MARK: - VCP Codes

    static let vcpBrightness: UInt8 = 0x10
    static let vcpContrast: UInt8 = 0x12
    static let vcpVolume: UInt8 = 0x62

    // MARK: - DDC Display Info

    struct DDCDisplay {
        let displayID: CGDirectDisplayID
        let service: io_service_t
        let name: String
        let supportsDDC: Bool
        var cachedBrightness: UInt8?
        var cachedVolume: UInt8?
    }

    // MARK: - State

    private(set) var displays: [CGDirectDisplayID: DDCDisplay] = [:]
    private(set) var isAvailable: Bool = false
    var isEnabled: Bool = true  // user toggle — set to false to disable DDC globally

    // Rate limiting
    private let ddcQueue = DispatchQueue(label: "com.powermate.ddc", qos: .userInteractive)
    private var lastCommandTime: [CGDirectDisplayID: TimeInterval] = [:]
    private let minCommandInterval: TimeInterval = 0.1  // 100ms between DDC writes per display
    private var pendingWrites: [CGDirectDisplayID: (vcp: UInt8, value: UInt8)] = [:]
    private var coalesceTimers: [CGDirectDisplayID: Timer] = [:]

    // IOAVService I2C functions (loaded dynamically)
    private typealias IOAVServiceReadI2CFunc = @convention(c) (io_service_t, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
    private typealias IOAVServiceWriteI2CFunc = @convention(c) (io_service_t, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
    private var readI2C: IOAVServiceReadI2CFunc?
    private var writeI2C: IOAVServiceWriteI2CFunc?

    init() {
        loadIOAVService()
        probeDisplays()
    }

    deinit {
        for (_, display) in displays {
            if display.service != IO_OBJECT_NULL {
                IOObjectRelease(display.service)
            }
        }
    }

    // MARK: - Setup

    private func loadIOAVService() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            NSLog("DDC: failed to open IOKit")
            return
        }
        if let readPtr = dlsym(handle, "IOAVServiceReadI2C") {
            readI2C = unsafeBitCast(readPtr, to: IOAVServiceReadI2CFunc.self)
        }
        if let writePtr = dlsym(handle, "IOAVServiceWriteI2C") {
            writeI2C = unsafeBitCast(writePtr, to: IOAVServiceWriteI2CFunc.self)
        }
        isAvailable = (readI2C != nil && writeI2C != nil)
        if isAvailable {
            NSLog("DDC: IOAVService I2C functions loaded")
        } else {
            NSLog("DDC: IOAVService I2C functions not available (Intel Mac or API changed)")
        }
    }

    // MARK: - Display Probing

    /// Probe all connected displays for DDC/CI support. Call on startup and display change.
    func probeDisplays() {
        guard isAvailable && isEnabled else { return }

        // Release old services
        for (_, display) in displays {
            if display.service != IO_OBJECT_NULL {
                IOObjectRelease(display.service)
            }
        }
        displays.removeAll()

        // Enumerate displays
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            // Skip built-in displays (they use DisplayServices, not DDC)
            if CGDisplayIsBuiltin(displayID) != 0 { continue }

            let service = findIOAVService(for: displayID)
            let name = displayName(for: displayID)

            if service != IO_OBJECT_NULL {
                // Test DDC by reading brightness
                var supportsDDC = false
                var cachedBrightness: UInt8? = nil
                if let (current, _) = readVCP(service: service, vcp: Self.vcpBrightness) {
                    supportsDDC = true
                    cachedBrightness = current
                    NSLog("DDC: display %d '%@' — DDC OK (brightness=%d)", displayID, name, current)
                } else {
                    NSLog("DDC: display %d '%@' — DDC probe failed", displayID, name)
                }

                displays[displayID] = DDCDisplay(
                    displayID: displayID,
                    service: service,
                    name: name,
                    supportsDDC: supportsDDC,
                    cachedBrightness: cachedBrightness,
                    cachedVolume: nil
                )
            } else {
                NSLog("DDC: display %d '%@' — no IOAVService found", displayID, name)
            }
        }
    }

    /// Check if a specific display supports DDC
    func supportsDDC(displayID: CGDirectDisplayID) -> Bool {
        guard isEnabled else { return false }
        return displays[displayID]?.supportsDDC ?? false
    }

    // MARK: - Public API (rate-limited)

    /// Set brightness (0-100) for a display via DDC. Rate-limited and coalesced.
    func setBrightness(_ value: UInt8, displayID: CGDirectDisplayID) {
        guard isEnabled else { return }
        setVCPCoalesced(displayID: displayID, vcp: Self.vcpBrightness, value: min(100, value))
    }

    /// Get cached brightness (0-100) for a display. Returns nil if DDC not supported.
    func getBrightness(displayID: CGDirectDisplayID) -> UInt8? {
        guard isEnabled else { return nil }
        return displays[displayID]?.cachedBrightness
    }

    /// Set volume (0-100) for a display via DDC. Rate-limited and coalesced.
    func setVolume(_ value: UInt8, displayID: CGDirectDisplayID) {
        guard isEnabled else { return }
        setVCPCoalesced(displayID: displayID, vcp: Self.vcpVolume, value: min(100, value))
    }

    /// Get cached volume (0-100) for a display. Returns nil if DDC not supported.
    func getVolume(displayID: CGDirectDisplayID) -> UInt8? {
        guard isEnabled else { return nil }
        return displays[displayID]?.cachedVolume
    }

    /// Read a VCP value fresh from the display (slow — 50-200ms). Use sparingly.
    func readBrightness(displayID: CGDirectDisplayID) -> UInt8? {
        guard isEnabled, let display = displays[displayID], display.supportsDDC else { return nil }
        if let (current, _) = readVCP(service: display.service, vcp: Self.vcpBrightness) {
            displays[displayID]?.cachedBrightness = current
            return current
        }
        return nil
    }

    // MARK: - Rate Limiting + Coalescing

    private func setVCPCoalesced(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt8) {
        guard let display = displays[displayID], display.supportsDDC else { return }

        pendingWrites[displayID] = (vcp: vcp, value: value)

        let now = ProcessInfo.processInfo.systemUptime
        let lastTime = lastCommandTime[displayID] ?? 0
        let elapsed = now - lastTime

        if elapsed >= minCommandInterval {
            flushWrite(displayID: displayID)
        } else {
            // Schedule flush after remaining interval
            coalesceTimers[displayID]?.invalidate()
            let remaining = minCommandInterval - elapsed
            coalesceTimers[displayID] = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                self?.flushWrite(displayID: displayID)
            }
        }
    }

    private func flushWrite(displayID: CGDirectDisplayID) {
        guard let pending = pendingWrites[displayID],
              let display = displays[displayID] else { return }
        pendingWrites.removeValue(forKey: displayID)
        lastCommandTime[displayID] = ProcessInfo.processInfo.systemUptime

        ddcQueue.async { [weak self] in
            self?.writeVCP(service: display.service, vcp: pending.vcp, value: UInt16(pending.value))
            // Update cache
            DispatchQueue.main.async {
                if pending.vcp == Self.vcpBrightness {
                    self?.displays[displayID]?.cachedBrightness = pending.value
                } else if pending.vcp == Self.vcpVolume {
                    self?.displays[displayID]?.cachedVolume = pending.value
                }
            }
        }
    }

    // MARK: - IOAVService Lookup

    private func findIOAVService(for displayID: CGDirectDisplayID) -> io_service_t {
        // On Apple Silicon, IOAVService instances correspond to display outputs
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAVService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(iterator) }

        // For single-display setups, just grab the first IOAVService
        // For multi-display, we match by iterating and checking display index
        var service: io_service_t = IOIteratorNext(iterator)
        var index: UInt32 = 0
        let targetIndex = externalDisplayIndex(displayID)

        while service != IO_OBJECT_NULL {
            if index == targetIndex {
                return service
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
            index += 1
        }

        return IO_OBJECT_NULL
    }

    /// Map a CGDirectDisplayID to an external display index (0-based, skipping built-in)
    private func externalDisplayIndex(_ displayID: CGDirectDisplayID) -> UInt32 {
        var allDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &allDisplays, &count)

        var externalIndex: UInt32 = 0
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(allDisplays[i]) != 0 { continue }
            if allDisplays[i] == displayID { return externalIndex }
            externalIndex += 1
        }
        return 0
    }

    // MARK: - DDC/CI Protocol

    /// Read a VCP feature. Returns (currentValue, maxValue) or nil on failure.
    private func readVCP(service: io_service_t, vcp: UInt8) -> (UInt8, UInt8)? {
        guard let readI2C = readI2C else { return nil }

        // DDC/CI GET VCP Feature request
        var request: [UInt8] = [0x51, 0x82, 0x01, vcp]
        let checksum = request.reduce(UInt8(0x6E)) { $0 ^ $1 }
        request.append(checksum)

        // Write the request
        guard let writeI2C = writeI2C else { return nil }
        var writeData = request
        let writeResult = writeI2C(service, 0x37, 0, &writeData, UInt32(writeData.count))
        guard writeResult == KERN_SUCCESS else { return nil }

        // Wait for monitor to process
        usleep(40_000)  // 40ms

        // Read the response (11 bytes for VCP reply)
        var response = [UInt8](repeating: 0, count: 11)
        let readResult = readI2C(service, 0x37, 0, &response, UInt32(response.count))
        guard readResult == KERN_SUCCESS else { return nil }

        // Parse DDC/CI VCP reply
        // Expected format: [src, length, 0x02, resultCode, vcp, typeCode, MH, ML, SH, SL, checksum]
        guard response.count >= 11,
              response[2] == 0x02,  // VCP reply opcode
              response[4] == vcp    // correct VCP code
        else { return nil }

        let maxValue = UInt8(min(255, (UInt16(response[6]) << 8) | UInt16(response[7])))
        let currentValue = UInt8(min(255, (UInt16(response[8]) << 8) | UInt16(response[9])))

        return (currentValue, maxValue)
    }

    /// Write a VCP feature value.
    private func writeVCP(service: io_service_t, vcp: UInt8, value: UInt16) {
        guard let writeI2C = writeI2C else { return }

        // DDC/CI SET VCP Feature
        var request: [UInt8] = [
            0x51,               // source address
            0x84,               // length (4 bytes follow, excluding checksum)
            0x03,               // SET VCP opcode
            vcp,                // VCP code
            UInt8(value >> 8),  // value high byte
            UInt8(value & 0xFF) // value low byte
        ]
        let checksum = request.reduce(UInt8(0x6E)) { $0 ^ $1 }
        request.append(checksum)

        var data = request
        let result = writeI2C(service, 0x37, 0, &data, UInt32(data.count))
        if result != KERN_SUCCESS {
            NSLog("DDC: writeVCP failed (vcp=0x%02X, value=%d, err=%d)", vcp, value, result)
        }
    }

    // MARK: - Helpers

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        switch vendor {
        case 0x1E6D: return "LG Display"
        case 0x10AC: return "Dell Display"
        case 0x0610: return "Apple Display"
        case 0x0469: return "Samsung Display"
        case 0x0D32: return "BenQ Display"
        case 0x0B05: return "ASUS Display"
        default: return "Display \(model)"
        }
    }
}
