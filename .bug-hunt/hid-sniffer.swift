// Passive HID sniffer for the Griffin PowerMate (vendor 0x077d, product 0x0410).
// Counts raw input reports while nobody touches the device, to test the
// phantom-HID-activity / sleep-prevention theory.
import Foundation
import IOKit
import IOKit.hid

let vendorID: Int = 0x077d
let productID: Int = 0x0410

var reportCount = 0
var lastReportTime = Date()
let startTime = Date()

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matchDict: [String: Any] = [
    kIOHIDVendorIDKey as String: vendorID,
    kIOHIDProductIDKey as String: productID,
]
IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    reportCount += 1
    lastReportTime = Date()
    let button = reportLength > 0 ? report[0] : 0
    let rotation = reportLength > 1 ? Int8(bitPattern: report[1]) : 0
    print("REPORT #\(reportCount) at +\(Date().timeIntervalSince(startTime).formatted(.number.precision(.fractionLength(1))))s button=\(button) rotation=\(rotation)")
    fflush(stdout)
}

let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
let reportBufferSize = CFIndex(8)

IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
    print("DEVICE MATCHED")
    IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, reportBufferSize, inputCallback, nil)
    fflush(stdout)
}, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

print("Sniffing raw HID reports from PowerMate for 90s. DON'T touch the knob.")
fflush(stdout)

// Run for 90 seconds
Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
    print("=== 90s SUMMARY: \(reportCount) raw reports received, last at +\(Date().timeIntervalSince(lastReportTime).formatted(.number.precision(.fractionLength(1))))s ago ===")
    fflush(stdout)
    exit(0)
}

RunLoop.main.run(until: Date().addingTimeInterval(120))