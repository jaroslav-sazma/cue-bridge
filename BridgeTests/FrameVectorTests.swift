import CryptoKit
import Foundation
import Testing

@Suite("frames.json")
struct FrameVectorTests {
    private var key: SymmetricKey {
        SymmetricKey(data: Data(vectorHex: Vectors.frames?.kBle ?? ""))
    }

    @Test("the frame limit matches")
    func limit() throws {
        #expect(try #require(Vectors.frames).maxFrameBytes == SignalFrame.maxFrameBytes)
        #expect(SignalFrame.maxPlaintextBytes == 159)
    }

    @Test(arguments: Vectors.frames?.keyHashes ?? [])
    func keyHash(_ vector: FramesFile.KeyHash) {
        #expect(Signal.keyHash(of: vector.key) == vector.hash)
    }

    @Test(arguments: Vectors.frames?.vectors ?? [])
    func sealAndOpen(_ vector: FramesFile.Vector) throws {
        let direction = direction(vector.direction)
        let plaintext = Data(vector.plaintext.utf8)
        #expect(SignalFrame.nonce(direction: direction, seq: vector.seq).hex == vector.nonce)
        let sealed = try SignalFrame.seal(
            type: vector.type, seq: vector.seq, plaintext: plaintext, key: key, direction: direction
        )
        #expect(sealed.hex == vector.frame)

        let frame = Data(vectorHex: vector.frame)
        let opened = try SignalFrame.open(frame, key: key, direction: direction, window: ReplayWindow())
        #expect(opened == OpenedSignal(type: vector.type, seq: vector.seq, plaintext: plaintext))
        if vector.seq > 0 {
            #expect(throws: Never.self) {
                try SignalFrame.open(frame, key: key, direction: direction, window: .accepting([vector.seq - 1]))
            }
        }

        let interpretation = Signal.interpret(type: opened.type, plaintext: opened.plaintext, direction: direction)
        switch vector.signal {
        case "valid":
            guard case .valid(let signal) = interpretation else {
                Issue.record("expected a valid signal, got \(interpretation)")
                return
            }
            #expect(signal.code == vector.type)
            #expect(try signal.plaintext() == plaintext)
        case "unknown-type":
            #expect(interpretation == .unknownType)
        case "invalid":
            #expect(interpretation == .invalid)
        case "wrong-direction":
            #expect(interpretation == .invalid)
            let other: SignalDirection = direction == .phoneToMac ? .macToPhone : .phoneToMac
            #expect(Signal.interpret(type: opened.type, plaintext: opened.plaintext, direction: other) != .invalid)
        default:
            Issue.record("unknown expectation \(vector.signal)")
        }
    }

    // An ignored signal was still accepted: the window holds its seq from then on.
    @Test(arguments: (Vectors.frames?.vectors ?? []).filter { $0.signal != "valid" })
    func ignoredSignalUsesUpSeq(_ vector: FramesFile.Vector) throws {
        let frame = Data(vectorHex: vector.frame)
        let opened = try SignalFrame.open(
            frame, key: key, direction: direction(vector.direction), window: .accepting([vector.seq - 1])
        )
        #expect(throws: SignalRejection.replay) {
            try SignalFrame.open(
                frame, key: key, direction: direction(vector.direction), window: .accepting([opened.seq])
            )
        }
    }

    @Test(arguments: Vectors.frames?.rejections ?? [])
    func rejection(_ vector: FramesFile.Rejection) throws {
        #expect(vector.expect == "fail")
        let reasons: [String: SignalRejection] = [
            "authentication": .authentication, "replay": .replay, "malformed": .malformed,
        ]
        let expected = try #require(reasons[vector.reason])
        #expect(throws: expected) {
            try SignalFrame.open(
                Data(vectorHex: vector.frame), key: key, direction: direction(vector.direction),
                window: .accepting(vector.accepted)
            )
        }
    }

    @Test("the replay window has the size the vectors give")
    func windowSize() throws {
        #expect(try #require(Vectors.frames).replayWindow.size == ReplayWindow.size)
    }

    @Test(arguments: Vectors.frames?.replayWindow.cases ?? [])
    func replayWindow(_ vector: FramesFile.WindowCase) {
        var window = ReplayWindow()
        let decided = vector.offered.map { seq in
            guard window.permits(seq) else { return "replay" }
            window.record(seq)
            return "accept"
        }
        #expect(decided == vector.expect)
    }

    @Test("a plaintext over 159 bytes is not sealed")
    func plaintextTooLong() {
        #expect(throws: SignalSealError.plaintextTooLong) {
            try SignalFrame.seal(type: 5, seq: 0, plaintext: Data(count: 160), key: key, direction: .macToPhone)
        }
    }

    @Test("a frame is never accepted by its own sender's direction")
    func ownDirection() throws {
        let frame = try SignalFrame.seal(
            type: 7, seq: 3, plaintext: Data("{}".utf8), key: key, direction: .macToPhone
        )
        #expect(throws: SignalRejection.authentication) {
            try SignalFrame.open(frame, key: key, direction: .phoneToMac, window: ReplayWindow())
        }
    }

    @Test("a signal sent in a direction its type does not allow is invalid")
    func wrongDirection() {
        #expect(Signal.interpret(type: 3, plaintext: Data(#"{"k":"54892d1f759b11f6"}"#.utf8), direction: .phoneToMac) == .invalid)
    }

    @Test("clipboard-pending is Mac to phone only and carries an empty object")
    func clipboardPending() throws {
        func interpret(_ json: String, _ direction: SignalDirection = .macToPhone) -> SignalInterpretation {
            Signal.interpret(type: 10, plaintext: Data(json.utf8), direction: direction)
        }
        #expect(interpret("{}") == .valid(.clipboardPending))
        #expect(interpret("[]") == .invalid)
        #expect(interpret("{}", .phoneToMac) == .invalid)
        #expect(Signal.clipboardPending.code == 10 && Signal.clipboardPending.name == "clipboard-pending")
        #expect(try Signal.clipboardPending.plaintext() == Data("{}".utf8))
    }

    @Test("ping goes either way and carries an object; unknown members are ignored")
    func ping() throws {
        func interpret(_ json: String, _ direction: SignalDirection = .phoneToMac) -> SignalInterpretation {
            Signal.interpret(type: 9, plaintext: Data(json.utf8), direction: direction)
        }
        #expect(interpret("{}") == .valid(.ping))
        #expect(interpret(#"{"x":1}"#) == .valid(.ping))
        #expect(interpret("[]") == .invalid)
        #expect(interpret("{}", .macToPhone) == .valid(.ping))
        #expect(Signal.ping.code == 9 && Signal.ping.name == "ping")
        #expect(try Signal.ping.plaintext() == Data("{}".utf8))
    }

    @Test("reply-ok goes phone to Mac only and needs a well-formed key hash")
    func replyOk() throws {
        func interpret(_ json: String, _ direction: SignalDirection = .phoneToMac) -> SignalInterpretation {
            Signal.interpret(type: 11, plaintext: Data(json.utf8), direction: direction)
        }
        #expect(interpret(#"{"k":"54892d1f759b11f6"}"#) == .valid(.replyOk(keyHash: "54892d1f759b11f6")))
        #expect(interpret(#"{"k":"54892D1F759B11F6"}"#) == .invalid)
        #expect(interpret(#"{"k":"54892d1f759b11f6"}"#, .macToPhone) == .invalid)
        #expect(Signal.replyOk(keyHash: "54892d1f759b11f6").name == "reply-ok")
    }

    @Test("lock-state goes Mac to phone with a boolean, lock phone to Mac with an empty object")
    func lock() throws {
        func interpret(_ type: UInt8, _ json: String, _ direction: SignalDirection) -> SignalInterpretation {
            Signal.interpret(type: type, plaintext: Data(json.utf8), direction: direction)
        }
        #expect(interpret(12, #"{"l":true}"#, .macToPhone) == .valid(.lockState(locked: true)))
        #expect(interpret(12, #"{"l":false,"x":1}"#, .macToPhone) == .valid(.lockState(locked: false)))
        #expect(interpret(12, "{}", .macToPhone) == .invalid)
        #expect(interpret(12, #"{"l":1}"#, .macToPhone) == .invalid)
        #expect(interpret(12, #"{"l":null}"#, .macToPhone) == .invalid)
        #expect(interpret(13, "{}", .phoneToMac) == .valid(.lock))
        #expect(interpret(13, "[]", .phoneToMac) == .invalid)
        #expect(interpret(13, "{}", .macToPhone) == .invalid)
        #expect(try Signal.lockState(locked: false).plaintext() == Data(#"{"l":false}"#.utf8))
        #expect(Signal.lockState(locked: true).name == "lock-state" && Signal.lock.name == "lock")
        #expect(Signal.lockState(locked: true).audience == .phone)
    }

    @Test("a dismiss carries the revision only when known; a null one reads as none, a string is invalid")
    func dismissRevision() throws {
        func interpret(_ json: String) -> SignalInterpretation {
            Signal.interpret(type: 3, plaintext: Data(json.utf8), direction: .macToPhone)
        }
        let hash = "54892d1f759b11f6"
        #expect(try Signal.dismiss(keyHash: hash).plaintext() == Data(#"{"k":"54892d1f759b11f6"}"#.utf8))
        #expect(try Signal.dismiss(keyHash: hash, revision: 1_791_820_800_000).plaintext()
            == Data(#"{"k":"54892d1f759b11f6","r":1791820800000}"#.utf8))
        #expect(interpret(#"{"k":"54892d1f759b11f6","r":null}"#) == .valid(.dismiss(keyHash: hash)))
        #expect(interpret(#"{"k":"54892d1f759b11f6","r":"1"}"#) == .invalid)
        #expect(interpret(#"{"k":"54892d1f759b11f6","r":1.5}"#) == .invalid)
    }

    @Test("a reply-error needs a well-formed key hash; a null reason reads as none")
    func replyError() {
        func interpret(_ json: String) -> SignalInterpretation {
            Signal.interpret(type: 8, plaintext: Data(json.utf8), direction: .phoneToMac)
        }
        #expect(interpret(#"{"k":"54892D1F759B11F6"}"#) == .invalid)
        #expect(interpret(#"{"r":"gone"}"#) == .invalid)
        #expect(interpret(#"{"k":"54892d1f759b11f6","r":null}"#) == .valid(.replyError(keyHash: "54892d1f759b11f6", reason: nil)))
        #expect(interpret(#"{"k":"54892d1f759b11f6","r":"gone","x":1}"#) == .valid(.replyError(keyHash: "54892d1f759b11f6", reason: "gone")))
    }
}

extension ReplayWindow {
    static func accepting(_ seqs: [UInt32]) -> ReplayWindow {
        var window = ReplayWindow()
        for seq in seqs {
            window.record(seq)
        }
        return window
    }
}
