import CommonCrypto

/// AES in CFB mode with a 128-bit segment, used as a stream cipher (no padding).
/// Built on single-block ECB so the behaviour for a trailing partial block is explicit.
enum AESCFB {
    static let blockSize = kCCBlockSizeAES128

    static func encrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try process(plaintext, key: key, iv: iv, decrypting: false)
    }

    static func decrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try process(ciphertext, key: key, iv: iv, decrypting: true)
    }

    private static func process(_ input: [UInt8], key: [UInt8], iv: [UInt8], decrypting: Bool) throws -> [UInt8] {
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else {
            throw DaikinError.invalidKey("esperado 16, 24 ou 32 bytes, veio \(key.count)")
        }
        guard iv.count == blockSize else {
            throw DaikinError.invalidFrame("IV com \(iv.count) bytes")
        }

        var output = [UInt8](repeating: 0, count: input.count)
        var feedback = iv
        var offset = 0
        while offset < input.count {
            let keystream = try encryptBlock(feedback, key: key)
            let count = min(blockSize, input.count - offset)
            for index in 0..<count {
                output[offset + index] = input[offset + index] ^ keystream[index]
            }
            if count == blockSize {
                // The next keystream block is derived from this ciphertext block.
                let ciphertext = decrypting ? input : output
                feedback = Array(ciphertext[offset..<offset + blockSize])
            }
            offset += count
        }
        return output
    }

    private static func encryptBlock(_ block: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: blockSize)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, key.count, nil,
            block, block.count,
            &output, output.count, &moved
        )
        guard status == kCCSuccess, moved == blockSize else {
            throw DaikinError.invalidKey("CommonCrypto falhou (\(status))")
        }
        return output
    }
}
