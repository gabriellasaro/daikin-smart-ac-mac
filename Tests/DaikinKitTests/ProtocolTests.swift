import Foundation
import Testing

@testable import DaikinKit

private func bytes(hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

@Suite struct CRC16Tests {
    @Test func matchesTheTableShippedInTheOfficialClient() {
        #expect(CRC16.table[1] == 4129)
        #expect(CRC16.table[16] == 4657)
        #expect(CRC16.table[255] == 7920)
    }

    @Test func genibusCheckValue() {
        #expect(CRC16.checksum(Array("123456789".utf8)) == 0xD64E)
    }
}

@Suite struct AESCFBTests {
    // NIST SP 800-38A, F.3.13 (CFB128-AES128.Encrypt), first two blocks.
    let key = bytes(hex: "2b7e151628aed2a6abf7158809cf4f3c")
    let iv = bytes(hex: "000102030405060708090a0b0c0d0e0f")
    let plaintext = bytes(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
    let ciphertext = bytes(hex: "3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b")

    @Test func nistVector() throws {
        #expect(try AESCFB.encrypt(plaintext, key: key, iv: iv) == ciphertext)
        #expect(try AESCFB.decrypt(ciphertext, key: key, iv: iv) == plaintext)
    }

    // Reference produced with `openssl enc -aes-128-cfb`; 40 bytes, so the last block is partial.
    @Test func partialFinalBlockMatchesOpenSSL() throws {
        let key = bytes(hex: "000102030405060708090a0b0c0d0e0f")
        let iv = bytes(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        let plaintext = Array(#"{"port1":{"power":1,"temperature":24}}BZ"#.utf8)
        let expected = bytes(
            hex: "253aa1918469395cfad81ca75bd0f4fda85cc60c1bf374cee54a174c5e4325c574b88cff27fafa4c")
        #expect(try AESCFB.encrypt(plaintext, key: key, iv: iv) == expected)
        #expect(try AESCFB.decrypt(expected, key: key, iv: iv) == plaintext)
    }

    @Test func rejectsBadKeyLength() {
        #expect(throws: DaikinError.self) {
            try AESCFB.encrypt([1, 2, 3], key: [1, 2, 3], iv: iv)
        }
    }
}

@Suite struct FrameTests {
    let key = bytes(hex: "000102030405060708090a0b0c0d0e0f")
    let iv = bytes(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")

    /// Builds a body the way the module does: IV | length byte | ciphertext | CRC16 LE.
    func deviceResponse(json: String, key: [UInt8]) throws -> String {
        let payload = Array(json.utf8)
        var frame = iv + [UInt8(payload.count & 0xFF)]
        frame += try AESCFB.encrypt(payload, key: key, iv: iv)
        let crc = CRC16.checksum(frame)
        frame += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return Data(frame).base64EncodedString()
    }

    @Test func requestIsIVThenCiphertextWithSuffixThenCRC() throws {
        let json = Data(#"{"port1":{"power":1,"temperature":24}}"#.utf8)
        let frame = Array(try #require(Data(base64Encoded: Frame.encodeRequest(json: json, key: key, iv: iv))))

        #expect(Array(frame.prefix(16)) == iv)
        let ciphertext = Array(frame[16..<(frame.count - 2)])
        #expect(ciphertext == bytes(
            hex: "253aa1918469395cfad81ca75bd0f4fda85cc60c1bf374cee54a174c5e4325c574b88cff27fafa4c"))
        let crc = UInt16(frame[frame.count - 2]) | UInt16(frame[frame.count - 1]) << 8
        #expect(crc == CRC16.checksum(frame.dropLast(2)))
    }

    @Test func requestUsesAFreshIVEachTime() throws {
        let json = Data("{}".utf8)
        #expect(try Frame.encodeRequest(json: json, key: key) != Frame.encodeRequest(json: json, key: key))
    }

    @Test func decodesResponse() throws {
        let json = #"{"port1":{"power":1,"mode":3,"temperature":25},"idu":1}"#
        let decoded = try Frame.decodeResponse(base64: deviceResponse(json: json, key: key), key: key)
        #expect(String(decoding: decoded, as: UTF8.self) == json)
    }

    @Test func wrongKeyIsReportedAsUndecodable() throws {
        let body = try deviceResponse(json: #"{"port1":{"power":1}}"#, key: key)
        let wrongKey = bytes(hex: "ffeeddccbbaa99887766554433221100")
        #expect(throws: DaikinError.undecodablePayload) {
            try Frame.decodeResponse(base64: body, key: wrongKey)
        }
    }

    @Test func corruptedFrameFailsChecksum() throws {
        var frame = Array(try #require(Data(base64Encoded: deviceResponse(json: "{}", key: key))))
        frame[20] ^= 0x01
        #expect(throws: DaikinError.checksumMismatch) {
            try Frame.decodeResponse(base64: Data(frame).base64EncodedString(), key: key)
        }
    }

    @Test func keyParsing() throws {
        #expect(try Frame.key(fromBase64: "AAECAwQFBgcICQoLDA0ODw==\n") == key)
        #expect(throws: DaikinError.self) { try Frame.key(fromBase64: "not base64!") }
        #expect(throws: DaikinError.self) { try Frame.key(fromBase64: "AAEC") }
    }
}

@Suite struct RawHTTPTests {
    // Header layout exactly as the module sends it, tabs included.
    let head = "HTTP/1.1 200 OK\r\n\t\tContent-Type: application/json\r\n\t\tContent-Length: 8\r\n\t\tConnection: Closed\r\n\r\n"

    @Test func parsesTabPrefixedHeaders() throws {
        let response = try RawHTTP.parse(Data((head + "QUJDREVG").utf8))
        #expect(response == RawHTTP.Response(status: 200, body: Data("QUJDREVG".utf8)))
    }

    @Test func completenessFollowsContentLength() {
        #expect(!RawHTTP.isComplete(Data("HTTP/1.1 200 OK\r\n".utf8)))
        #expect(!RawHTTP.isComplete(Data((head + "QUJD").utf8)))
        #expect(RawHTTP.isComplete(Data((head + "QUJDREVG").utf8)))
    }

    @Test func reportsStatusCode() throws {
        #expect(try RawHTTP.parse(Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)).status == 404)
    }

    @Test func rejectsGarbage() {
        #expect(throws: DaikinError.self) { try RawHTTP.parse(Data("hello".utf8)) }
    }
}

@Suite struct ModelTests {
    @Test func decodesStateReportedByTheUnit() throws {
        let json = """
            {"port1":{"power":1,"mode":3,"temperature":25,"fan":17,"h_swing":0,"v_swing":0,"coanda":1,\
            "econo":1,"powerchill":0,"good_sleep":0,"streamer":0,"out_quite":0,"on_timer_set":0,\
            "on_timer_value":0,"off_timer_set":0,"off_timer_value":0,\
            "sensors":{"room_temp":25,"out_temp":22},"rst_r":12,"fw_ver":"p1.0.3.28"},"idu":1}
            """
        let state = try JSONDecoder().decode(ACState.self, from: Data(json.utf8))
        #expect(state.port1.isOn)
        #expect(state.port1.acMode == .cool)
        #expect(state.port1.fanSpeed == .auto)
        #expect(state.port1.temperature == 25)
        #expect(state.port1.sensors?.outTemp == 22)
        #expect(state.port1.fwVer == "p1.0.3.28")
    }

    @Test func decodesDeviceCapabilities() throws {
        let json = #"{"apn":"DAIKIN:A1B2C3D4E5F6","eepid":"02B7","h_sw":0,"heat":0,"mic":"FFFF","v_bld":0,"v_sw":1}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        #expect(info == DeviceInfo(apn: "DAIKIN:A1B2C3D4E5F6", heat: 0, verticalSwing: 1, horizontalSwing: 0))
    }

    @Test func setpointRangeDependsOnMode() {
        #expect(ACMode.cool.temperatureRange == 18...32)
        #expect(ACMode.heat.temperatureRange == 10...30)
        #expect(ACMode.dry.temperatureRange == nil)
        #expect(ACMode.fan.temperatureRange == nil)
    }

    @Test func commandSendsOnlyWhatWasSet() throws {
        let command = ACCommand(power: true, temperature: 24)
        #expect(String(decoding: try command.jsonData(), as: UTF8.self) == #"{"port1":{"power":1,"temperature":24}}"#)
    }

    @Test func commandMapsFriendlyNamesToWireFields() throws {
        let command = ACCommand(mode: .cool, fan: .quiet, verticalSwing: true, comfort: false, econo: true, powerful: false)
        #expect(String(decoding: try command.jsonData(), as: UTF8.self)
            == #"{"port1":{"coanda":0,"econo":1,"fan":18,"mode":3,"powerchill":0,"v_swing":1}}"#)
    }

    @Test func dryModeForcesAutomaticFan() throws {
        let command = ACCommand(mode: .dry, fan: .high)
        #expect(String(decoding: try command.jsonData(), as: UTF8.self) == #"{"port1":{"fan":17,"mode":2}}"#)
    }

    @Test func emptyCommand() {
        #expect(ACCommand().isEmpty)
        #expect(!ACCommand(extra: ["streamer": 1]).isEmpty)
    }
}

@Suite struct DiscoveryTests {
    @Test func hostnameFromAPN() {
        #expect(Discovery.hostname(fromAPN: "DAIKIN:A1B2C3D4E5F6") == "DAIKINC3B2A1.local")
        #expect(Discovery.hostname(fromAPN: "DAIKIN:0A1B2C3D4E5F") == "DAIKIN2C1B0A.local")
        #expect(Discovery.hostname(fromAPN: "garbage") == nil)
    }
}

@Suite struct ConfigTests {
    @Test func savesWithOwnerOnlyPermissionsAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        var config = Config()
        config.upsert(DeviceConfig(name: "Quarto", host: "DAIKINC3B2A1.local", apn: "DAIKIN:A1B2C3D4E5F6", key: "a2V5"))
        try config.save(to: url)

        #expect(try Config.load(from: url) == config)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func missingFileLoadsAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        #expect(try Config.load(from: url).devices.isEmpty)
    }

    @Test func upsertReplacesBySameAPNOrName() {
        var config = Config()
        config.upsert(DeviceConfig(name: "Quarto", host: "a", apn: "X", key: "1"))
        config.upsert(DeviceConfig(name: "Suíte", host: "b", apn: "X", key: "2"))
        config.upsert(DeviceConfig(name: "Sala", host: "c", apn: "Y", key: "3"))
        config.upsert(DeviceConfig(name: "sala", host: "d", apn: nil, key: "4"))

        #expect(config.devices.map(\.name) == ["Suíte", "sala"])
        #expect(config.device(named: nil)?.host == "b")
        #expect(config.device(named: "SALA")?.host == "d")
    }
}
