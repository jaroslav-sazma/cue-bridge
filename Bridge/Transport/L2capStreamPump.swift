import CoreBluetooth
import Foundation
import os

nonisolated enum L2capPumpEvent: Sendable {
    case bytes(Data)
    case ended
    case failed(String)
}

// CoreBluetooth hands an L2CAP channel over as a pair of streams that report on a run loop. Each
// channel gets a thread that runs one while the channel is open and owns the streams: every read and
// write happens there. The server reaches it only through send, close and cancel, which the thread
// picks up on its next pass; what it reads goes out through `events` in order. Writes wait in memory
// and leave as fast as the stream takes them, so a frame of a megabyte never blocks the server.
// Nothing is reported for an end the server asked for.
nonisolated final class L2capStreamPump: NSObject, @unchecked Sendable {
    private enum Request {
        case idle
        case close
        case cancel
    }

    private static let readChunk = 16_384
    private static let deliveryBytes = 65_536

    let peer: UUID
    let psm: UInt16

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var outbox: [Data] = []
    private var request = Request.idle

    // The pump thread's own from start() on.
    private var channel: CBL2CAPChannel?
    private let input: InputStream
    private let output: OutputStream
    private var events: (@Sendable (L2capPumpEvent) -> Void)?
    private var writing: [Data] = []
    private var writtenOfFirst = 0
    private var closing = false
    private var finished = false

    init(channel: CBL2CAPChannel) {
        self.channel = channel
        peer = channel.peer.identifier
        psm = channel.psm
        input = channel.inputStream
        output = channel.outputStream
    }

    func start(events: @escaping @Sendable (L2capPumpEvent) -> Void) {
        self.events = events
        let thread = Thread { [self] in run() }
        thread.name = "app.cue.bridge.l2cap"
        thread.start()
    }

    // For a channel that is never started: its streams were never opened or scheduled.
    func refuse() {
        input.close()
        output.close()
        channel = nil
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        post { $0.outbox.append(data) }
    }

    // What is queued goes out first, then the channel closes.
    func close() {
        post { if $0.request == .idle { $0.request = .close } }
    }

    func cancel() {
        post { $0.request = .cancel }
    }

    private func post(_ change: (L2capStreamPump) -> Void) {
        lock.lock()
        change(self)
        let loop = runLoop
        lock.unlock()
        // Before the thread runs, it picks the change up itself; after it ended, the change is moot.
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in service() }
        CFRunLoopWakeUp(loop)
    }

    private func run() {
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        lock.unlock()
        for stream in [input, output] as [Stream] {
            stream.delegate = self
            stream.schedule(in: .current, forMode: .default)
            stream.open()
        }
        service()
        while !finished {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        lock.lock()
        runLoop = nil
        outbox = []
        lock.unlock()
    }

    private func service() {
        guard !finished else { return }
        lock.lock()
        let queued = outbox
        outbox = []
        let request = request
        lock.unlock()
        writing += queued
        switch request {
        case .cancel:
            finish()
            return
        case .close:
            closing = true
        case .idle:
            break
        }
        writePending()
    }

    private func writePending() {
        while let first = writing.first, output.hasSpaceAvailable {
            let written = first.withUnsafeBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                return output.write(bytes.baseAddress! + writtenOfFirst, maxLength: bytes.count - writtenOfFirst)
            }
            if written < 0 {
                end(.failed(output.streamError?.localizedDescription ?? "write failed"))
                return
            }
            if written == 0 { break }
            writtenOfFirst += written
            if writtenOfFirst == first.count {
                writing.removeFirst()
                writtenOfFirst = 0
            }
        }
        if closing, writing.isEmpty { finish() }
    }

    private func readAvailable() {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                if !collected.isEmpty { events?(.bytes(collected)) }
                end(.failed(input.streamError?.localizedDescription ?? "read failed"))
                return
            }
            if count == 0 { break }
            collected.append(buffer, count: count)
            if collected.count >= Self.deliveryBytes {
                events?(.bytes(collected))
                collected = Data()
            }
        }
        if !collected.isEmpty { events?(.bytes(collected)) }
    }

    private func end(_ event: L2capPumpEvent) {
        guard !finished else { return }
        finish()
        events?(event)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for stream in [input, output] as [Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
        writing = []
        channel = nil
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

nonisolated extension L2capStreamPump: StreamDelegate {
    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard !finished else { return }
        switch event {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            writePending()
        case .endEncountered:
            end(.ended)
        case .errorOccurred:
            end(.failed(stream.streamError?.localizedDescription ?? "stream error"))
        default:
            break
        }
    }
}
