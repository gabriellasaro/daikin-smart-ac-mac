import Foundation
import Network

/// Minimal HTTP/1.1 exchange over a raw TCP socket.
///
/// The module's HTTP server is not spec-compliant — header lines are prefixed with tabs:
///
///     HTTP/1.1 200 OK\r\n\t\tContent-Type: application/json\r\n\t\tContent-Length: 452\r\n...
///
/// URLSession rejects that, so responses are read and parsed by hand.
enum RawHTTP {
    struct Response: Equatable {
        var status: Int
        var body: Data
    }

    static func send(
        host: String, port: UInt16, method: String, path: String, body: Data? = nil, timeout: TimeInterval = 10
    ) async throws -> Response {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }

        let raw = try await Exchange(host: host, port: port, request: request, timeout: timeout).run()
        return try parse(raw)
    }

    private static let separator = Data("\r\n\r\n".utf8)

    static func parse(_ raw: Data) throws -> Response {
        guard let split = raw.range(of: separator) else {
            throw DaikinError.malformedResponse("sem separador de cabeçalho")
        }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let statusLine = head.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let status = Int(statusLine[1]) else {
            throw DaikinError.malformedResponse("linha de status inválida")
        }
        var body = Data(raw[split.upperBound...])
        if let length = contentLength(in: head), body.count > length {
            body = body.prefix(length)
        }
        return Response(status: status, body: body)
    }

    /// True once the header block and the announced body length have fully arrived.
    static func isComplete(_ raw: Data) -> Bool {
        guard let split = raw.range(of: separator) else { return false }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        guard let length = contentLength(in: head) else { return false }
        return raw.count - split.upperBound >= length
    }

    private static func contentLength(in head: String) -> Int? {
        guard let match = head.firstMatch(of: /(?i)content-length:\s*(\d+)/) else { return nil }
        return Int(match.1)
    }
}

/// One request/response round trip. All mutable state is confined to `queue`.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "daikin.http")
    private let request: Data
    private let timeout: TimeInterval
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    init(host: String, port: UInt16, request: Data, timeout: TimeInterval) {
        self.connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 15914, using: .tcp)
        self.request = request
        self.timeout = timeout
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>) {
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { finish(.failure(DaikinError.connection(error.localizedDescription))) }
                })
                receive()
            case .failed(let error), .waiting(let error):
                // `.waiting` covers refused/unreachable; for a one-shot CLI call, fail instead of retrying.
                finish(.failure(DaikinError.connection(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(DaikinError.timeout))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if isComplete || RawHTTP.isComplete(buffer) {
                finish(.success(buffer))
            } else if let error {
                finish(.failure(DaikinError.connection(error.localizedDescription)))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
