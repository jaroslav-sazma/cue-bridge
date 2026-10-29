import CryptoKit
import Foundation

nonisolated enum BridgeProtocol {
    static let version = 1
    static let maxBodyBytes = 1_048_576
    static let maxBinaryBytes = 1_048_576
    static let bonjourType = "_cuebridge._tcp"
    static let gattService = "e8f0e1fc-e5f4-40ba-a53f-87911835c3bb"
    static let gattDoorbell = "0978ea53-a36b-43a4-a38d-5a26bc34b549"
    static let gattCommand = "eec765d8-f473-40be-a4b4-6998d3ef5602"
    static let gattPsm = "012d7eb8-5ac2-4600-b849-a9475da8a1d8"
}

// Spec, Discovery: `v` always, `pair=1` only while pairing mode is on.
nonisolated enum BonjourTxt {
    static func entries(pairingMode: Bool) -> [String: String] {
        var txt = ["v": String(BridgeProtocol.version)]
        if pairingMode { txt["pair"] = "1" }
        return txt
    }
}

nonisolated extension Data {
    init?(hex: String) {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let nibble: UInt8
            switch character {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = character - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = character - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = character - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let value = high {
                bytes.append(value << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        self.init(bytes)
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff),
        ])
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(value >> 32))
        appendUInt32(UInt32(value & 0xffff_ffff))
    }

    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) << 24 | UInt32(self[start + 1]) << 16
            | UInt32(self[start + 2]) << 8 | UInt32(self[start + 3])
    }
}

nonisolated enum Fingerprint {
    static func of(certificateDER: Data) -> Data {
        Data(SHA256.hash(data: certificateDER))
    }

    static func isWellFormed(_ hex: String) -> Bool {
        hex.utf8.count == 64 && hex.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
