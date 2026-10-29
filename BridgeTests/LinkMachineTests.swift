import Foundation
import Testing

private let pinnedIdle = LinkContext(isPinned: true, ceremony: .none, lastPairingModeExpired: false)
private let pinnedOpen = LinkContext(isPinned: true, ceremony: .open, lastPairingModeExpired: false)
private let unpinnedOpen = LinkContext(isPinned: false, ceremony: .open, lastPairingModeExpired: false)
private let hello = BridgeMessage.hello(version: BridgeProtocol.version)

private func machine(at stage: LinkStage) -> LinkMachine {
    var machine = LinkMachine()
    guard stage != .handshaking else { return machine }
    _ = machine.connection(.ready(hasPeerCertificate: true))
    switch stage {
    case .awaitingKind:
        _ = machine.received(hello, context: unpinnedOpen)
    case .session:
        _ = machine.received(hello, context: pinnedIdle)
    case .pairing, .pairingDone:
        _ = machine.received(hello, context: unpinnedOpen)
        _ = machine.received(.pairRequest(commit: "c"), context: unpinnedOpen)
        if stage == .pairingDone { machine.ceremonyEnded() }
    default:
        break
    }
    return machine
}

// #expect cannot take a mutating call, so every step goes through these.
private func received(_ message: BridgeMessage, at stage: LinkStage, _ context: LinkContext) -> (LinkStage, [LinkEffect]) {
    var link = machine(at: stage)
    let effects = link.received(message, context: context)
    return (link.stage, effects)
}

private func connection(_ event: LinkConnectionEvent) -> (LinkStage, [LinkEffect]) {
    var link = LinkMachine()
    let effects = link.connection(event)
    return (link.stage, effects)
}

@Suite("Link stages")
struct LinkMachineTests {
    @Test("the helper reaches every stage")
    func stages() {
        for stage: LinkStage in [.handshaking, .awaitingHello, .awaitingKind, .pairing, .pairingDone, .session] {
            #expect(machine(at: stage).stage == stage)
        }
        let pending = [LinkStage.handshaking, .awaitingHello, .awaitingKind, .pairing, .pairingDone, .session]
            .map(\.isPending)
        #expect(pending == [true, true, true, false, false, false])
    }

    @Test("TLS ready sends hello, arms the step timer and starts reading")
    func ready() {
        let (stage, effects) = connection(.ready(hasPeerCertificate: true))
        #expect(stage == .awaitingHello)
        #expect(effects == [.send(hello), .armStepTimer, .startReceiving])
    }

    @Test("connection events: no certificate and waiting close, failed and cancelled detach")
    func connectionEvents() {
        #expect(connection(.ready(hasPeerCertificate: false)) == (.handshaking, [.close(.noPeerCertificate)]))
        #expect(connection(.waiting).1 == [.close(.connectionWaiting)])
        #expect(connection(.failed).1 == [.detach])
        #expect(connection(.cancelled).1 == [.detach])
    }

    @Test("data before TLS is ready closes")
    func dataBeforeTls() {
        #expect(received(hello, at: .handshaking, pinnedIdle).1 == [.close(.dataBeforeTls)])
    }

    @Test("the first frame must be hello")
    func notHello() {
        #expect(received(.syncRequest, at: .awaitingHello, pinnedIdle).1 == [.close(.notHello(type: "sync-request"))])
    }

    @Test("an unknown type before hello closes like any first frame that is not hello; after it, it is ignored")
    func unknownType() throws {
        var decoder = TcpFrameDecoder()
        let body = Data(#"{"type":"from-the-future","x":1}"#.utf8)
        var frame = Data()
        frame.appendUInt32(UInt32(body.count))
        frame.append(body)
        decoder.append(frame)
        let event = try decoder.next()
        #expect(event == .unknown(type: "from-the-future"))
        #expect(machine(at: .awaitingHello).receivedUnknown(type: "from-the-future") == [
            .close(.notHello(type: "from-the-future")),
        ])
        #expect(machine(at: .handshaking).receivedUnknown(type: "x") == [.close(.dataBeforeTls)])
        for stage: LinkStage in [.awaitingKind, .pairing, .pairingDone, .session] {
            #expect(machine(at: stage).receivedUnknown(type: "from-the-future").isEmpty, "\(stage)")
        }
    }

    @Test("a different version gets bye version-mismatch")
    func versionMismatch() {
        #expect(received(.hello(version: 2), at: .awaitingHello, pinnedIdle).1 == [
            .cancelStepTimer, .send(.bye(reason: BridgeMessage.versionMismatch)), .close(.versionMismatch(peer: 2)),
        ])
    }

    @Test("a pinned peer outside pairing mode is a session right after hello")
    func pinnedSession() {
        let (stage, effects) = received(hello, at: .awaitingHello, pinnedIdle)
        #expect(stage == .session)
        #expect(effects == [.cancelStepTimer, .establishSession])
    }

    @Test("in pairing mode, or unpinned, the kind waits for the first message")
    func awaitingKind() {
        for context in [
            unpinnedOpen, pinnedOpen, LinkContext(isPinned: false, ceremony: .none, lastPairingModeExpired: false),
        ] {
            let (stage, effects) = received(hello, at: .awaitingHello, context)
            #expect(stage == .awaitingKind)
            #expect(effects == [.cancelStepTimer, .armStepTimer])
        }
    }

    @Test("pair-request in open pairing mode makes a pairing connection that feeds the ceremony")
    func pairRequest() {
        let (stage, effects) = received(.pairRequest(commit: "c"), at: .awaitingKind, unpinnedOpen)
        #expect(stage == .pairing)
        #expect(effects == [.cancelStepTimer, .beginPairing(commit: "c")])
        let confirm = BridgeMessage.pairConfirm(proof: "p")
        #expect(received(confirm, at: .pairing, unpinnedOpen).1 == [.toCeremony(confirm)])
    }

    @Test("pair-request outside pairing mode aborts: timeout after expiry, cancelled otherwise, busy while busy")
    func pairRequestOutsidePairingMode() {
        let request = BridgeMessage.pairRequest(commit: "c")
        let expired = LinkContext(isPinned: false, ceremony: .none, lastPairingModeExpired: true)
        #expect(received(request, at: .awaitingKind, expired).1 == [
            .cancelStepTimer, .send(.pairAbort(.timeout)), .close(.notInPairingMode),
        ])
        #expect(received(request, at: .awaitingKind, pinnedIdle).1 == [
            .cancelStepTimer, .send(.pairAbort(.cancelled)), .close(.notInPairingMode),
        ])
        let busy = LinkContext(isPinned: false, ceremony: .busy, lastPairingModeExpired: false)
        #expect(received(request, at: .awaitingKind, busy).1 == [
            .cancelStepTimer, .send(.pairAbort(.busy)), .close(.busy),
        ])
    }

    @Test("another first message makes a session for a pinned peer and is handled in it")
    func firstMessageSession() {
        let set = BridgeMessage.activeSet(notifications: [])
        let (stage, effects) = received(set, at: .awaitingKind, pinnedOpen)
        #expect(stage == .session)
        #expect(effects == [.cancelStepTimer, .establishSession, .toSession(set)])
        #expect(received(set, at: .awaitingKind, unpinnedOpen).1 == [.cancelStepTimer, .close(.unpinnedSession)])
        #expect(received(.syncRequest, at: .awaitingKind, pinnedOpen).1 == [
            .cancelStepTimer, .establishSession, .close(.protocolError(type: "sync-request")),
        ])
    }

    @Test("a session routes the phone's messages, closes on bye and on any other message")
    func session() {
        for message: BridgeMessage in [
            .activeSet(notifications: []), .signal(frame: "AA=="), .iconData(hash: "h", png: Data([1])),
            .clipboardSet(text: "t", sensitive: false, announce: false),
        ] {
            #expect(received(message, at: .session, pinnedIdle) == (.session, [.toSession(message)]))
        }
        #expect(received(.bye(reason: nil), at: .session, pinnedIdle).1 == [.close(.bye)])
        for message: BridgeMessage in [
            hello, .pairRequest(commit: "c"), .pairResponse(publicKey: "pk"), .pairReveal(publicKey: "pk"),
            .pairConfirm(proof: "p"), .pairAbort(reason: "x"),
            .syncRequest, .iconGet(hash: "h"), .replyText(key: "k", text: "t"),
        ] {
            #expect(received(message, at: .session, pinnedIdle).1 == [.close(.protocolError(type: message.type))])
        }
    }

    @Test("a Send to Mac connection carries hello, one clipboard-set and bye, and never an active-set")
    func oneShotClipboard() {
        let clip = BridgeMessage.clipboardSet(text: "t", sensitive: false, announce: true)
        for context in [pinnedIdle, pinnedOpen] {
            var link = LinkMachine()
            _ = link.connection(.ready(hasPeerCertificate: true))
            let opened = link.received(hello, context: context)
            let delivered = link.received(clip, context: context)
            let closed = link.received(.bye(reason: nil), context: context)
            if context.ceremony == .none {
                #expect(opened == [.cancelStepTimer, .establishSession])
                #expect(delivered == [.toSession(clip)])
            } else {
                #expect(opened == [.cancelStepTimer, .armStepTimer])
                #expect(delivered == [.cancelStepTimer, .establishSession, .toSession(clip)])
            }
            #expect(closed == [.close(.bye)])
            #expect(link.stage == .session)
        }
    }

    @Test("after the ceremony only bye matters")
    func pairingDone() {
        #expect(received(.activeSet(notifications: []), at: .pairingDone, pinnedIdle).1.isEmpty)
        #expect(received(.bye(reason: nil), at: .pairingDone, pinnedIdle).1 == [.close(.bye)])
    }

    @Test("a step timer closes its own stage, with pair-abort where a ceremony may be waiting")
    func stepTimer() {
        #expect(machine(at: .handshaking).stepExpired(armedIn: .handshaking, ceremonyPresent: true) == [
            .close(.stepTimeout(.handshaking)),
        ])
        #expect(machine(at: .awaitingHello).stepExpired(armedIn: .awaitingHello, ceremonyPresent: false) == [
            .close(.stepTimeout(.awaitingHello)),
        ])
        #expect(machine(at: .awaitingHello).stepExpired(armedIn: .awaitingHello, ceremonyPresent: true) == [
            .send(.pairAbort(.timeout)), .close(.stepTimeout(.awaitingHello)),
        ])
        #expect(machine(at: .awaitingKind).stepExpired(armedIn: .awaitingKind, ceremonyPresent: false) == [
            .send(.pairAbort(.timeout)), .close(.stepTimeout(.awaitingKind)),
        ])
        #expect(machine(at: .session).stepExpired(armedIn: .awaitingHello, ceremonyPresent: true).isEmpty, "stale")
    }
}

@Suite("Session slots")
struct SessionSlotsTests {
    @Test("a new TCP connection past eight in their handshake closes the oldest instead of being refused")
    func tcpEviction() {
        let seven = (1...7).map { (id: $0, source: "10.0.0.\($0)") }
        #expect(SessionSlots.evictedByNewTcpConnection(from: "10.0.0.9", pending: seven).isEmpty)
        let eight = (1...8).map { (id: $0, source: "10.0.0.\($0)") }
        #expect(SessionSlots.evictedByNewTcpConnection(from: "10.0.0.9", pending: eight.reversed()) == [1])
        let crowded = (1...10).map { (id: $0, source: "10.0.0.\($0)") }
        #expect(SessionSlots.evictedByNewTcpConnection(from: "10.0.0.11", pending: crowded) == [1, 2, 3])
    }

    @Test("one address holds at most three connections in their handshake and only ever pushes out its own")
    func tcpPerSource() {
        let attacker = "192.168.1.66"
        let two = [(id: 4, source: attacker), (id: 2, source: attacker)]
        #expect(SessionSlots.evictedByNewTcpConnection(from: attacker, pending: two).isEmpty)
        let three = two + [(id: 9, source: attacker), (id: 1, source: "192.168.1.20")]
        #expect(SessionSlots.evictedByNewTcpConnection(from: attacker, pending: three) == [2], "its own oldest, not the phone's")
        #expect(SessionSlots.evictedByNewTcpConnection(from: "192.168.1.20", pending: three).isEmpty)
        var full = (1...5).map { (id: $0, source: "10.0.0.\($0)") }
        full += [(id: 6, source: attacker), (id: 7, source: attacker), (id: 8, source: attacker)]
        #expect(SessionSlots.evictedByNewTcpConnection(from: attacker, pending: full) == [6], "its share makes room before the cap is reached")
        #expect(SessionSlots.evictedByNewTcpConnection(from: "10.0.0.9", pending: full) == [1])
    }

    @Test("a new Bluetooth channel past two in their handshake closes the oldest instead of being refused")
    func l2capEviction() {
        #expect(SessionSlots.evictedByNewL2capChannel(unauthenticated: []).isEmpty)
        #expect(SessionSlots.evictedByNewL2capChannel(unauthenticated: [4]).isEmpty)
        #expect(SessionSlots.evictedByNewL2capChannel(unauthenticated: [9, 4]) == [4])
        #expect(SessionSlots.evictedByNewL2capChannel(unauthenticated: [7, 3, 5]) == [3, 5])
    }

    @Test("a new session supersedes the old one, which is released before the new one binds")
    func replacement() {
        var slots = SessionSlots()
        #expect(slots.superseded(by: 1) == nil)
        slots.bindSession(1)
        #expect(slots.superseded(by: 1) == nil)
        #expect(slots.superseded(by: 2) == 1)
        let old = slots.detach(1)
        slots.bindSession(2)
        let unrelated = slots.detach(3)
        #expect(slots.session == 2)
        let new = slots.detach(2)
        #expect(old == .session && unrelated == [] && new == .session)
        #expect(slots.session == nil)
    }

    @Test("the ceremony link reports its loss and is released when the ceremony ends")
    func ceremony() {
        var slots = SessionSlots()
        slots.bindCeremony(4)
        let lost = slots.detach(4)
        let released = slots.releaseCeremony()
        let again = slots.releaseCeremony()
        #expect(lost == .ceremony && released == 4 && again == nil)
    }

    @Test("pair-request closes the other pending connections that are not pinned")
    func pairingModeTaken() {
        let links: [(id: Int, stage: LinkStage, isPinned: Bool)] = [
            (1, .awaitingKind, false), (2, .handshaking, false), (3, .awaitingHello, true), (4, .session, false),
            (5, .awaitingKind, false),
        ]
        #expect(SessionSlots.closedByPairRequest(on: 1, links: links) == [2, 5])
    }
}

@Suite("Bonjour TXT")
struct BonjourTxtTests {
    @Test("the TXT record carries the version always and the pairing flag only in pairing mode")
    func pairingFlag() {
        #expect(BonjourTxt.entries(pairingMode: false) == ["v": "1"])
        #expect(BonjourTxt.entries(pairingMode: true) == ["v": "1", "pair": "1"])
        #expect(BonjourTxt.entries(pairingMode: false) == ["v": String(BridgeProtocol.version)])
    }
}
