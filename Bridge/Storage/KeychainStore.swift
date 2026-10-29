import Foundation
import Security

// The file-based login keychain: the data protection keychain needs a restricted entitlement, which
// an ad-hoc signed app cannot carry. Items get the default ACL that trusts the creating code, so a
// rebuild with a new ad-hoc signature makes the system ask once before the new build may use them.
nonisolated final class KeychainStore: BridgeStore {
    private static let certificate = "identity-certificate"

    private let passwords: GenericPasswords
    private let identityLabel: String

    init(service: String = "app.cue.bridge", identityLabel: String = "app.cue.bridge.identity") {
        passwords = GenericPasswords(service: service)
        self.identityLabel = identityLabel
    }

    private var vault: PairingVault { PairingVault(items: passwords) }

    // The file keychain overrides a certificate's label with its common name, so the certificate is
    // kept as a generic password and SecIdentityCreateWithCertificate pairs it with the key, which
    // it finds by the public key hash.
    func loadOrCreateIdentity() throws -> LocalIdentity {
        if let der = try passwords.read(Self.certificate), let certificate = SecCertificateCreateWithData(nil, der as CFData) {
            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
            if status == errSecSuccess, let identity {
                return LocalIdentity(identity: identity, certificateDER: der)
            }
            guard status == errSecItemNotFound else { throw StoreError(operation: "identity lookup", status: status) }
        }
        try passwords.delete(Self.certificate)
        try Self.delete([kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(identityLabel.utf8)])
        return try createIdentity()
    }

    func loadPairing(on host: String?) throws -> StoredPairing {
        try vault.load(on: host)
    }

    func savePairing(_ record: PairingRecord, on host: String) throws {
        try vault.save(record, on: host)
    }

    func wipePairing() throws {
        try vault.wipe()
    }

    private func createIdentity() throws -> LocalIdentity {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrLabel: identityLabel,
                kSecAttrApplicationTag: Data(identityLabel.utf8),
            ] as [CFString: Any],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw error.map { $0.takeRetainedValue() as Error } ?? StoreError(operation: "public key", status: errSecParam) }
        var serial = Data(count: 16)
        let randomStatus = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw StoreError(operation: "serial", status: randomStatus) }
        let tbs = SelfSignedCertificate.tbs(publicKeyX963: publicBytes, serial: serial, notBefore: .now)
        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error
        ) as Data? else { throw error!.takeRetainedValue() as Error }
        let der = SelfSignedCertificate.certificate(tbs: tbs, signatureDER: signature)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw StoreError(operation: "certificate parse", status: errSecDecode)
        }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw StoreError(operation: "identity create", status: status) }
        try passwords.write(der, to: Self.certificate)
        return LocalIdentity(identity: identity, certificateDER: der)
    }

    fileprivate static func delete(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError(operation: "delete", status: status)
        }
    }
}

nonisolated private struct GenericPasswords: SecretItems {
    let service: String

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StoreError(operation: "read \(account)", status: status)
        }
        return data
    }

    func write(_ data: Data, to account: String) throws {
        let query = query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StoreError(operation: "update \(account)", status: status) }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Cue: bridge \(account)"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError(operation: "add \(account)", status: addStatus) }
    }

    func delete(_ account: String) throws {
        try KeychainStore.delete(query(account))
    }
}
