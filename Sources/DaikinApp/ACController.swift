import DaikinKit
import Foundation
import Observation
import os

/// Live state of one air conditioner: polls it, applies edits optimistically and keeps
/// every request in a single queue, since the module's HTTP server handles one at a time.
@MainActor @Observable
final class ACController {
    let device: DeviceConfig

    private(set) var port: UnitState?
    private(set) var capabilities: DeviceInfo?
    /// Set while the unit cannot be reached; cleared by the next successful exchange.
    private(set) var errorMessage: String?
    /// Short-lived message about a command the unit refused.
    private(set) var notice: String?
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let client: DaikinClient?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var temperatureTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingEdits = 0
    @ObservationIgnored private var wasReachable: Bool?

    /// `log show --predicate 'subsystem == "local.daikin.app"' --last 5m` tells whether it connected.
    private static let log = Logger(subsystem: "local.daikin.app", category: "connection")

    init(device: DeviceConfig) {
        self.device = device
        do {
            client = try DaikinClient(host: device.host, keyBase64: device.key)
        } catch {
            client = nil
            errorMessage = error.localizedDescription
        }
    }

    /// One line for where there is no room for the full state.
    var statusText: String {
        if errorMessage != nil { return "Sem conexão" }
        guard let port else { return "Conectando…" }
        guard port.isOn else { return "Desligado" }
        return port.acMode?.label ?? "Ligado"
    }

    // MARK: - Polling

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.poll() else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        temperatureTask?.cancel()
        temperatureTask = nil
    }

    private func poll() async -> Duration {
        await refresh()
        return errorMessage == nil ? .seconds(10) : .seconds(4)
    }

    func refresh() async {
        guard let client else { return }
        await serialized { [self] in
            do {
                if capabilities == nil { capabilities = try? await client.deviceInfo() }
                let state = try await client.state()
                // A reply that was requested before a local edit would undo it on screen.
                if !hasLocalEdits { port = state.port1 }
                markReachable()
            } catch {
                markUnreachable(error)
            }
        }
    }

    // MARK: - What the current state allows

    var availableModes: [ACMode] {
        [.auto, .cool, .dry, .fan, .heat].filter { $0 != .heat || capabilities?.heat != 0 }
    }

    /// Nil when the setpoint is fixed: dry and fan modes, or while "potente" is on.
    var temperatureRange: ClosedRange<Double>? {
        guard let port, port.powerchill != 1 else { return nil }
        return port.acMode?.temperatureRange
    }

    var canChangeFan: Bool {
        port?.acMode != .dry && port?.powerchill != 1
    }

    var hasVerticalSwing: Bool {
        port?.vSwing != nil && capabilities?.verticalSwing != 0
    }

    // MARK: - Edits

    func setPower(_ on: Bool) {
        send(ACCommand(power: on)) { $0.power = on ? 1 : 0 }
    }

    func setMode(_ mode: ACMode) {
        send(ACCommand(mode: mode)) {
            $0.mode = mode.rawValue
            if mode == .dry { $0.fan = FanSpeed.auto.rawValue }
        }
    }

    func setFan(_ fan: FanSpeed) {
        send(ACCommand(fan: fan)) { $0.fan = fan.rawValue }
    }

    /// Vertical swing and comfort airflow exclude each other.
    func setSwing(_ on: Bool) {
        let clearsComfort = on && port?.coanda == 1
        send(ACCommand(verticalSwing: on, comfort: clearsComfort ? false : nil)) {
            $0.vSwing = on ? 1 : 0
            if clearsComfort { $0.coanda = 0 }
        }
    }

    func setComfort(_ on: Bool) {
        let clearsSwing = on && port?.vSwing == 1
        send(ACCommand(verticalSwing: clearsSwing ? false : nil, comfort: on)) {
            $0.coanda = on ? 1 : 0
            if clearsSwing { $0.vSwing = 0 }
        }
    }

    /// Econo and powerful exclude each other; the firmware clears the other one.
    func setEcono(_ on: Bool) {
        send(ACCommand(econo: on)) {
            $0.econo = on ? 1 : 0
            if on { $0.powerchill = 0 }
        }
    }

    func setPowerful(_ on: Bool) {
        send(ACCommand(powerful: on)) {
            $0.powerchill = on ? 1 : 0
            if on { $0.econo = 0 }
        }
    }

    /// Updates the display at once and sends after a pause, so repeated clicks become one command.
    func setTemperature(_ value: Double) {
        guard var draft = port, let range = temperatureRange else { return }
        let target = min(max(value, range.lowerBound), range.upperBound)
        guard target != draft.temperature else { return }
        draft.temperature = target
        port = draft

        temperatureTask?.cancel()
        temperatureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            temperatureTask = nil
            send(ACCommand(temperature: target)) { $0.temperature = target }
        }
    }

    func stepTemperature(by delta: Double) {
        guard let current = port?.temperature else { return }
        setTemperature(current + delta)
    }

    // MARK: - Plumbing

    private var hasLocalEdits: Bool {
        pendingEdits > 0 || temperatureTask != nil
    }

    private func send(_ command: ACCommand, optimistic: (inout UnitState) -> Void) {
        guard let client, var draft = port else { return }
        optimistic(&draft)
        port = draft
        pendingEdits += 1

        Task {
            let applied = await serialized { [self] in
                do {
                    let state = try await client.send(command)
                    pendingEdits -= 1
                    if !hasLocalEdits { port = state.port1 }
                    markReachable()
                    return true
                } catch {
                    pendingEdits -= 1
                    if case DaikinError.commandRejected = error {
                        show(notice: "O aparelho não aceitou o comando.")
                    } else {
                        markUnreachable(error)
                    }
                    return false
                }
            }
            // The optimistic value never reached the unit; show what it really has.
            if !applied { await refresh() }
        }
    }

    /// Runs `operation` after everything queued before it.
    @discardableResult
    private func serialized<Value: Sendable>(_ operation: @escaping @MainActor () async -> Value) async -> Value {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func markReachable() {
        if wasReachable != true {
            Self.log.notice("connected to \(self.device.host, privacy: .public)")
        }
        wasReachable = true
        errorMessage = nil
        lastUpdated = .now
    }

    private func markUnreachable(_ error: Error) {
        let message = error.localizedDescription
        if wasReachable != false {
            Self.log.error("cannot reach \(self.device.host, privacy: .public): \(message, privacy: .public)")
        }
        wasReachable = false
        errorMessage = message
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
