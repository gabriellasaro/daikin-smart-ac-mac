import Foundation

/// Decrypted body of `GET /acstatus` (and of the reply to `POST /acstatus`).
public struct ACState: Codable, Sendable, Equatable {
    public var port1: UnitState
    public var idu: Int?
}

/// State of the indoor unit. Every field is optional because the set varies by model and firmware.
public struct UnitState: Codable, Sendable, Equatable {
    public var power: Int?
    public var mode: Int?
    public var temperature: Double?
    public var fan: Int?
    public var hSwing: Int?
    public var vSwing: Int?
    public var coanda: Int?
    public var econo: Int?
    public var powerchill: Int?
    public var goodSleep: Int?
    public var streamer: Int?
    public var outQuite: Int?
    public var onTimerSet: Int?
    public var onTimerValue: Int?
    public var offTimerSet: Int?
    public var offTimerValue: Int?
    public var sensors: Sensors?
    public var rstR: Int?
    public var fwVer: String?

    enum CodingKeys: String, CodingKey {
        case power, mode, temperature, fan, coanda, econo, powerchill, streamer, sensors
        case hSwing = "h_swing"
        case vSwing = "v_swing"
        case goodSleep = "good_sleep"
        case outQuite = "out_quite"
        case onTimerSet = "on_timer_set"
        case onTimerValue = "on_timer_value"
        case offTimerSet = "off_timer_set"
        case offTimerValue = "off_timer_value"
        case rstR = "rst_r"
        case fwVer = "fw_ver"
    }

    public var isOn: Bool { power == 1 }
    public var acMode: ACMode? { mode.flatMap(ACMode.init(rawValue:)) }
    public var fanSpeed: FanSpeed? { fan.flatMap(FanSpeed.init(rawValue:)) }
}

public struct Sensors: Codable, Sendable, Equatable {
    public var roomTemp: Double?
    public var outTemp: Double?

    enum CodingKeys: String, CodingKey {
        case roomTemp = "room_temp"
        case outTemp = "out_temp"
    }
}

/// Decrypted body of `GET /device`: what the unit is and what it can do.
public struct DeviceInfo: Codable, Sendable, Equatable {
    public var apn: String?
    /// 0 on cooling-only units.
    public var heat: Int?
    public var verticalSwing: Int?
    public var horizontalSwing: Int?

    enum CodingKeys: String, CodingKey {
        case apn, heat
        case verticalSwing = "v_sw"
        case horizontalSwing = "h_sw"
    }
}

public enum ACMode: Int, Sendable, CaseIterable {
    case auto = 1
    case dry = 2
    case cool = 3
    case heat = 4
    case fan = 6

    /// Setpoints the firmware accepts in this mode; nil where the setpoint cannot be changed.
    public var temperatureRange: ClosedRange<Double>? {
        switch self {
        case .cool: 18...32
        case .heat: 10...30
        case .auto: 18...30
        case .dry, .fan: nil
        }
    }

    public var label: String {
        switch self {
        case .auto: "Automático"
        case .dry: "Desumidificar"
        case .cool: "Resfriar"
        case .heat: "Aquecer"
        case .fan: "Ventilar"
        }
    }

    public var identifier: String {
        switch self {
        case .auto: "auto"
        case .dry: "dry"
        case .cool: "cool"
        case .heat: "heat"
        case .fan: "fan"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "auto", "automatico", "automático": self = .auto
        case "dry", "desumidificar", "seco": self = .dry
        case "cool", "resfriar", "frio": self = .cool
        case "heat", "aquecer", "quente": self = .heat
        case "fan", "ventilar", "ventilador": self = .fan
        default: return nil
        }
    }
}

public enum FanSpeed: Int, Sendable, CaseIterable {
    case low = 3
    case lowMedium = 4
    case medium = 5
    case mediumHigh = 6
    case high = 7
    case auto = 17
    case quiet = 18

    public var label: String {
        switch self {
        case .low: "Baixa"
        case .lowMedium: "Média-baixa"
        case .medium: "Média"
        case .mediumHigh: "Média-alta"
        case .high: "Alta"
        case .auto: "Automática"
        case .quiet: "Silenciosa"
        }
    }

    public var identifier: String {
        switch self {
        case .low: "low"
        case .lowMedium: "low-medium"
        case .medium: "medium"
        case .mediumHigh: "medium-high"
        case .high: "high"
        case .auto: "auto"
        case .quiet: "quiet"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "low", "baixa", "1": self = .low
        case "low-medium", "media-baixa", "média-baixa", "2": self = .lowMedium
        case "medium", "media", "média", "3": self = .medium
        case "medium-high", "media-alta", "média-alta", "4": self = .mediumHigh
        case "high", "alta", "5": self = .high
        case "auto", "automatica", "automática": self = .auto
        case "quiet", "silenciosa", "silencioso": self = .quiet
        default: return nil
        }
    }
}

/// A partial update: only the fields that are set are sent, the rest keep their current value.
public struct ACCommand: Sendable, Equatable {
    public static let temperatureRange: ClosedRange<Double> = 10...32

    public var power: Bool?
    public var mode: ACMode?
    public var temperature: Double?
    public var fan: FanSpeed?
    public var verticalSwing: Bool?
    /// "Conforto" in the app; `coanda` on the wire.
    public var comfort: Bool?
    public var econo: Bool?
    /// "Potente" in the app; `powerchill` on the wire.
    public var powerful: Bool?
    /// Extra raw `port1` fields, for features this type does not model.
    public var extra: [String: Int] = [:]

    public init(
        power: Bool? = nil, mode: ACMode? = nil, temperature: Double? = nil, fan: FanSpeed? = nil,
        verticalSwing: Bool? = nil, comfort: Bool? = nil, econo: Bool? = nil, powerful: Bool? = nil,
        extra: [String: Int] = [:]
    ) {
        self.power = power
        self.mode = mode
        self.temperature = temperature
        self.fan = fan
        self.verticalSwing = verticalSwing
        self.comfort = comfort
        self.econo = econo
        self.powerful = powerful
        self.extra = extra
    }

    public var isEmpty: Bool { fields.isEmpty }

    var fields: [String: Any] {
        var fields: [String: Any] = extra
        if let power { fields["power"] = power ? 1 : 0 }
        if let mode { fields["mode"] = mode.rawValue }
        if let temperature {
            // The firmware expects whole degrees as integers.
            fields["temperature"] = temperature == temperature.rounded() ? Int(temperature) : temperature
        }
        if let fan { fields["fan"] = fan.rawValue }
        if let verticalSwing { fields["v_swing"] = verticalSwing ? 1 : 0 }
        if let comfort { fields["coanda"] = comfort ? 1 : 0 }
        if let econo { fields["econo"] = econo ? 1 : 0 }
        if let powerful { fields["powerchill"] = powerful ? 1 : 0 }
        // Dry mode only runs with automatic fan; the official client forces it too.
        if mode == .dry { fields["fan"] = FanSpeed.auto.rawValue }
        return fields
    }

    /// The JSON the module expects: `{"port1":{...}}`.
    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["port1": fields], options: [.sortedKeys])
    }
}
