import Foundation
import Security
import Testing

// Any object stands in for the login keychain: the queries are only built here, never run.
private let login = NSObject()
private let queries = KeychainQueries(keychain: login)

private func searchesOnlyLogin(_ query: [CFString: Any]) -> Bool {
    guard let list = query[kSecMatchSearchList] as? [AnyObject] else { return false }
    return list.count == 1 && list[0] === login && query[kSecUseKeychain] == nil
}

@Suite("keychain queries")
struct KeychainQueriesTests {
    @Test("every lookup, update and delete searches the login keychain alone")
    func pinnedSearches() {
        for account in [PairingVault.peerPin, PairingVault.kBle, PairingVault.host, KeychainQueries.certificateAccount] {
            #expect(searchesOnlyLogin(queries.password(account)), "\(account)")
            #expect(searchesOnlyLogin(queries.readPassword(account)), "\(account)")
        }
        #expect(searchesOnlyLogin(queries.identityKey))
    }

    @Test("every item written goes into the login keychain")
    func pinnedWrites() {
        let item = queries.newPassword(Data([1]), for: PairingVault.kBle)
        #expect(item[kSecUseKeychain] as AnyObject? === login)
        #expect(item[kSecMatchSearchList] == nil)
        let key = queries.newIdentityKey
        #expect(key[kSecUseKeychain] as AnyObject? === login)
        let privateAttributes = key[kSecPrivateKeyAttrs] as? [CFString: Any]
        #expect(privateAttributes?[kSecAttrIsPermanent] as? Bool == true)
    }

    // A pinned query finds what earlier versions wrote only while these stay as they were.
    @Test("the attributes that identify an item keep their names")
    func identifyingAttributes() {
        #expect(KeychainQueries.service == "app.cue.bridge")
        #expect(KeychainQueries.identityLabel == "app.cue.bridge.identity")
        #expect(KeychainQueries.certificateAccount == "identity-certificate")
        let lookup = queries.readPassword(PairingVault.kBle)
        #expect(lookup[kSecClass] as? String == kSecClassGenericPassword as String)
        #expect(lookup[kSecAttrService] as? String == "app.cue.bridge")
        #expect(lookup[kSecAttrAccount] as? String == "k-ble")
        #expect(lookup[kSecReturnData] as? Bool == true)
        #expect(lookup[kSecMatchLimit] as? String == kSecMatchLimitOne as String)

        let item = queries.newPassword(Data([1]), for: PairingVault.peerPin)
        #expect(item[kSecAttrService] as? String == "app.cue.bridge")
        #expect(item[kSecAttrAccount] as? String == "peer-pin")
        #expect(item[kSecAttrLabel] as? String == "Cue: bridge peer-pin")
        #expect(item[kSecValueData] as? Data == Data([1]))

        let tag = Data("app.cue.bridge.identity".utf8)
        #expect(queries.identityKey[kSecClass] as? String == kSecClassKey as String)
        #expect(queries.identityKey[kSecAttrApplicationTag] as? Data == tag)
        let key = queries.newIdentityKey
        #expect(key[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String)
        #expect(key[kSecAttrKeySizeInBits] as? Int == 256)
        let privateAttributes = key[kSecPrivateKeyAttrs] as? [CFString: Any]
        #expect(privateAttributes?[kSecAttrLabel] as? String == "app.cue.bridge.identity")
        #expect(privateAttributes?[kSecAttrApplicationTag] as? Data == tag)
    }

    // An extra attribute, such as kSecUseDataProtectionKeychain or an access group, would change which
    // items a query finds.
    @Test("the queries carry no attribute beyond these")
    func exactAttributes() {
        let match: Set<CFString> = [kSecClass, kSecAttrService, kSecAttrAccount, kSecMatchSearchList]
        #expect(Set(queries.password(PairingVault.kBle).keys) == match)
        #expect(Set(queries.readPassword(PairingVault.kBle).keys) == match.union([kSecReturnData, kSecMatchLimit]))
        #expect(
            Set(queries.newPassword(Data([1]), for: PairingVault.kBle).keys)
                == [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrLabel, kSecValueData, kSecUseKeychain]
        )
        #expect(Set(queries.identityKey.keys) == [kSecClass, kSecAttrApplicationTag, kSecMatchSearchList])
        let key = queries.newIdentityKey
        #expect(Set(key.keys) == [kSecAttrKeyType, kSecAttrKeySizeInBits, kSecUseKeychain, kSecPrivateKeyAttrs])
        let privateAttributes = key[kSecPrivateKeyAttrs] as? [CFString: Any]
        #expect(privateAttributes.map { Set($0.keys) } == [kSecAttrIsPermanent, kSecAttrLabel, kSecAttrApplicationTag])
    }
}
