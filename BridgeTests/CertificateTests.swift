import CryptoKit
import Foundation
import Security
import Testing

@Suite("Self-signed certificate")
struct CertificateTests {
    @Test("the hand-written DER parses and its signature verifies under its own key")
    func roundTrip() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let tbs = SelfSignedCertificate.tbs(
            publicKeyX963: publicKey, serial: Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }),
            notBefore: .now
        )
        let signature = try key.signature(for: tbs).derRepresentation
        let der = SelfSignedCertificate.certificate(tbs: tbs, signatureDER: signature)
        #expect(der.suffix(signature.count + 1) == Data([0]) + signature)

        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == SelfSignedCertificate.commonName)
        #expect(SecCertificateCopyData(certificate) as Data == der)
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == publicKey)
        #expect(SecKeyVerifySignature(certificateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, signature as CFData, nil))
    }

    @Test("a serial with the high bit set stays a positive INTEGER")
    func positiveSerial() {
        let tbs = SelfSignedCertificate.tbs(
            publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation, serial: Data([0x80, 0x01]),
            notBefore: .now
        )
        let integer = Data([0x02, 0x03, 0x00, 0x80, 0x01])
        #expect(tbs.range(of: integer) != nil)
    }
}
