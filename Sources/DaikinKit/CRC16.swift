/// CRC-16/GENIBUS (poly 0x1021, init 0xFFFF, no reflection, xorout 0xFFFF).
/// This is the checksum the Daikin module appends, little-endian, to every frame.
public enum CRC16 {
    static let table: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }

    public static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc = table[Int((crc >> 8) ^ UInt16(byte))] ^ (crc << 8)
        }
        return ~crc
    }
}
