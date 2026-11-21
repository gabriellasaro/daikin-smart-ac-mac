import DaikinKit
import SwiftUI

/// Everything about one unit: a loading or unreachable placeholder until the first state arrives.
struct ControlView: View {
    let controller: ACController
    @Environment(\.isCompact) private var isCompact

    private var placeholderHeight: CGFloat { isCompact ? 220 : 380 }

    var body: some View {
        if let port = controller.port {
            ControlPanel(controller: controller, port: port)
        } else if let message = controller.errorMessage {
            ContentUnavailableView {
                Label("Sem conexão", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Não foi possível falar com \(controller.device.host). Confira se o Mac está na mesma rede do ar-condicionado e se o app tem acesso à Rede Local em Ajustes do Sistema → Privacidade e Segurança.")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } actions: {
                Button("Tentar de novo") {
                    Task { await controller.refresh() }
                }
            }
            .padding()
            .frame(minHeight: placeholderHeight)
        } else {
            ProgressView("Conectando…")
                .frame(maxWidth: .infinity, minHeight: placeholderHeight)
        }
    }
}

private struct ControlPanel: View {
    let controller: ACController
    let port: UnitState
    @Environment(\.isCompact) private var isCompact

    private var tint: Color {
        port.isOn ? (port.acMode?.tint ?? .accentColor) : .secondary
    }

    var body: some View {
        VStack(spacing: isCompact ? 14 : 22) {
            if controller.errorMessage != nil {
                Banner(text: "Sem conexão com o aparelho. Tentando de novo…", symbol: "wifi.exclamationmark")
            } else if let notice = controller.notice {
                Banner(text: notice, symbol: "exclamationmark.triangle.fill")
            }

            TemperatureControl(controller: controller, port: port)
            PowerButton(controller: controller, isOn: port.isOn, tint: tint)

            VStack(spacing: isCompact ? 14 : 20) {
                ModePicker(controller: controller, selection: port.acMode)
                FanPicker(controller: controller, selection: port.fanSpeed, tint: tint)
                OptionList(controller: controller, port: port, tint: tint)
            }
            .disabled(!port.isOn)
            .opacity(port.isOn ? 1 : 0.4)

            if !isCompact {
                Footer(firmware: port.fwVer, lastUpdated: controller.lastUpdated)
            }
        }
        .padding(isCompact ? 16 : 20)
        .disabled(controller.errorMessage != nil)
        .animation(.snappy(duration: 0.25), value: port)
        .animation(.snappy(duration: 0.25), value: controller.errorMessage)
        .animation(.snappy(duration: 0.25), value: controller.notice)
    }
}

// MARK: - Temperature

private struct TemperatureControl: View {
    let controller: ACController
    let port: UnitState
    @Environment(\.isCompact) private var isCompact

    private var range: ClosedRange<Double>? {
        port.isOn ? controller.temperatureRange : nil
    }

    private var caption: String {
        var parts: [String] = []
        if let room = port.sensors?.roomTemp { parts.append("Ambiente \(formatDegrees(room)) °C") }
        if let outside = port.sensors?.outTemp { parts.append("Externa \(formatDegrees(outside)) °C") }
        return parts.joined(separator: "  ·  ")
    }

    /// Why the setpoint cannot be changed right now, if the unit is on and it is fixed.
    private var lockReason: String? {
        guard port.isOn, range == nil else { return nil }
        if port.powerchill == 1 { return "Temperatura fixa no modo Potente" }
        if let mode = port.acMode { return "Temperatura fixa no modo \(mode.label)" }
        return nil
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                StepButton(symbol: "minus", label: "Diminuir temperatura", isEnabled: canStep(to: -1)) {
                    controller.stepTemperature(by: -1)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(formatDegrees(port.temperature))
                        .font(.system(size: isCompact ? 56 : 84, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("°C")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(port.isOn && range != nil ? .primary : .secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Temperatura ajustada")
                .accessibilityValue("\(formatDegrees(port.temperature)) graus")
                Spacer(minLength: 0)
                StepButton(symbol: "plus", label: "Aumentar temperatura", isEnabled: canStep(to: 1)) {
                    controller.stepTemperature(by: 1)
                }
            }

            if !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let lockReason {
                Text(lockReason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func canStep(to delta: Double) -> Bool {
        guard let range, let current = port.temperature else { return false }
        return range.contains(current + delta)
    }
}

private struct StepButton: View {
    let symbol: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.isCompact) private var isCompact

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font((isCompact ? Font.title3 : .title2).weight(.medium))
                .frame(width: isCompact ? 38 : 48, height: isCompact ? 38 : 48)
                .background(.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Power

private struct PowerButton: View {
    let controller: ACController
    let isOn: Bool
    let tint: Color

    var body: some View {
        Button {
            controller.setPower(!isOn)
        } label: {
            Label(isOn ? "Ligado" : "Desligado", systemImage: "power")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? AnyShapeStyle(tint) : .controlFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Desligar o ar-condicionado" : "Ligar o ar-condicionado")
        .accessibilityLabel("Ar-condicionado")
        .accessibilityValue(isOn ? "Ligado" : "Desligado")
    }
}

// MARK: - Mode

private struct ModePicker: View {
    let controller: ACController
    let selection: ACMode?

    var body: some View {
        Section(title: "Modo") {
            HStack(spacing: 8) {
                ForEach(controller.availableModes, id: \.self) { mode in
                    let isSelected = mode == selection
                    Button {
                        controller.setMode(mode)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .frame(height: 20)
                            Text(mode.shortLabel)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            isSelected ? AnyShapeStyle(mode.tint) : .controlFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(mode.label)
                    .accessibilityLabel(mode.label)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Fan

private struct FanPicker: View {
    let controller: ACController
    let selection: FanSpeed?
    let tint: Color

    private static let barHeights: [CGFloat] = [12, 18, 24, 30, 36]

    var body: some View {
        Section(title: "Ventilação") {
            HStack(spacing: 8) {
                chip(.auto, title: "Auto")
                chip(.quiet, title: "Silenciosa")
                Spacer(minLength: 12)
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(1...5, id: \.self) { level in
                        bar(level)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Velocidade")
            }
        }
        .disabled(!controller.canChangeFan)
        .opacity(controller.canChangeFan ? 1 : 0.4)
    }

    private func chip(_ speed: FanSpeed, title: String) -> some View {
        let isSelected = selection == speed
        return Button {
            controller.setFan(speed)
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? AnyShapeStyle(tint) : .controlFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ventilação \(speed.label.lowercased())")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func bar(_ level: Int) -> some View {
        let isFilled = (selection?.level ?? 0) >= level
        return Button {
            if let speed = FanSpeed(level: level) { controller.setFan(speed) }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isFilled ? AnyShapeStyle(tint) : .controlFill)
                .frame(width: 16, height: Self.barHeights[level - 1])
                // The whole column is clickable, not just the short bar.
                .frame(height: Self.barHeights[4], alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(FanSpeed(level: level)?.label ?? "")
        .accessibilityLabel("Velocidade \(level) de 5")
        .accessibilityAddTraits(selection?.level == level ? .isSelected : [])
    }
}

// MARK: - Options

private struct OptionList: View {
    let controller: ACController
    let port: UnitState
    let tint: Color

    private struct Option: Identifiable, Sendable {
        let id: String
        let symbol: String
        let isOn: Bool
        let set: @MainActor (Bool) -> Void
    }

    /// Only what this unit reports; the set varies by model.
    private var options: [Option] {
        var options: [Option] = []
        if controller.hasVerticalSwing, let value = port.vSwing {
            options.append(Option(id: "Oscilação", symbol: "arrow.up.and.down", isOn: value == 1, set: controller.setSwing))
        }
        if let value = port.coanda {
            options.append(Option(id: "Conforto", symbol: "wind", isOn: value == 1, set: controller.setComfort))
        }
        if let value = port.econo {
            options.append(Option(id: "Econômico", symbol: "leaf.fill", isOn: value == 1, set: controller.setEcono))
        }
        if let value = port.powerchill {
            options.append(Option(id: "Potente", symbol: "bolt.fill", isOn: value == 1, set: controller.setPowerful))
        }
        return options
    }

    var body: some View {
        let options = options
        if !options.isEmpty {
            VStack(spacing: 0) {
                ForEach(options) { option in
                    Toggle(isOn: Binding(get: { option.isOn }, set: { option.set($0) })) {
                        HStack(spacing: 10) {
                            Image(systemName: option.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(option.id)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .tint(tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    if option.id != options.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Pieces

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct Banner: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.yellow.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
    }
}

private struct Footer: View {
    let firmware: String?
    let lastUpdated: Date?

    var body: some View {
        let parts = [
            firmware.map { "Firmware \($0)" },
            lastUpdated.map { "Atualizado às \($0.formatted(date: .omitted, time: .shortened))" },
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
