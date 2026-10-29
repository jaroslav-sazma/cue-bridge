import Foundation
import Security

nonisolated struct LocalIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificateDER: Data
    let fingerprint: Data

    init(identity: SecIdentity, certificateDER: Data) {
        self.identity = identity
        self.certificateDER = certificateDER
        fingerprint = Fingerprint.of(certificateDER: certificateDER)
    }
}

nonisolated struct StoreError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(operation) failed: \(status) \(message)"
    }
}

nonisolated protocol BridgeStore: Sendable {
    func loadOrCreateIdentity() throws -> LocalIdentity
    func loadPairing(on host: String?) throws -> StoredPairing
    func savePairing(_ record: PairingRecord, on host: String) throws
    func wipePairing() throws
}
