import Darwin
import Foundation
import Security
import Synchronization

// The file-based login keychain: the data protection keychain needs a restricted entitlement, which
// an ad-hoc signed app cannot carry. Items get the default ACL that trusts the creating code, so a
// rebuild with a new ad-hoc signature makes the system ask once before the new build may use them.
nonisolated final class KeychainStore: BridgeStore {
    private static let certificate = KeychainQueries.certificateAccount

    // Fails closed: without the login keychain every operation throws, nothing falls back to the
    // default keychain or the search list. Only an open that succeeded is kept; a failed one is tried
    // again by the next operation, so an open made too early at login does not last until relaunch.
    private let login = Mutex<KeychainQueries?>(nil)
    private let service: String
    private let identityLabel: String

    init(service: String = KeychainQueries.service, identityLabel: String = KeychainQueries.identityLabel) {
        self.service = service
        self.identityLabel = identityLabel
    }

    private func queries() throws -> KeychainQueries {
        try login.withLock { cached in
            if let cached { return cached }
            let opened = KeychainQueries(keychain: try Self.openLoginKeychain(), service: service, identityLabel: identityLabel)
            cached = opened
            return opened
        }
    }

    private func vault() throws -> PairingVault {
        PairingVault(items: GenericPasswords(queries: try queries()))
    }

    // The file keychain overrides a certificate's label with its common name, so the certificate is
    // kept as a generic password and SecIdentityCreateWithCertificate pairs it with the key, which
    // it finds by the public key hash.
    func loadOrCreateIdentity() throws -> LocalIdentity {
        let queries = try self.queries()
        let passwords = GenericPasswords(queries: queries)
        if let der = try passwords.read(Self.certificate), let certificate = SecCertificateCreateWithData(nil, der as CFData) {
            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(queries.keychain, certificate, &identity)
            if status == errSecSuccess, let identity {
                return LocalIdentity(identity: identity, certificateDER: der)
            }
            guard status == errSecItemNotFound else { throw StoreError(operation: "identity lookup", status: status) }
        }
        try passwords.delete(Self.certificate)
        try Self.delete(queries.identityKey)
        return try createIdentity(queries)
    }

    func loadPairing(on host: String?) throws -> StoredPairing {
        try vault().load(on: host)
    }

    func savePairing(_ record: PairingRecord, on host: String) throws {
        try vault().save(record, on: host)
    }

    func wipePairing() throws {
        try vault().wipe()
    }

    private func createIdentity(_ queries: KeychainQueries) throws -> LocalIdentity {
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(queries.newIdentityKey as CFDictionary, &error) else {
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
        let status = SecIdentityCreateWithCertificate(queries.keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw StoreError(operation: "identity create", status: status) }
        try GenericPasswords(queries: queries).write(der, to: Self.certificate)
        return LocalIdentity(identity: identity, certificateDER: der)
    }

    // SecKeychainOpen succeeds for a path with no keychain behind it; only the status call finds out.
    // The home comes from the user's record, never from HOME or CFFIXED_USER_HOME, which whoever
    // starts the app chooses.
    @diagnose(DeprecatedDeclaration, as: ignored, reason: "the file keychain has no other way to be named")
    private static func openLoginKeychain() throws -> SecKeychain {
        guard let home = userHome() else { throw StoreError(operation: "login keychain path", status: errSecNoSuchKeychain) }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(home + "/Library/Keychains/login.keychain-db", &keychain)
        guard status == errSecSuccess, let keychain else {
            throw StoreError(operation: "login keychain open", status: status == errSecSuccess ? errSecNoSuchKeychain : status)
        }
        var flags: SecKeychainStatus = 0
        let state = SecKeychainGetStatus(keychain, &flags)
        guard state == errSecSuccess else { throw StoreError(operation: "login keychain status", status: state) }
        return keychain
    }

    private static func userHome() -> String? {
        let size = max(sysconf(_SC_GETPW_R_SIZE_MAX), 4096)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        var entry = passwd()
        var found: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(getuid(), &entry, buffer, size, &found) == 0, found != nil, let directory = entry.pw_dir else {
            return nil
        }
        return String(cString: directory)
    }

    fileprivate static func delete(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError(operation: "delete", status: status)
        }
    }
}

nonisolated private struct GenericPasswords: SecretItems {
    let queries: KeychainQueries

    func read(_ account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(queries.readPassword(account) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StoreError(operation: "read \(account)", status: status)
        }
        return data
    }

    func write(_ data: Data, to account: String) throws {
        let status = SecItemUpdate(queries.password(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StoreError(operation: "update \(account)", status: status) }
        let addStatus = SecItemAdd(queries.newPassword(data, for: account) as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError(operation: "add \(account)", status: addStatus) }
    }

    func delete(_ account: String) throws {
        try KeychainStore.delete(queries.password(account))
    }
}
