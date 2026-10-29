import Foundation

// macOS has no public API that mints a certificate, so this writes the minimal DER by hand: an X.509
// v3 TBSCertificate without extensions, signed ECDSA-SHA256 over a P-256 key. The peer ignores
// every X.509 property and pins the SHA-256 of these bytes.
nonisolated enum SelfSignedCertificate {
    static let commonName = "Cue Bridge"

    static func tbs(publicKeyX963: Data, serial: Data, notBefore: Date) -> Data {
        sequence(
            explicit(0, integer(Data([2])))
                + integer(serial)
                + ecdsaWithSHA256
                + name
                + sequence(utcTime(notBefore) + noWellDefinedExpiration)
                + name
                + sequence(sequence(oid(idEcPublicKey) + oid(prime256v1)) + bitString(publicKeyX963))
        )
    }

    static func certificate(tbs: Data, signatureDER: Data) -> Data {
        sequence(tbs + ecdsaWithSHA256 + bitString(signatureDER))
    }

    private static let idEcPublicKey: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    private static let prime256v1: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
    private static let ecdsaWithSHA256Oid: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]
    private static let commonNameOid: [UInt8] = [0x55, 0x04, 0x03]

    private static var ecdsaWithSHA256: Data { sequence(oid(ecdsaWithSHA256Oid)) }

    private static var name: Data {
        sequence(element(0x31, sequence(oid(commonNameOid) + element(0x0c, Data(commonName.utf8)))))
    }

    // RFC 5280 §4.1.2.5: 99991231235959Z means the certificate has no well-defined expiration.
    private static var noWellDefinedExpiration: Data { element(0x18, Data("99991231235959Z".utf8)) }

    private static func utcTime(_ date: Date) -> Data {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let digits = [parts.year! % 100, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!]
            .map { $0 < 10 ? "0\($0)" : "\($0)" }
            .joined()
        return element(0x17, Data((digits + "Z").utf8))
    }

    private static func integer(_ magnitude: Data) -> Data {
        var bytes = Data(magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(0x02, bytes)
    }

    private static func oid(_ body: [UInt8]) -> Data { element(0x06, Data(body)) }
    private static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }
    private static func sequence(_ content: Data) -> Data { element(0x30, content) }
    private static func explicit(_ tag: UInt8, _ content: Data) -> Data { element(0xa0 | tag, content) }

    private static func element(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let length = content.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var lengthBytes = [UInt8]()
            var remaining = length
            while remaining > 0 {
                lengthBytes.insert(UInt8(remaining & 0xff), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(lengthBytes.count))
            out.append(contentsOf: lengthBytes)
        }
        out.append(content)
        return out
    }
}
