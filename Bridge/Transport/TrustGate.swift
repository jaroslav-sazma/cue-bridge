import Foundation
import Network
import Security
import os

// The TLS verify block overrides all trust evaluation: only the SHA-256 of the leaf certificate
// counts. In pairing mode any client certificate passes and the connection decides later; outside
// it only the pinned fingerprint does.
nonisolated final class TrustGate: Sendable {
    private struct State: Sendable {
        var pairingMode = false
        var pin: Data?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: "app.cue.bridge", category: "transport")

    func setPairingMode(_ on: Bool) {
        state.withLock { $0.pairingMode = on }
    }

    func setPin(_ pin: Data?) {
        state.withLock { $0.pin = pin }
    }

    func install(on options: sec_protocol_options_t, queue: DispatchQueue) {
        sec_protocol_options_set_verify_block(options, { [self] _, trust, complete in
            guard let fingerprint = Self.leafFingerprint(of: sec_trust_copy_ref(trust).takeRetainedValue()) else {
                log.info("TLS peer rejected: no leaf certificate")
                complete(false)
                return
            }
            let admitted = state.withLock { $0.pairingMode || $0.pin == fingerprint }
            if !admitted {
                log.info("TLS peer rejected: fingerprint \(String(fingerprint.hex.prefix(8)), privacy: .public)")
            }
            complete(admitted)
        }, queue)
    }

    static func leafFingerprint(of trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return Fingerprint.of(certificateDER: SecCertificateCopyData(leaf) as Data)
    }

    static func peerFingerprint(of connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        final class Leaf { var der: Data? }
        let leaf = Leaf()
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf.der == nil {
                leaf.der = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data
            }
        }
        return leaf.der.map(Fingerprint.of(certificateDER:))
    }
}
