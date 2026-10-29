import Foundation

nonisolated struct NotificationInfo: Codable, Equatable, Sendable {
    var key: String
    var pkg: String
    var appLabel: String
    var title: String
    var text: String
    var when: Int64
    var threadId: String?
    var canReply: Bool
    var isClearable: Bool
    var iconHash: String?
    var revision: Int64? = nil

    private enum CodingKeys: String, CodingKey {
        case key, pkg, appLabel, title, text, when, threadId, canReply, isClearable, iconHash
        case revision = "r"
    }
}

nonisolated enum PairAbortReason: String, Sendable {
    case sasMismatch = "sas-mismatch"
    case cancelled
    case timeout
    case protocolError = "protocol-error"
    case busy

    init(wire: String) {
        self = PairAbortReason(rawValue: wire) ?? .cancelled
    }
}

nonisolated enum BridgeMessage: Equatable, Sendable {
    case hello(version: Int, clipboardFromMac: Bool? = nil)
    case bye(reason: String?)
    case pairRequest(commit: String)
    case pairResponse(publicKey: String)
    case pairReveal(publicKey: String)
    case pairConfirm(proof: String)
    case pairAbort(reason: String)
    case signal(frame: String)
    case syncRequest
    case activeSet(notifications: [NotificationInfo])
    case notifDetail(NotificationInfo)
    case iconGet(hash: String)
    case iconData(hash: String, png: Data)
    case clipboardSet(text: String, sensitive: Bool, announce: Bool, ageMs: Int64? = nil)
    case replyText(key: String, text: String)

    static let versionMismatch = "version-mismatch"
    static let replaced = "replaced"

    var type: String {
        switch self {
        case .hello: "hello"
        case .bye: "bye"
        case .pairRequest: "pair-request"
        case .pairResponse: "pair-response"
        case .pairReveal: "pair-reveal"
        case .pairConfirm: "pair-confirm"
        case .pairAbort: "pair-abort"
        case .signal: "signal"
        case .syncRequest: "sync-request"
        case .activeSet: "active-set"
        case .notifDetail: "notif-detail"
        case .iconGet: "icon-get"
        case .iconData: "icon-data"
        case .clipboardSet: "clipboard-set"
        case .replyText: "reply-text"
        }
    }

    static func pairAbort(_ reason: PairAbortReason) -> BridgeMessage {
        .pairAbort(reason: reason.rawValue)
    }

    // Returns nil for a type this version does not know. Throws when a known type lacks a required
    // member or carries one of the wrong JSON type, null included.
    static func decode(type: String, body: Data, sidecar: Data?) throws -> BridgeMessage? {
        let json = JSONDecoder()
        switch type {
        case "hello":
            let wire = try json.decode(Wire.Hello.self, from: body)
            return .hello(version: Int(wire.v), clipboardFromMac: wire.clipboardFromMac)
        case "bye":
            return .bye(reason: try json.decode(Wire.Bye.self, from: body).reason)
        case "pair-request":
            return .pairRequest(commit: try json.decode(Wire.PairRequest.self, from: body).commit)
        case "pair-response":
            return .pairResponse(publicKey: try json.decode(Wire.PairKey.self, from: body).pk)
        case "pair-reveal":
            return .pairReveal(publicKey: try json.decode(Wire.PairKey.self, from: body).pk)
        case "pair-confirm":
            return .pairConfirm(proof: try json.decode(Wire.PairConfirm.self, from: body).proof)
        case "pair-abort":
            return .pairAbort(reason: try json.decode(Wire.PairAbort.self, from: body).reason)
        case "signal":
            return .signal(frame: try json.decode(Wire.Signal.self, from: body).frame)
        case "sync-request":
            return .syncRequest
        case "active-set":
            return .activeSet(notifications: try json.decode(Wire.ActiveSet.self, from: body).notifications)
        case "notif-detail":
            return .notifDetail(try json.decode(NotificationInfo.self, from: body))
        case "icon-get":
            return .iconGet(hash: try json.decode(Wire.IconGet.self, from: body).hash)
        case "icon-data":
            let wire = try json.decode(Wire.IconData.self, from: body)
            guard let sidecar, sidecar.count == Int(wire.binaryBytes) else { throw TcpFrameError.malformed("icon-data sidecar") }
            return .iconData(hash: wire.hash, png: sidecar)
        case "clipboard-set":
            let wire = try json.decode(Wire.ClipboardSet.self, from: body)
            return .clipboardSet(
                text: wire.text, sensitive: wire.sensitive, announce: wire.announce ?? false, ageMs: wire.ageMs
            )
        case "reply-text":
            let wire = try json.decode(Wire.ReplyText.self, from: body)
            return .replyText(key: wire.key, text: wire.text)
        default:
            return nil
        }
    }

    func encodedBody() throws -> (body: Data, sidecar: Data?) {
        let json = JSONEncoder()
        json.outputFormatting = [.withoutEscapingSlashes]
        let type = type
        switch self {
        case .hello(let version, let clipboardFromMac):
            guard let v = Int32(exactly: version) else { throw TcpFrameError.malformed("hello v") }
            return (try json.encode(Wire.Hello(type: type, v: v, clipboardFromMac: clipboardFromMac)), nil)
        case .bye(let reason):
            return (try json.encode(Wire.Bye(type: type, reason: reason)), nil)
        case .pairRequest(let commit):
            return (try json.encode(Wire.PairRequest(type: type, commit: commit)), nil)
        case .pairResponse(let publicKey), .pairReveal(let publicKey):
            return (try json.encode(Wire.PairKey(type: type, pk: publicKey)), nil)
        case .syncRequest:
            return (try json.encode(Wire.Empty(type: type)), nil)
        case .pairConfirm(let proof):
            return (try json.encode(Wire.PairConfirm(type: type, proof: proof)), nil)
        case .pairAbort(let reason):
            return (try json.encode(Wire.PairAbort(type: type, reason: reason)), nil)
        case .signal(let frame):
            return (try json.encode(Wire.Signal(type: type, frame: frame)), nil)
        case .activeSet(let notifications):
            return (try json.encode(Wire.ActiveSet(type: type, notifications: notifications)), nil)
        case .notifDetail(let info):
            return (try json.encode(Wire.NotifDetail(type: type, info: info)), nil)
        case .iconGet(let hash):
            return (try json.encode(Wire.IconGet(type: type, hash: hash)), nil)
        case .iconData(let hash, let png):
            guard (1...BridgeProtocol.maxBinaryBytes).contains(png.count) else {
                throw TcpFrameError.malformed("icon-data size")
            }
            return (try json.encode(Wire.IconData(type: type, hash: hash, binaryBytes: Int32(png.count))), png)
        case .clipboardSet(let text, let sensitive, let announce, let ageMs):
            let wire = Wire.ClipboardSet(
                type: type, text: text, sensitive: sensitive, announce: announce ? true : nil, ageMs: ageMs
            )
            return (try json.encode(wire), nil)
        case .replyText(let key, let text):
            return (try json.encode(Wire.ReplyText(type: type, key: key, text: text)), nil)
        }
    }
}

nonisolated private enum Wire {
    struct Empty: Codable { var type: String }
    struct Hello: Codable { var type: String; var v: Int32; var clipboardFromMac: Bool? }
    struct Bye: Codable { var type: String; var reason: String? }
    struct PairRequest: Codable { var type: String; var commit: String }
    struct PairKey: Codable { var type: String; var pk: String }
    struct PairConfirm: Codable { var type: String; var proof: String }
    struct PairAbort: Codable { var type: String; var reason: String }
    struct Signal: Codable { var type: String; var frame: String }
    struct ActiveSet: Codable { var type: String; var notifications: [NotificationInfo] }
    struct IconGet: Codable { var type: String; var hash: String }
    struct IconData: Codable { var type: String; var hash: String; var binaryBytes: Int32 }
    struct ClipboardSet: Codable {
        var type: String; var text: String; var sensitive: Bool; var announce: Bool?; var ageMs: Int64?
    }
    struct ReplyText: Codable { var type: String; var key: String; var text: String }

    struct NotifDetail: Encodable {
        var type: String
        var info: NotificationInfo

        private enum CodingKeys: String, CodingKey { case type }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try info.encode(to: encoder)
        }
    }
}
