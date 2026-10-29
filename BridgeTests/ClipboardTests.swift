import Foundation
import Testing

private let start = ContinuousClock.now

private func text(_ clip: String) -> PasteboardClip {
    PasteboardClip(concealed: false, text: clip)
}

// #expect cannot take a mutating call, so each step records what it returned.
private struct Script {
    var machine = ClipboardPublisherMachine()
    var effects: [[ClipboardPublisherMachine.Effect]] = []

    mutating func on(_ event: ClipboardPublisherMachine.Event) {
        effects.append(machine.handle(event))
    }

    var last: [ClipboardPublisherMachine.Effect] { effects.last ?? [] }
}

@Suite("Clipboard")
struct ClipboardTests {
    @Test("clipboard-set encodes announce only when true and reads an absent one as false")
    func announceCodec() throws {
        let plain = try BridgeMessage.clipboardSet(text: "a", sensitive: true, announce: false).encodedBody().body
        // JSONEncoder does not keep member order: the members are compared, not the bytes.
        let members = try JSONSerialization.jsonObject(with: plain) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"{"type":"clipboard-set","text":"a","sensitive":true}"#.utf8)
        ) as? NSDictionary
        #expect(members != nil && members == expected)
        let announced = try BridgeMessage.clipboardSet(text: "a", sensitive: false, announce: true).encodedBody().body
        let object = try #require(try JSONSerialization.jsonObject(with: announced) as? [String: Any])
        #expect(object["announce"] as? Bool == true)
        let decoded = try BridgeMessage.decode(type: "clipboard-set", body: plain, sidecar: nil)
        #expect(decoded == .clipboardSet(text: "a", sensitive: true, announce: false))
    }

    @Test("clipboard-set encodes ageMs only when given and reads an absent or null one as none")
    func ageCodec() throws {
        let aged = try BridgeMessage.clipboardSet(text: "a", sensitive: false, announce: false, ageMs: 95_000).encodedBody().body
        let object = try #require(try JSONSerialization.jsonObject(with: aged) as? [String: Any])
        #expect(object["ageMs"] as? Int64 == 95_000)
        #expect(try BridgeMessage.decode(type: "clipboard-set", body: aged, sidecar: nil)
            == .clipboardSet(text: "a", sensitive: false, announce: false, ageMs: 95_000))
        let fresh = try BridgeMessage.clipboardSet(text: "a", sensitive: false, announce: false).encodedBody().body
        let members = try #require(try JSONSerialization.jsonObject(with: fresh) as? [String: Any])
        #expect(members["ageMs"] == nil)
        let null = Data(#"{"type":"clipboard-set","text":"a","sensitive":false,"ageMs":null}"#.utf8)
        #expect(try BridgeMessage.decode(type: "clipboard-set", body: null, sidecar: nil)
            == .clipboardSet(text: "a", sensitive: false, announce: false, ageMs: nil))
        let quoted = Data(#"{"type":"clipboard-set","text":"a","sensitive":false,"ageMs":"5"}"#.utf8)
        #expect(throws: (any Error).self) { try BridgeMessage.decode(type: "clipboard-set", body: quoted, sidecar: nil) }
    }

    @Test("a clip that waited carries its age, in a frame when it fits and over TCP when not")
    func agedEncoding() throws {
        #expect(try ClipboardEncoding.plan("short", ageMs: 1_500)
            == .small(.clipboardSmall(text: "short", sensitive: false, ageMs: 1_500)))
        #expect(try ClipboardEncoding.plan("short") == .small(.clipboardSmall(text: "short", sensitive: false)))
        let small = try Signal.clipboardSmall(text: "short", sensitive: false, ageMs: 1_500).plaintext()
        #expect(String(decoding: small, as: UTF8.self) == #"{"t":"short","s":false,"a":1500}"#)
        let long = String(repeating: "x", count: SignalFrame.maxPlaintextBytes)
        #expect(try ClipboardEncoding.plan(long, ageMs: 1_500)
            == .overTcp(.clipboardSet(text: long, sensitive: false, announce: false, ageMs: 1_500)))
        let echo = ClipboardEcho()
        #expect(try echo.decide(text("short"), at: start, ageMs: 0)
            == .send(text: "short", .small(.clipboardSmall(text: "short", sensitive: false, ageMs: 0))))
    }

    @Test("an age on the clip frame is optional, a number, and read back")
    func agedFrame() {
        func interpret(_ json: String) -> SignalInterpretation {
            Signal.interpret(type: 5, plaintext: Data(json.utf8), direction: .macToPhone)
        }
        #expect(interpret(#"{"t":"x","s":false,"a":95000}"#) == .valid(.clipboardSmall(text: "x", sensitive: false, ageMs: 95_000)))
        #expect(interpret(#"{"t":"x","s":false,"a":null}"#) == .valid(.clipboardSmall(text: "x", sensitive: false)))
        #expect(interpret(#"{"t":"x","s":false,"a":"95000"}"#) == .invalid)
    }

    @Test("a debt reports its age in milliseconds and expires after an hour")
    func debt() {
        let debt = ClipboardDebt(changeCount: 7, observedAt: start)
        #expect(debt.ageMs(at: start) == 0)
        #expect(debt.ageMs(at: start + .milliseconds(95_000)) == 95_000)
        #expect(debt.ageMs(at: start - .seconds(1)) == 0, "a clock that went back reads as fresh")
        #expect(!debt.expired(at: start + ClipboardDebt.lifetime))
        #expect(debt.expired(at: start + ClipboardDebt.lifetime + .milliseconds(1)))
        #expect(ClipboardDebt.lifetime == .seconds(3600), "the longest limit the phone offers")
        #expect(!debt.signalled)
    }

    @Test("skip reasons in order: concealed before anything is read, then not-text, empty, too-large")
    func skips() throws {
        let echo = ClipboardEcho()
        #expect(try echo.decide(PasteboardClip(concealed: true, text: "secret"), at: start) == .skip(.concealed))
        #expect(try echo.decide(PasteboardClip(concealed: true, text: nil), at: start) == .skip(.concealed))
        #expect(try echo.decide(PasteboardClip(concealed: false, text: nil), at: start) == .skip(.notText))
        #expect(try echo.decide(text(""), at: start) == .skip(.empty))
        #expect(ClipSkip.tooLarge.rawValue == "too-large")
        #expect(ClipSkip.notText.rawValue == "not-text")
    }

    @Test("the limit is 102,400 UTF-8 bytes, not characters")
    func limit() throws {
        let echo = ClipboardEcho()
        let atLimit = String(repeating: "a", count: 102_400)
        let overLimit = atLimit + "a"
        let multibyte = String(repeating: "é", count: 51_201)
        #expect(ClipboardLimits.fits(atLimit))
        #expect(!ClipboardLimits.fits(overLimit))
        #expect(multibyte.count < 102_400)
        #expect(!ClipboardLimits.fits(multibyte), "102,402 bytes in 51,201 characters")
        #expect(try echo.decide(text(overLimit), at: start) == .skip(.tooLarge))
        #expect(try echo.decide(text(multibyte), at: start) == .skip(.tooLarge))
        guard case .send(_, .overTcp) = try echo.decide(text(atLimit), at: start) else {
            Issue.record("a clip at the limit goes over TCP")
            return
        }
    }

    @Test("clipboard-small while the plaintext fits 159 bytes, clipboard-set over TCP beyond")
    func encoding() throws {
        // {"t":"…","s":false} is 18 bytes around the text.
        let fits = String(repeating: "x", count: SignalFrame.maxPlaintextBytes - 18)
        let over = fits + "x"
        #expect(try Signal.clipboardSmall(text: fits, sensitive: false).plaintext().count == SignalFrame.maxPlaintextBytes)
        #expect(try ClipboardEncoding.plan(fits) == .small(.clipboardSmall(text: fits, sensitive: false)))
        #expect(try ClipboardEncoding.plan(over) == .overTcp(.clipboardSet(text: over, sensitive: false, announce: false)))
        #expect(try ClipboardEncoding.plan(fits).wireType == "clipboard-small")
        #expect(try ClipboardEncoding.plan(over).wireType == "clipboard-set")
        // JSON escaping counts: a quote costs two bytes in the plaintext.
        let quoted = String(repeating: "\"", count: 72)
        #expect(try ClipboardEncoding.plan(quoted) == .overTcp(.clipboardSet(text: quoted, sensitive: false, announce: false)))
    }

    @Test("an applied text is an echo while its tombstone lives, and unchanged after")
    func appliedEcho() throws {
        var echo = ClipboardEcho()
        echo.applied("from the phone", at: start)
        #expect(echo.liveTombstones(at: start) == 1)
        #expect(try echo.decide(text("from the phone"), at: start + .seconds(1)) == .skip(.echo))
        #expect(try echo.decide(text("from the phone"), at: start + ClipboardEcho.tombstoneLifetime) == .skip(.unchanged))
        #expect(echo.liveTombstones(at: start + ClipboardEcho.tombstoneLifetime) == 0)
        #expect(ClipboardEcho.tombstoneLifetime >= .seconds(5), "spec: at least 5 seconds")
    }

    @Test("the tombstone outlives a send in between; the last digest follows every crossing")
    func lastCrossed() throws {
        var echo = ClipboardEcho()
        echo.applied("A", at: start)
        echo.sent("B")
        #expect(try echo.decide(text("A"), at: start + .seconds(2)) == .skip(.echo), "still tombstoned")
        #expect(try echo.decide(text("B"), at: start + .seconds(2)) == .skip(.unchanged))
        #expect(try echo.decide(text("A"), at: start + .seconds(20)) == .send(text: "A", .small(.clipboardSmall(text: "A", sensitive: false))))
        echo.applied("C", at: start + .seconds(30))
        #expect(echo.liveTombstones(at: start + .seconds(30)) == 1, "the expired tombstone of A was pruned")
        #expect(try echo.decide(text("B"), at: start + .seconds(31)) == .send(text: "B", .small(.clipboardSmall(text: "B", sensitive: false))))
    }

    @Test("a new text goes out; the Mac never marks it sensitive or announced")
    func send() throws {
        let echo = ClipboardEcho()
        guard case .send(let sent, .small(let signal)) = try echo.decide(text("https://example.com"), at: start) else {
            Issue.record("expected a small clip")
            return
        }
        #expect(sent == "https://example.com")
        #expect(signal == .clipboardSmall(text: "https://example.com", sensitive: false))
        #expect(signal.allows(.macToPhone))
        #expect(!signal.allows(.phoneToMac))
    }

    @Test("the notice for a text sent from the phone carries no clip text")
    func notice() {
        let notice = LocalNotices.clipboardArrived
        #expect(notice.title == "Sent from your phone")
        #expect(notice.body.contains("⌘V"))
        #expect(notice.subtitle.isEmpty)
    }

    @Test("armed only with a signal path, and every arming is reported once")
    func sessionGate() {
        var script = Script()
        #expect(!script.machine.armed)
        #expect(script.machine.idle == .noSignalPath)
        #expect(ClipboardPublisherMachine.Idle.noSignalPath.rawValue == "no session or confirmed Bluetooth link")
        script.on(.screenUnlocked)
        #expect(script.last.isEmpty, "no session yet")
        script.on(.sessionStarted)
        #expect(script.last == [.arm])
        script.on(.sessionStarted)
        #expect(script.last.isEmpty, "already armed")
        script.on(.sessionEnded)
        #expect(script.last == [.disarm(.noSignalPath)])
        script.on(.sessionEnded)
        #expect(script.last.isEmpty, "nothing scheduled, nothing to tear down")
    }

    @Test("a replaced session disarms and arms again, which brings a fresh pass")
    func replacedSession() {
        var script = Script()
        script.on(.sessionStarted)
        script.on(.sessionEnded)
        script.on(.sessionStarted)
        #expect(script.effects == [[.arm], [.disarm(.noSignalPath)], [.arm]])
    }

    @Test("the confirmed Bluetooth link alone arms; a session arriving meanwhile brings one more pass")
    func bluetoothGate() {
        var script = Script()
        script.on(.bluetooth(linked: true))
        #expect(script.last == [.arm])
        script.on(.sessionStarted)
        #expect(script.last == [.pass], "a clip too large for a BLE frame waits for this")
        script.on(.sessionEnded)
        #expect(script.last.isEmpty, "the visit ends, the Bluetooth link stays")
        script.on(.bluetooth(linked: false))
        #expect(script.last == [.disarm(.noSignalPath)])
        script.on(.screenLocked)
        script.on(.bluetooth(linked: true))
        #expect(script.last.isEmpty, "locked")
        #expect(script.machine.idle == .screenLocked)
    }

    @Test("a clip that fits a BLE frame goes to the confirmed phone over GATT without a session; a larger one needs the session")
    func clipRoutes() throws {
        let gattOnly = SignalPaths(phonePayload: 244, summonPayload: 244, sessionUp: false)
        let small = try ClipboardEncoding.plan("short")
        #expect(try gattOnly.plan(small) == [.signal(.clipboardSmall(text: "short", sensitive: false), .gatt)])
        let large = try ClipboardEncoding.plan(String(repeating: "x", count: 200))
        #expect(try gattOnly.plan(large) == nil)
        let session = SignalPaths(sessionUp: true)
        #expect(try session.plan(large) == [.message(.clipboardSet(text: String(repeating: "x", count: 200), sensitive: false, announce: false))])
        #expect(try session.plan(small) == [.signal(.clipboardSmall(text: "short", sensitive: false), .tcp)])
        let stranger = SignalPaths(summonPayload: 244, sessionUp: false)
        #expect(try stranger.plan(small) == nil, "a clip never goes to a subscriber not confirmed")
    }

    @Test("locking and sleeping disarm; unlocking and waking arm again")
    func screenGate() {
        var script = Script()
        script.on(.sessionStarted)
        script.on(.screenLocked)
        #expect(script.last == [.disarm(.screenLocked)])
        script.on(.screenSlept)
        #expect(script.last.isEmpty)
        #expect(script.machine.idle == .screenAsleep)
        script.on(.screenWoke)
        #expect(script.last.isEmpty, "still locked")
        #expect(script.machine.idle == .screenLocked)
        script.on(.screenUnlocked)
        #expect(script.last == [.arm])
        #expect(ClipboardPublisherMachine.Idle.screenLocked.rawValue == "screen locked")
    }

    @Test("a locked Mac at launch stays idle when the phone connects")
    func lockedAtLaunch() {
        var machine = ClipboardPublisherMachine(screenAwake: true, unlocked: false)
        let connected = machine.handle(.sessionStarted)
        #expect(connected.isEmpty)
        #expect(machine.idle == .screenLocked)
        let unlocked = machine.handle(.screenUnlocked)
        #expect(unlocked == [.arm])
    }

    @Test("denied pasteboard access idles with its own reason and recovers")
    func accessDenied() {
        var script = Script()
        script.on(.access(denied: true))
        script.on(.sessionStarted)
        #expect(script.last.isEmpty)
        #expect(script.machine.idle == .accessDenied)
        #expect(ClipboardPublisherMachine.Idle.accessDenied.rawValue == "pasteboard access denied")
        script.on(.access(denied: false))
        #expect(script.last == [.arm])
        script.on(.access(denied: true))
        #expect(script.last == [.disarm(.accessDenied)])
    }
}
