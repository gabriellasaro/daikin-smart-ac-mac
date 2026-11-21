import Foundation

/// Wire format of the HTTP bodies exchanged with the module. Every body is Base64 of:
///
///     request:   IV (16) | AES-CFB(json + "BZ")          | CRC16 (2, little-endian)
///     response:  IV (16) | length & 0xFF (1) | AES-CFB(json) | CRC16 (2, little-endian)
///
/// The CRC covers everything before it. The response carries one extra byte holding the
/// low 8 bits of the payload length; requests do not.
public enum Frame {
    static let commandSuffix = Array("BZ".utf8)
    static let ivSize = 16
    static let crcSize = 2

    public static func key(fromBase64 string: String) throws -> [UInt8] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw DaikinError.invalidKey("não é Base64")
        }
        guard [16, 24, 32].contains(data.count) else {
            throw DaikinError.invalidKey("esperado 16, 24 ou 32 bytes, veio \(data.count)")
        }
        return Array(data)
    }

    public static func encodeRequest(json: Data, key: [UInt8], iv: [UInt8]? = nil) throws -> String {
        let iv = iv ?? (0..<ivSize).map { _ in UInt8.random(in: .min ... .max) }
        var frame = iv
        frame += try AESCFB.encrypt(Array(json) + commandSuffix, key: key, iv: iv)
        let crc = CRC16.checksum(frame)
        frame += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return Data(frame).base64EncodedString()
    }

    /// Returns the decrypted JSON payload.
    public static func decodeResponse(base64: String, key: [UInt8]) throws -> Data {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw DaikinError.invalidFrame("corpo não é Base64")
        }
        let frame = Array(data)
        guard frame.count > ivSize + 1 + crcSize else {
            throw DaikinError.invalidFrame("apenas \(frame.count) bytes")
        }

        let crcOffset = frame.count - crcSize
        let received = UInt16(frame[crcOffset]) | UInt16(frame[crcOffset + 1]) << 8
        guard CRC16.checksum(frame[..<crcOffset]) == received else {
            throw DaikinError.checksumMismatch
        }

        let iv = Array(frame[..<ivSize])
        let ciphertext = Array(frame[(ivSize + 1)..<crcOffset])
        var plaintext = try AESCFB.decrypt(ciphertext, key: key, iv: iv)
        while let last = plaintext.last, last == 0 || last == 0x20 || last == 0x0A || last == 0x0D {
            plaintext.removeLast()
        }

        // CFB has no integrity check of its own: a wrong key still "decrypts", to garbage.
        guard plaintext.first == UInt8(ascii: "{"),
              (try? JSONSerialization.jsonObject(with: Data(plaintext))) != nil
        else {
            throw DaikinError.undecodablePayload
        }
        return Data(plaintext)
    }
}
