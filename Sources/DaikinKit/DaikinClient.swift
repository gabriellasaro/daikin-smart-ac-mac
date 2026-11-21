import Foundation

/// Talks to one air conditioner over the local network.
public struct DaikinClient: Sendable {
    public static let defaultPort: UInt16 = 15914

    public let host: String
    public let port: UInt16
    public var timeout: TimeInterval = 10
    private let key: [UInt8]

    /// - Parameter keyBase64: the Device Key shown by the app under Menu → Integrações → Home Assistant.
    public init(host: String, port: UInt16 = DaikinClient.defaultPort, keyBase64: String) throws {
        self.host = host
        self.port = port
        self.key = try Frame.key(fromBase64: keyBase64)
    }

    /// Decrypted JSON of a read endpoint: `acstatus`, `device` or `status`.
    public func get(_ endpoint: String) async throws -> Data {
        let response = try await RawHTTP.send(
            host: host, port: port, method: "GET", path: "/\(endpoint)", timeout: timeout)
        return try decode(response)
    }

    public func state() async throws -> ACState {
        try JSONDecoder().decode(ACState.self, from: await get("acstatus"))
    }

    public func deviceInfo() async throws -> DeviceInfo {
        try JSONDecoder().decode(DeviceInfo.self, from: await get("device"))
    }

    /// Applies a partial update and returns the state the unit reports back.
    @discardableResult
    public func send(_ command: ACCommand) async throws -> ACState {
        let body = try Frame.encodeRequest(json: command.jsonData(), key: key)
        let response = try await RawHTTP.send(
            host: host, port: port, method: "POST", path: "/acstatus", body: Data(body.utf8), timeout: timeout)
        guard let state = try? JSONDecoder().decode(ACState.self, from: decode(response)),
              state.port1.power != nil
        else {
            throw DaikinError.commandRejected
        }
        return state
    }

    private func decode(_ response: RawHTTP.Response) throws -> Data {
        guard response.status == 200 else { throw DaikinError.http(status: response.status) }
        return try Frame.decodeResponse(base64: String(decoding: response.body, as: UTF8.self), key: key)
    }
}
