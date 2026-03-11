import Foundation
import Network

/// Lightweight OSC (Open Sound Control) sender over UDP.
/// Supports sending float and int OSC messages to arbitrary endpoints.
class OSCController {
    private var connections: [String: NWConnection] = [:]

    /// Send an OSC message with a float value
    func sendFloat(_ path: String, value: Float, host: String, port: UInt16) {
        let data = buildOSCMessage(path: path, typeTag: ",f", payload: floatBytes(value))
        send(data, host: host, port: port)
    }

    /// Send an OSC message with an int value
    func sendInt(_ path: String, value: Int32, host: String, port: UInt16) {
        let data = buildOSCMessage(path: path, typeTag: ",i", payload: intBytes(value))
        send(data, host: host, port: port)
    }

    /// Send an OSC message with no arguments (bang / trigger)
    func sendTrigger(_ path: String, host: String, port: UInt16) {
        let data = buildOSCMessage(path: path, typeTag: ",", payload: Data())
        send(data, host: host, port: port)
    }

    // MARK: - OSC Message Builder

    private func buildOSCMessage(path: String, typeTag: String, payload: Data) -> Data {
        var msg = Data()
        msg.append(oscString(path))
        msg.append(oscString(typeTag))
        msg.append(payload)
        return msg
    }

    /// OSC strings are null-terminated and padded to 4-byte boundaries
    private func oscString(_ string: String) -> Data {
        var data = string.data(using: .utf8) ?? Data()
        data.append(0) // null terminator
        // Pad to 4-byte boundary
        while data.count % 4 != 0 {
            data.append(0)
        }
        return data
    }

    private func floatBytes(_ value: Float) -> Data {
        var big = value.bitPattern.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private func intBytes(_ value: Int32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    // MARK: - Network

    private func send(_ data: Data, host: String, port: UInt16) {
        let key = "\(host):\(port)"

        if connections[key] == nil {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let connection = NWConnection(to: endpoint, using: .udp)
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("OSC: connection to %@ failed: %@", key, error.localizedDescription)
                }
            }
            connection.start(queue: .global(qos: .userInteractive))
            connections[key] = connection
        }

        connections[key]?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                NSLog("OSC: send to %@ failed: %@", key, error.localizedDescription)
            }
        })
    }

    /// Cleanup all connections
    func shutdown() {
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
    }
}
