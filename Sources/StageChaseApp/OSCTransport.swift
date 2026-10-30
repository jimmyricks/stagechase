import Foundation
import Combine
import Network
import StageChaseCore

@MainActor
final class OSCTransport: ObservableObject {
    @Published var host: String {
        didSet {
            UserDefaults.standard.set(host, forKey: "oscHost")
            reconnectIfNeeded()
        }
    }
    @Published var portText: String {
        didSet {
            UserDefaults.standard.set(portText, forKey: "oscPort")
            reconnectIfNeeded()
        }
    }
    @Published private(set) var status = "Not connected"
    @Published private(set) var lastSent = ""

    private var connection: NWConnection?
    private var endpointKey = ""
    private var strobeTasks: [String: Task<Void, Never>] = [:]

    init() {
        host = UserDefaults.standard.string(forKey: "oscHost") ?? "127.0.0.1"
        portText = UserDefaults.standard.string(forKey: "oscPort") ?? "7000"
    }

    func isStrobing(_ id: String) -> Bool {
        strobeTasks[id] != nil
    }

    var port: NWEndpoint.Port? {
        guard let raw = UInt16(portText), raw > 0 else { return nil }
        return NWEndpoint.Port(rawValue: raw)
    }

    func send(address: String, value: Float) {
        guard OSCAddress.isValid(address), value.isFinite else {
            status = "Invalid OSC address or value"
            return
        }
        guard let packet = try? OSCMessage.float(address: address, value: value) else {
            status = "Could not encode OSC message"
            return
        }
        guard ensureConnection() else { return }
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.status = "Send failed: \(error.localizedDescription)"
                } else {
                    self?.lastSent = "\(address)  \(value.formatted(.number.precision(.fractionLength(0...3))))"
                    self?.status = "Sent via UDP"
                }
            }
        })
    }

    func trigger(address: String) {
        guard let packet = try? OSCMessage.trigger(address: address) else {
            status = "Invalid OSC trigger address"
            return
        }
        guard ensureConnection() else { return }
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.status = "Send failed: \(error.localizedDescription)"
                } else {
                    self?.lastSent = "\(address)  trigger"
                    self?.status = "Sent via UDP"
                }
            }
        })
    }

    func toggleStrobe(_ widget: OSCWidget) {
        if strobeTasks[widget.id] != nil {
            stopStrobe(widget)
            return
        }
        guard OSCAddress.isValid(widget.address) else {
            status = "Set a valid OSC address before starting the strobe"
            return
        }
        let interval = Duration.milliseconds(Int(1000 / (min(max(widget.strobeRate, 1), 20) * 2)))
        strobeTasks[widget.id] = Task { [weak self] in
            var high = false
            while !Task.isCancelled {
                guard let self else { return }
                self.send(address: widget.address, value: high ? widget.maximum : widget.minimum)
                high.toggle()
                try? await Task.sleep(for: interval)
            }
        }
        status = "Strobe active"
    }

    func stopStrobe(_ widget: OSCWidget) {
        strobeTasks.removeValue(forKey: widget.id)?.cancel()
        send(address: widget.address, value: widget.restingValue)
        status = "Strobe stopped"
    }

    func stopAllStrobes(widgets: [OSCWidget]) {
        for widget in widgets where strobeTasks[widget.id] != nil {
            stopStrobe(widget)
        }
    }

    private func reconnectIfNeeded() {
        if let connection, endpointKey != "\(host):\(portText)" {
            connection.cancel()
            self.connection = nil
            endpointKey = ""
            status = "Not connected"
        }
    }

    @discardableResult
    private func ensureConnection() -> Bool {
        guard let port else {
            status = "Enter a valid UDP port"
            return false
        }
        let key = "\(host):\(portText)"
        if connection == nil || endpointKey != key {
            connection?.cancel()
            let next = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
            endpointKey = key
            connection = next
            next.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "UDP ready · delivery is not confirmed"
                    case .failed(let error): self?.status = "UDP unavailable: \(error.localizedDescription)"
                    case .cancelled: self?.status = "Not connected"
                    default: break
                    }
                }
            }
            next.start(queue: .global(qos: .userInitiated))
        }
        return true
    }
}
