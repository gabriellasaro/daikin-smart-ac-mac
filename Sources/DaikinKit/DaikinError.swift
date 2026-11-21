import Foundation

public enum DaikinError: Error, LocalizedError, Equatable {
    case invalidKey(String)
    case invalidFrame(String)
    case checksumMismatch
    /// The payload decrypted to something that is not JSON — almost always a wrong Device Key.
    case undecodablePayload
    case http(status: Int)
    case malformedResponse(String)
    case connection(String)
    case timeout
    case commandRejected

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let why): "Device Key inválida: \(why)"
        case .invalidFrame(let why): "Resposta do aparelho em formato inesperado: \(why)"
        case .checksumMismatch: "CRC da resposta não confere"
        case .undecodablePayload: "Não foi possível decifrar a resposta — a Device Key provavelmente está errada"
        case .http(let status): "O aparelho respondeu HTTP \(status)"
        case .malformedResponse(let why): "Resposta HTTP malformada: \(why)"
        case .connection(let why): "Falha de conexão: \(why)"
        case .timeout: "Tempo esgotado ao falar com o aparelho"
        case .commandRejected: "O aparelho não aceitou o comando"
        }
    }
}
