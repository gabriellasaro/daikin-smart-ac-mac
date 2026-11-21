import DaikinKit
import Foundation

@main
struct DaikinCLI {
    static let usage = """
        daikin — controle local do ar-condicionado Daikin Smart AC

        USO
          daikin discover [--timeout 4]         procura aparelhos na rede local
          daikin setup [--host H] [--name N]    salva um aparelho (pede a Device Key)
          daikin status [--json]                mostra o estado atual
          daikin on | off                       liga / desliga
          daikin set [opções]                   altera um ou mais ajustes
          daikin get <acstatus|device|status>   mostra o JSON decifrado de um endpoint
          daikin send '<json>'                  envia campos crus de port1, ex.: '{"streamer":1}'

        OPÇÕES DE set
          --power on|off
          --temp 24
          --mode auto|cool|heat|dry|fan
          --fan auto|quiet|low|low-medium|medium|medium-high|high
          --swing on|off        oscilação vertical
          --comfort on|off      modo conforto (coanda)
          --econo on|off        modo econômico
          --powerful on|off     modo potente

        OPÇÕES GERAIS
          --device NOME         aparelho salvo a usar (padrão: o primeiro)
          --host H --key K      usa um aparelho sem salvar (a chave também pode vir de DAIKIN_KEY)

        A Device Key aparece no app do celular em Menu → Integrações → Home Assistant.
        """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            printError("erro: \(error.description)")
            exit(2)
        } catch {
            printError("erro: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(_ raw: [String]) async throws {
        var arguments = try Arguments(raw, flags: ["json", "help"])
        guard !arguments.flag("help"), let command = arguments.positional(), command != "help" else {
            print(usage)
            return
        }

        switch command {
        case "discover": try await discover(&arguments)
        case "setup": try await setup(&arguments)
        case "status": try await status(&arguments)
        case "on": try await apply(ACCommand(power: true), &arguments)
        case "off": try await apply(ACCommand(power: false), &arguments)
        case "set": try await apply(try parseCommand(&arguments), &arguments)
        case "get": try await get(&arguments)
        case "send": try await sendRaw(&arguments)
        default: throw CLIError("comando desconhecido: \(command) (veja `daikin help`)")
        }
    }

    // MARK: - Commands

    static func discover(_ arguments: inout Arguments) async throws {
        let timeout = try arguments.option("timeout").map(parseSeconds) ?? 4
        try arguments.finish()

        let devices = await Discovery.browse(for: timeout)
        guard !devices.isEmpty else {
            print("Nenhum aparelho encontrado. O Mac está na mesma rede Wi-Fi do ar-condicionado?")
            return
        }
        for device in devices {
            let host = device.hostname ?? "?"
            let address = device.hostname.flatMap(Discovery.resolveIPv4) ?? "?"
            print("\(device.name)  host=\(host)  ip=\(address)  apn=\(device.apn ?? "?")")
        }
    }

    static func setup(_ arguments: inout Arguments) async throws {
        var host = arguments.option("host")
        let requestedName = arguments.option("name")
        let providedKey = arguments.option("key") ?? ProcessInfo.processInfo.environment["DAIKIN_KEY"]
        try arguments.finish()

        var apn: String?
        if host == nil {
            print("Procurando aparelhos na rede…")
            let found = await Discovery.browse().filter { $0.hostname != nil }
            let chosen: DiscoveredDevice
            switch found.count {
            case 0:
                throw CLIError("nenhum aparelho encontrado; informe o endereço com --host")
            case 1:
                chosen = found[0]
            default:
                for (index, device) in found.enumerated() {
                    print("  \(index + 1)) \(device.hostname ?? "?")  apn=\(device.apn ?? "?")")
                }
                guard let answer = prompt("Qual aparelho? [1-\(found.count)] "),
                      let index = Int(answer), found.indices.contains(index - 1)
                else { throw CLIError("escolha inválida") }
                chosen = found[index - 1]
            }
            host = chosen.hostname
            apn = chosen.apn
            print("Encontrado: \(chosen.hostname ?? "?")")
        }
        guard let host else { throw CLIError("informe o endereço com --host") }

        guard let key = (providedKey ?? promptSecret("Device Key (não aparece ao digitar): "))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { throw CLIError("Device Key vazia") }

        let client = try DaikinClient(host: host, keyBase64: key)
        let state = try await client.state()

        var config = try Config.load()
        let name = requestedName
            ?? config.devices.first { $0.apn != nil && $0.apn == apn }?.name
            ?? (config.devices.isEmpty ? "Ar-condicionado" : "Ar-condicionado \(config.devices.count + 1)")
        config.upsert(DeviceConfig(name: name, host: host, apn: apn, key: key))
        try config.save()

        print("Chave válida. \"\(name)\" salvo em \(Config.defaultURL.path)\n")
        printState(state, title: "\(name) — \(host)")
    }

    static func status(_ arguments: inout Arguments) async throws {
        let json = arguments.flag("json")
        let (client, title) = try resolveClient(&arguments)
        try arguments.finish()

        if json {
            print(try prettyJSON(await client.get("acstatus")))
        } else {
            printState(try await client.state(), title: title)
        }
    }

    static func apply(_ command: ACCommand, _ arguments: inout Arguments) async throws {
        let (client, title) = try resolveClient(&arguments)
        try arguments.finish()
        guard !command.isEmpty else { throw CLIError("nada a alterar; veja `daikin help`") }
        printState(try await client.send(command), title: title)
    }

    static func get(_ arguments: inout Arguments) async throws {
        guard let endpoint = arguments.positional() else {
            throw CLIError("informe o endpoint: acstatus, device ou status")
        }
        let (client, _) = try resolveClient(&arguments)
        try arguments.finish()
        print(try prettyJSON(await client.get(endpoint)))
    }

    static func sendRaw(_ arguments: inout Arguments) async throws {
        guard let text = arguments.positional() else {
            throw CLIError("informe o JSON, ex.: daikin send '{\"streamer\":1}'")
        }
        guard let fields = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Int] else {
            throw CLIError("o JSON deve ser um objeto de campos inteiros, ex.: '{\"streamer\":1}'")
        }
        try await apply(ACCommand(extra: fields), &arguments)
    }

    // MARK: - Helpers

    static func parseCommand(_ arguments: inout Arguments) throws -> ACCommand {
        var command = ACCommand()
        if let value = arguments.option("power") { command.power = try parseOnOff(value, option: "power") }
        if let value = arguments.option("temp") {
            guard let temperature = Double(value.replacingOccurrences(of: ",", with: ".")),
                  ACCommand.temperatureRange.contains(temperature)
            else { throw CLIError("--temp espera um valor entre 10 e 32, veio \"\(value)\"") }
            command.temperature = temperature
        }
        if let value = arguments.option("mode") {
            guard let mode = ACMode(name: value) else {
                throw CLIError("--mode espera \(ACMode.allCases.map(\.identifier).joined(separator: "|"))")
            }
            command.mode = mode
        }
        if let value = arguments.option("fan") {
            guard let fan = FanSpeed(name: value) else {
                throw CLIError("--fan espera \(FanSpeed.allCases.map(\.identifier).joined(separator: "|"))")
            }
            command.fan = fan
        }
        if let value = arguments.option("swing") { command.verticalSwing = try parseOnOff(value, option: "swing") }
        if let value = arguments.option("comfort") { command.comfort = try parseOnOff(value, option: "comfort") }
        if let value = arguments.option("econo") { command.econo = try parseOnOff(value, option: "econo") }
        if let value = arguments.option("powerful") { command.powerful = try parseOnOff(value, option: "powerful") }
        return command
    }

    /// `--host` + key for a one-off device, otherwise a saved one (`--device`, or the first).
    static func resolveClient(_ arguments: inout Arguments) throws -> (DaikinClient, title: String) {
        let deviceName = arguments.option("device")
        let host = arguments.option("host")
        let key = arguments.option("key") ?? ProcessInfo.processInfo.environment["DAIKIN_KEY"]

        if let host {
            guard let key else { throw CLIError("--host precisa de --key ou da variável DAIKIN_KEY") }
            return (try DaikinClient(host: host, keyBase64: key), host)
        }
        let config = try Config.load()
        guard let device = config.device(named: deviceName) else {
            throw CLIError(deviceName.map { "aparelho \"\($0)\" não encontrado" }
                ?? "nenhum aparelho salvo; rode `daikin setup` primeiro")
        }
        return (try DaikinClient(host: device.host, keyBase64: device.key), "\(device.name) — \(device.host)")
    }

    static func parseSeconds(_ value: String) throws -> TimeInterval {
        guard let seconds = TimeInterval(value), seconds > 0, seconds <= 60 else {
            throw CLIError("--timeout espera segundos entre 1 e 60")
        }
        return seconds
    }

    static func prettyJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: pretty, as: UTF8.self)
    }

    static func printState(_ state: ACState, title: String) {
        let port = state.port1
        func degrees(_ value: Double?) -> String {
            guard let value else { return "?" }
            return value == value.rounded() ? "\(Int(value)) °C" : "\(value) °C"
        }
        func toggle(_ value: Int?) -> String? {
            value.map { $0 == 1 ? "ligado" : "desligado" }
        }

        var rows: [(String, String)] = [
            ("Estado", port.power.map { $0 == 1 ? "Ligado" : "Desligado" } ?? "?"),
            ("Modo", port.acMode?.label ?? port.mode.map { "desconhecido (\($0))" } ?? "?"),
            ("Temperatura", degrees(port.temperature)),
            ("Ventilação", port.fanSpeed?.label ?? port.fan.map { "desconhecida (\($0))" } ?? "?"),
        ]
        if let sensors = port.sensors {
            rows.append(("Ambiente", degrees(sensors.roomTemp)))
            rows.append(("Externa", degrees(sensors.outTemp)))
        }
        let toggles: [(String, Int?)] = [
            ("Oscilação", port.vSwing), ("Conforto", port.coanda),
            ("Econômico", port.econo), ("Potente", port.powerchill),
        ]
        for (label, value) in toggles {
            if let text = toggle(value) { rows.append((label, text)) }
        }
        if let firmware = port.fwVer { rows.append(("Firmware", firmware)) }

        print(title)
        for (label, value) in rows {
            print("  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value)")
        }
    }
}
