import Foundation

nonisolated enum LinkStage: Equatable, Sendable {
    case handshaking
    case awaitingHello
    case awaitingKind
    case pairing
    case pairingDone
    case session

    var isPending: Bool {
        self == .handshaking || self == .awaitingHello || self == .awaitingKind
    }
}

nonisolated enum LinkTransport: String, Equatable, Sendable {
    case tcp
    case l2cap
}

// `open` is pairing mode waiting for its first pair-request; `busy` a ceremony that took it.
nonisolated enum CeremonyState: Equatable, Sendable {
    case none
    case open
    case busy
}

nonisolated struct LinkContext: Equatable, Sendable {
    var isPinned: Bool
    var ceremony: CeremonyState
    var lastPairingModeExpired: Bool
}

nonisolated enum LinkCloseReason: Equatable, Sendable {
    case noPeerCertificate
    case connectionWaiting
    case dataBeforeTls
    case notHello(type: String)
    case versionMismatch(peer: Int)
    case unpinnedSession
    case notInPairingMode
    case busy
    case protocolError(type: String)
    case bye
    case stepTimeout(LinkStage)
}

nonisolated enum LinkEffect: Equatable, Sendable {
    case send(BridgeMessage)
    case armStepTimer
    case cancelStepTimer
    case startReceiving
    case establishSession
    case beginPairing(commit: String)
    case toCeremony(BridgeMessage)
    case toSession(BridgeMessage)
    case close(LinkCloseReason)
    case detach
}

nonisolated enum LinkConnectionEvent: Equatable, Sendable {
    case ready(hasPeerCertificate: Bool)
    case failed
    case waiting
    case cancelled
}

// One connection's stages as a pure machine: the caller owns the connection, its step timer and
// the server's slots, and carries out the returned effects in order. `.armStepTimer` arms the
// timer for the stage the machine is in once the effects are returned.
// On L2CAP, `.ready` stands for the first record that opened under the pairing's key, the
// counterpart of the pinned TLS handshake. Pairing never runs there, so the connection is a session
// from its hello on, in pairing mode too, and a pair-request on it is a protocol error.
nonisolated struct LinkMachine: Equatable, Sendable {
    // Every wait for the peer's next step, the L2CAP handshake's two included.
    static let stepTimeout = Duration.seconds(15)

    let transport: LinkTransport
    private(set) var stage = LinkStage.handshaking

    init(transport: LinkTransport = .tcp) {
        self.transport = transport
    }

    mutating func connection(_ event: LinkConnectionEvent) -> [LinkEffect] {
        switch event {
        case .ready(let hasPeerCertificate):
            guard hasPeerCertificate else { return [.close(.noPeerCertificate)] }
            stage = .awaitingHello
            return [.send(.hello(version: BridgeProtocol.version)), .armStepTimer, .startReceiving]
        case .failed, .cancelled:
            return [.detach]
        case .waiting:
            return [.close(.connectionWaiting)]
        }
    }

    mutating func received(_ message: BridgeMessage, context: LinkContext) -> [LinkEffect] {
        switch stage {
        case .handshaking:
            return [.close(.dataBeforeTls)]
        case .awaitingHello:
            return receivedHello(message, context: context)
        case .awaitingKind:
            return receivedFirst(message, context: context)
        case .pairing:
            return [.toCeremony(message)]
        case .pairingDone:
            if case .bye = message { return [.close(.bye)] }
            return []
        case .session:
            return Self.inSession(message)
        }
    }

    // Spec, Connections: the first frame must be hello, so an unknown type before it is malformed.
    // After it an unknown type is ignored, which is what lets a peer add message types.
    func receivedUnknown(type: String) -> [LinkEffect] {
        switch stage {
        case .handshaking: [.close(.dataBeforeTls)]
        case .awaitingHello: [.close(.notHello(type: type))]
        case .awaitingKind, .pairing, .pairingDone, .session: []
        }
    }

    mutating func ceremonyEnded() {
        stage = .pairingDone
    }

    // A timer armed in an earlier stage is stale and does nothing.
    func stepExpired(armedIn armed: LinkStage, ceremonyPresent: Bool) -> [LinkEffect] {
        guard stage == armed else { return [] }
        if transport == .tcp, armed == .awaitingKind || (armed == .awaitingHello && ceremonyPresent) {
            return [.send(.pairAbort(.timeout)), .close(.stepTimeout(armed))]
        }
        return [.close(.stepTimeout(armed))]
    }

    private mutating func receivedHello(_ message: BridgeMessage, context: LinkContext) -> [LinkEffect] {
        guard case .hello(let version, _) = message else { return [.close(.notHello(type: message.type))] }
        guard version == BridgeProtocol.version else {
            return [
                .cancelStepTimer, .send(.bye(reason: BridgeMessage.versionMismatch)),
                .close(.versionMismatch(peer: version)),
            ]
        }
        if context.isPinned, context.ceremony == .none || transport == .l2cap {
            stage = .session
            return [.cancelStepTimer, .establishSession]
        }
        guard transport == .tcp else { return [.cancelStepTimer, .close(.unpinnedSession)] }
        stage = .awaitingKind
        return [.cancelStepTimer, .armStepTimer]
    }

    private mutating func receivedFirst(_ message: BridgeMessage, context: LinkContext) -> [LinkEffect] {
        if case .pairRequest(let commit) = message {
            switch context.ceremony {
            case .open:
                stage = .pairing
                return [.cancelStepTimer, .beginPairing(commit: commit)]
            case .busy:
                return [.cancelStepTimer, .send(.pairAbort(.busy)), .close(.busy)]
            case .none:
                return [
                    .cancelStepTimer, .send(.pairAbort(context.lastPairingModeExpired ? .timeout : .cancelled)),
                    .close(.notInPairingMode),
                ]
            }
        }
        guard context.isPinned else { return [.cancelStepTimer, .close(.unpinnedSession)] }
        stage = .session
        return [.cancelStepTimer, .establishSession] + Self.inSession(message)
    }

    private static func inSession(_ message: BridgeMessage) -> [LinkEffect] {
        switch message {
        case .bye:
            [.close(.bye)]
        case .activeSet, .signal, .notifDetail, .iconData, .clipboardSet:
            [.toSession(message)]
        case .hello, .pairRequest, .pairResponse, .pairReveal, .pairConfirm, .pairAbort, .syncRequest, .iconGet,
             .replyText:
            [.close(.protocolError(type: message.type))]
        }
    }
}

// Which connection holds the session and which the ceremony. A new session supersedes the old one:
// the caller closes the superseded connection, which releases its slot, and binds the new one
// after that.
nonisolated struct SessionSlots: Equatable, Sendable {
    struct Release: OptionSet, Sendable {
        let rawValue: Int
        static let session = Release(rawValue: 1)
        static let ceremony = Release(rawValue: 2)
    }

    static let maxPendingConnections = 8
    static let maxPendingPerSource = 3
    static let maxPendingL2capChannels = 2

    private(set) var session: Int?
    private(set) var ceremony: Int?

    // TCP connections not yet past their handshake: a new one is never refused, the oldest makes room
    // instead — first among those from the same address, so one address holds at most its share and
    // cannot push out anyone else's, then among all of them. Link ids rise, so the oldest is the lowest.
    static func evictedByNewTcpConnection(from source: String, pending: [(id: Int, source: String)]) -> [Int] {
        let sameSource = pending.filter { $0.source == source }.map(\.id).sorted()
        let evicted = Set(sameSource.dropLast(maxPendingPerSource - 1))
        let rest = pending.map(\.id).filter { !evicted.contains($0) }.sorted()
        return (evicted.union(rest.dropLast(maxPendingConnections - 1))).sorted()
    }

    // Bluetooth channels not yet past their handshake have a cap of their own, so a device in radio
    // range cannot take the TCP slots; a new channel is never refused for it, the oldest one makes room
    // instead, so the phone's own channel always gets in. Link ids rise, so the oldest is the lowest.
    static func evictedByNewL2capChannel(unauthenticated ids: [Int]) -> [Int] {
        Array(ids.sorted().dropLast(maxPendingL2capChannels - 1))
    }

    func superseded(by id: Int) -> Int? {
        guard let session, session != id else { return nil }
        return session
    }

    mutating func bindSession(_ id: Int) {
        session = id
    }

    mutating func bindCeremony(_ id: Int) {
        ceremony = id
    }

    mutating func releaseCeremony() -> Int? {
        defer { ceremony = nil }
        return ceremony
    }

    mutating func detach(_ id: Int) -> Release {
        var released: Release = []
        if session == id {
            session = nil
            released.insert(.session)
        }
        if ceremony == id { released.insert(.ceremony) }
        return released
    }

    // The first pair-request takes pairing mode: every other pending connection that could still
    // become a pairing one is closed, told `busy` if it is past its handshake.
    static func closedByPairRequest(
        on id: Int, links: [(id: Int, stage: LinkStage, isPinned: Bool)]
    ) -> [Int] {
        links.filter { $0.id != id && $0.stage.isPending && !$0.isPinned }.map(\.id).sorted()
    }
}
