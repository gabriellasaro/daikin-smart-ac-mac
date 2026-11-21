import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `--name value`, `--name=value`, boolean `--flag` and positional arguments.
struct Arguments {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String], flags flagNames: Set<String> = []) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--"), argument.count > 2 else {
                positionals.append(argument)
                continue
            }
            let body = argument.dropFirst(2)
            if let equals = body.firstIndex(of: "=") {
                options[String(body[..<equals])] = String(body[body.index(after: equals)...])
            } else if flagNames.contains(String(body)) {
                flags.insert(String(body))
            } else if let value = iterator.next() {
                options[String(body)] = value
            } else {
                throw CLIError("faltou o valor de \(argument)")
            }
        }
    }

    mutating func option(_ name: String) -> String? {
        options.removeValue(forKey: name)
    }

    mutating func flag(_ name: String) -> Bool {
        flags.remove(name) != nil
    }

    mutating func positional() -> String? {
        positionals.isEmpty ? nil : positionals.removeFirst()
    }

    /// Call after consuming everything a command understands.
    func finish() throws {
        if let unknown = options.keys.sorted().first ?? flags.sorted().first {
            throw CLIError("opção desconhecida: --\(unknown)")
        }
        if let extra = positionals.first {
            throw CLIError("argumento inesperado: \(extra)")
        }
    }
}

func parseOnOff(_ value: String, option: String) throws -> Bool {
    switch value.lowercased() {
    case "on", "1", "true", "sim", "ligado", "ligar": return true
    case "off", "0", "false", "nao", "não", "desligado", "desligar": return false
    default: throw CLIError("--\(option) espera on ou off, veio \"\(value)\"")
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Reads a line without echoing it when stdin is a terminal; plain read otherwise (pipes).
func promptSecret(_ prompt: String) -> String? {
    guard isatty(STDIN_FILENO) != 0 else { return readLine(strippingNewline: true) }
    FileHandle.standardError.write(Data(prompt.utf8))
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var silent = original
    silent.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &silent)
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        FileHandle.standardError.write(Data("\n".utf8))
    }
    return readLine(strippingNewline: true)
}

func prompt(_ text: String) -> String? {
    FileHandle.standardError.write(Data(text.utf8))
    return readLine(strippingNewline: true)
}
