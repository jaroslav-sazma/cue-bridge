import CryptoKit
import Foundation

nonisolated enum SignalDirection: Sendable {
    case phoneToMac
    case macToPhone

    var nonceTag: UInt32 {
        switch self {
        case .phoneToMac: 1
        case .macToPhone: 2
        }
    }
}

nonisolated enum SignalRejection: Error, Equatable {
    case malformed
    case replay
    case authentication
}

nonisolated enum SignalSealError: Error, Equatable {
    case plaintextTooLong
}

nonisolated struct OpenedSignal: Equatable, Sendable {
    var type: UInt8
    var seq: UInt32
    var plaintext: Data
}

nonisolated enum SignalFrame {
    static let maxFrameBytes = 180
    static let headerBytes = 5
    static let tagBytes = 16
    static let minFrameBytes = headerBytes + tagBytes
    static let maxPlaintextBytes = maxFrameBytes - headerBytes - tagBytes
    static let lastSeq = UInt32.max

    static func nonce(direction: SignalDirection, seq: UInt32) -> Data {
        var nonce = Data(capacity: 12)
        nonce.appendUInt32(direction.nonceTag)
        nonce.appendUInt32(0)
        nonce.appendUInt32(seq)
        return nonce
    }

    static func seal(
        type: UInt8, seq: UInt32, plaintext: Data, key: SymmetricKey, direction: SignalDirection
    ) throws -> Data {
        guard plaintext.count <= maxPlaintextBytes else { throw SignalSealError.plaintextTooLong }
        let box = try ChaChaPoly.seal(
            plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce(direction: direction, seq: seq)),
            authenticating: Data([type])
        )
        var frame = Data(capacity: headerBytes + plaintext.count + tagBytes)
        frame.append(type)
        frame.appendUInt32(seq)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    // The order of the checks is normative: size, replay, then the AEAD. A rejected frame changes
    // no state; on success the caller records the returned seq in the window.
    static func open(
        _ frame: Data, key: SymmetricKey, direction: SignalDirection, window: ReplayWindow
    ) throws(SignalRejection) -> OpenedSignal {
        guard (minFrameBytes...maxFrameBytes).contains(frame.count) else { throw .malformed }
        let frame = Data(frame)
        let type = frame[0]
        let seq = frame.uint32(at: 1)
        guard window.permits(seq) else { throw .replay }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce(direction: direction, seq: seq)),
                ciphertext: frame[headerBytes ..< frame.count - tagBytes],
                tag: frame[(frame.count - tagBytes)...]
            )
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: Data([type]))
            return OpenedSignal(type: type, seq: seq, plaintext: plaintext)
        } catch {
            throw .authentication
        }
    }
}

nonisolated enum Signal: Equatable, Sendable {
    case notifPosted(keyHash: String)
    case notifRemoved(keyHash: String)
    case dismiss(keyHash: String, revision: Int64? = nil)
    case reply(keyHash: String, text: String)
    case replyOverTcp(keyHash: String)
    case clipboardSmall(text: String, sensitive: Bool, ageMs: Int64? = nil)
    case syncRequest
    case replyError(keyHash: String, reason: String?)
    case ping
    case clipboardPending
    case replyOk(keyHash: String)
    case lockState(locked: Bool)
    case lock

    var code: UInt8 {
        switch self {
        case .notifPosted: 1
        case .notifRemoved: 2
        case .dismiss: 3
        case .reply, .replyOverTcp: 4
        case .clipboardSmall: 5
        case .syncRequest: 7
        case .replyError: 8
        case .ping: 9
        case .clipboardPending: 10
        case .replyOk: 11
        case .lockState: 12
        case .lock: 13
        }
    }

    var name: String {
        Self.name(of: code)
    }

    var keyHash: String? {
        switch self {
        case .notifPosted(let hash), .notifRemoved(let hash), .dismiss(let hash, _), .reply(let hash, _),
            .replyOverTcp(let hash), .replyError(let hash, _), .replyOk(let hash):
            hash
        default:
            nil
        }
    }

    static func name(of code: UInt8) -> String {
        switch code {
        case 1: "notif-posted"
        case 2: "notif-removed"
        case 3: "dismiss"
        case 4: "reply"
        case 5: "clipboard-small"
        case 7: "sync-request"
        case 8: "reply-error"
        case 9: "ping"
        case 10: "clipboard-pending"
        case 11: "reply-ok"
        case 12: "lock-state"
        case 13: "lock"
        default: "unknown-\(code)"
        }
    }

    static func keyHash(of notificationKey: String) -> String {
        Data(SHA256.hash(data: Data(notificationKey.utf8)).prefix(8)).hex
    }

    static func isKeyHash(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    // Written member by member: JSONEncoder does not keep member order, and a fixed order keeps
    // the frames identical to the launcher's for the same signal.
    func plaintext() throws -> Data {
        func string(_ value: String) throws -> String {
            let json = JSONEncoder()
            json.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try json.encode(value), as: UTF8.self)
        }
        let body = switch self {
        case .notifPosted(let hash), .notifRemoved(let hash), .dismiss(let hash, nil), .replyOk(let hash):
            #""k":\#(try string(hash))"#
        case .dismiss(let hash, let revision?):
            #""k":\#(try string(hash)),"r":\#(revision)"#
        case .reply(let hash, let text):
            #""k":\#(try string(hash)),"t":\#(try string(text))"#
        case .replyOverTcp(let hash):
            #""k":\#(try string(hash)),"tcp":true"#
        case .clipboardSmall(let text, let sensitive, nil):
            #""t":\#(try string(text)),"s":\#(sensitive)"#
        case .clipboardSmall(let text, let sensitive, let ageMs?):
            #""t":\#(try string(text)),"s":\#(sensitive),"a":\#(ageMs)"#
        case .lockState(let locked):
            #""l":\#(locked)"#
        case .syncRequest, .ping, .clipboardPending, .lock:
            ""
        case .replyError(let hash, nil):
            #""k":\#(try string(hash))"#
        case .replyError(let hash, let reason?):
            #""k":\#(try string(hash)),"r":\#(try string(reason))"#
        }
        return Data("{\(body)}".utf8)
    }

    func allows(_ direction: SignalDirection) -> Bool {
        switch self {
        case .ping: true
        case .notifPosted, .notifRemoved, .replyError, .replyOk, .lock: direction == .phoneToMac
        case .dismiss, .reply, .replyOverTcp, .clipboardSmall, .syncRequest, .clipboardPending, .lockState:
            direction == .macToPhone
        }
    }
}

nonisolated enum SignalInterpretation: Equatable, Sendable {
    case valid(Signal)
    case unknownType
    case invalid
}

nonisolated extension Signal {
    static func interpret(type: UInt8, plaintext: Data, direction: SignalDirection) -> SignalInterpretation {
        let json = JSONDecoder()
        let signal: Signal
        do {
            switch type {
            case 1, 2, 11:
                let hash = try json.decode(Plain.Key.self, from: plaintext).k
                guard isKeyHash(hash) else { return .invalid }
                signal = type == 1 ? .notifPosted(keyHash: hash) : type == 2
                    ? .notifRemoved(keyHash: hash) : .replyOk(keyHash: hash)
            case 3:
                let dismiss = try json.decode(Plain.Dismiss.self, from: plaintext)
                guard isKeyHash(dismiss.k) else { return .invalid }
                signal = .dismiss(keyHash: dismiss.k, revision: dismiss.r)
            case 4:
                let reply = try json.decode(Plain.Reply.self, from: plaintext)
                guard isKeyHash(reply.k) else { return .invalid }
                switch (reply.t, reply.tcp == true) {
                case (let text?, false): signal = .reply(keyHash: reply.k, text: text)
                case (nil, true): signal = .replyOverTcp(keyHash: reply.k)
                default: return .invalid
                }
            case 5:
                let clip = try json.decode(Plain.Clipboard.self, from: plaintext)
                signal = .clipboardSmall(text: clip.t, sensitive: clip.s, ageMs: clip.a)
            case 7, 9, 10, 13:
                _ = try json.decode(Plain.Empty.self, from: plaintext)
                signal = switch type {
                case 7: .syncRequest
                case 9: .ping
                case 10: .clipboardPending
                default: .lock
                }
            case 12:
                signal = .lockState(locked: try json.decode(Plain.LockState.self, from: plaintext).l)
            case 8:
                let error = try json.decode(Plain.ReplyError.self, from: plaintext)
                guard isKeyHash(error.k) else { return .invalid }
                signal = .replyError(keyHash: error.k, reason: error.r)
            default:
                return .unknownType
            }
        } catch {
            return .invalid
        }
        return signal.allows(direction) ? .valid(signal) : .invalid
    }
}

nonisolated private enum Plain {
    struct Empty: Decodable {
        private struct NoKeys: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            _ = try decoder.container(keyedBy: NoKeys.self)
        }
    }

    struct Key: Codable { var k: String }
    struct Dismiss: Codable { var k: String; var r: Int64? }
    struct Reply: Codable { var k: String; var t: String?; var tcp: Bool? }
    struct Clipboard: Codable { var t: String; var s: Bool; var a: Int64? }
    struct ReplyError: Codable { var k: String; var r: String? }
    struct LockState: Codable { var l: Bool }
}
