import DaikinKit
import SwiftUI

extension ACMode {
    var tint: Color {
        switch self {
        case .auto: .indigo
        case .cool: .blue
        case .dry: .teal
        case .fan: .green
        case .heat: .orange
        }
    }

    var symbol: String {
        switch self {
        case .auto: "arrow.triangle.2.circlepath"
        case .cool: "snowflake"
        case .dry: "drop.fill"
        case .fan: "fan.fill"
        case .heat: "sun.max.fill"
        }
    }

    /// Fits under an icon; `label` is the full name.
    var shortLabel: String {
        switch self {
        case .auto: "Auto"
        case .cool: "Resfriar"
        case .dry: "Secar"
        case .fan: "Ventilar"
        case .heat: "Aquecer"
        }
    }
}

extension FanSpeed {
    /// 1...5 for the fixed speeds, nil for automatic and quiet.
    var level: Int? {
        switch self {
        case .low: 1
        case .lowMedium: 2
        case .medium: 3
        case .mediumHigh: 4
        case .high: 5
        case .auto, .quiet: nil
        }
    }

    init?(level: Int) {
        switch level {
        case 1: self = .low
        case 2: self = .lowMedium
        case 3: self = .medium
        case 4: self = .mediumHigh
        case 5: self = .high
        default: return nil
        }
    }
}

extension EnvironmentValues {
    /// True inside the menu bar panel, where the same controls are laid out tighter.
    @Entry var isCompact = false
}

extension ShapeStyle where Self == AnyShapeStyle {
    /// Resting background of the custom controls.
    static var controlFill: AnyShapeStyle { AnyShapeStyle(.quaternary.opacity(0.7)) }
}

func formatDegrees(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.number.precision(.fractionLength(0...1)))
}
