import Foundation

public struct DeviceConfig: Codable, Sendable, Equatable {
    public var name: String
    public var host: String
    public var apn: String?
    /// Device Key, Base64.
    public var key: String

    public init(name: String, host: String, apn: String? = nil, key: String) {
        self.name = name
        self.host = host
        self.apn = apn
        self.key = key
    }
}

/// Saved devices. The file holds the Device Keys, so it is written with owner-only permissions.
public struct Config: Codable, Sendable, Equatable {
    public var devices: [DeviceConfig] = []

    public init(devices: [DeviceConfig] = []) {
        self.devices = devices
    }

    /// `~/.config/daikin/config.json`, or the file named by the `DAIKIN_CONFIG` environment variable.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["DAIKIN_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/daikin/config.json")
    }

    /// Returns an empty config when the file does not exist yet.
    public static func load(from url: URL = defaultURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = defaultURL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try data.write(to: url)
    }

    /// The device with that name (case-insensitive), or the first one when `name` is nil.
    public func device(named name: String?) -> DeviceConfig? {
        guard let name else { return devices.first }
        return devices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Replaces the device with the same name or APN, otherwise appends.
    public mutating func upsert(_ device: DeviceConfig) {
        let index = devices.firstIndex {
            $0.name.caseInsensitiveCompare(device.name) == .orderedSame
                || ($0.apn != nil && $0.apn == device.apn)
        }
        if let index {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }
}
