import Foundation
import Network

public struct DiscoveredDevice: Sendable, Hashable {
    /// Bonjour instance name, normally "Daikin Smart AC".
    public var name: String
    /// Module identifier from the TXT record, e.g. "DAIKIN:A1B2C3D4E5F6".
    public var apn: String?
    /// mDNS hostname derived from the APN, e.g. "DAIKINC3B2A1.local".
    public var hostname: String?
}

public enum Discovery {
    public static let serviceType = "_iota._tcp"

    /// Browses Bonjour for `duration` seconds and returns every unit seen.
    ///
    /// The service advertises port 80, which is closed; the API lives on port 15914,
    /// so only the host is taken from discovery.
    public static func browse(for duration: TimeInterval = 4) async -> [DiscoveredDevice] {
        await Browse().run(for: duration)
    }

    /// "DAIKIN:A1B2C3D4E5F6" → "DAIKINC3B2A1.local": the prefix plus the first three bytes reversed.
    public static func hostname(fromAPN apn: String) -> String? {
        let parts = apn.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[1].count >= 6 else { return nil }
        let hex = Array(parts[1].prefix(6))
        let reversed = String(hex[4...5] + hex[2...3] + hex[0...1])
        return "\(parts[0])\(reversed).local"
    }

    /// Blocking lookup, mainly for display; connections resolve `.local` names on their own.
    public static func resolveIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private final class Browse: @unchecked Sendable {
    private let queue = DispatchQueue(label: "daikin.discovery")
    private let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: Discovery.serviceType, domain: "local."), using: NWParameters())

    func run(for duration: TimeInterval) async -> [DiscoveredDevice] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                browser.start(queue: queue)
                queue.asyncAfter(deadline: .now() + duration) { [self] in
                    var seen = Set<DiscoveredDevice>()
                    let devices = browser.browseResults
                        .compactMap(Self.device(from:))
                        .filter { seen.insert($0).inserted }
                        .sorted { ($0.hostname ?? $0.name) < ($1.hostname ?? $1.name) }
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }

    private static func device(from result: NWBrowser.Result) -> DiscoveredDevice? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var apn: String?
        if case .bonjour(let record) = result.metadata { apn = record["apn"] }
        return DiscoveredDevice(name: name, apn: apn, hostname: apn.flatMap(Discovery.hostname(fromAPN:)))
    }
}
