import Foundation
import Security

// Every query names the login keychain itself. The default keychain and the search list are the
// user's settings, which any process of the same user can change: a write could then land in a
// keychain whose password that process knows, and a read find an item it planted in one of its own.
// Nothing here may change what identifies an item, or the pinned queries would stop finding the items
// earlier versions wrote to the login keychain as the default one.
nonisolated struct KeychainQueries: @unchecked Sendable {
    static let service = "app.cue.bridge"
    static let identityLabel = "app.cue.bridge.identity"
    static let certificateAccount = "identity-certificate"

    let keychain: CFTypeRef
    var service = Self.service
    var identityLabel = Self.identityLabel

    func password(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecMatchSearchList: [keychain],
        ]
    }

    func readPassword(_ account: String) -> [CFString: Any] {
        var query = password(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        return query
    }

    func newPassword(_ data: Data, for account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: "Cue: bridge \(account)", kSecValueData: data, kSecUseKeychain: keychain,
        ]
    }

    var identityKey: [CFString: Any] {
        [kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(identityLabel.utf8), kSecMatchSearchList: [keychain]]
    }

    // kSecUseKeychain goes at the top level: the file keychain reads it there, not from the key's own
    // attributes.
    var newIdentityKey: [CFString: Any] {
        [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseKeychain: keychain,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrLabel: identityLabel,
                kSecAttrApplicationTag: Data(identityLabel.utf8),
            ] as [CFString: Any],
        ]
    }
}
