import Foundation

nonisolated enum TcpFrameError: Error, Equatable {
    case malformed(String)
}

nonisolated enum TcpFrameEvent: Equatable, Sendable {
    case message(BridgeMessage)
    case unknown(type: String)
}

nonisolated enum TcpFrame {
    static func encode(_ message: BridgeMessage) throws -> Data {
        let (body, sidecar) = try message.encodedBody()
        guard (1...BridgeProtocol.maxBodyBytes).contains(body.count) else {
            throw TcpFrameError.malformed("body size \(body.count)")
        }
        var frame = Data(capacity: 4 + body.count + (sidecar?.count ?? 0))
        frame.appendUInt32(UInt32(body.count))
        frame.append(body)
        if let sidecar { frame.append(sidecar) }
        return frame
    }
}

// A malformed frame ends the stream: after next() throws, the caller closes the connection and
// never reads on.
nonisolated struct TcpFrameDecoder {
    private var buffer = Data()

    var isEmpty: Bool { buffer.isEmpty }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() throws(TcpFrameError) -> TcpFrameEvent? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.uint32(at: 0))
        guard (1...BridgeProtocol.maxBodyBytes).contains(length) else {
            throw .malformed("length \(length)")
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
        guard String(validating: body, as: UTF8.self) != nil else { throw .malformed("body is not UTF-8") }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: body)
        } catch {
            throw .malformed("envelope")
        }
        var binaryBytes = 0
        if let declared = envelope.binaryBytes {
            guard (1...Int32(BridgeProtocol.maxBinaryBytes)).contains(declared) else {
                throw .malformed("binaryBytes \(declared)")
            }
            binaryBytes = Int(declared)
        }
        let total = 4 + length + binaryBytes
        guard buffer.count >= total else { return nil }
        let sidecar = binaryBytes > 0
            ? buffer.subdata(in: buffer.startIndex + 4 + length ..< buffer.startIndex + total)
            : nil
        buffer = Data(buffer.dropFirst(total))
        let message: BridgeMessage?
        do {
            message = try BridgeMessage.decode(type: envelope.type, body: body, sidecar: sidecar)
        } catch {
            throw .malformed("\(envelope.type) members")
        }
        guard let message else { return .unknown(type: envelope.type) }
        return .message(message)
    }

    func finish() throws(TcpFrameError) {
        guard buffer.isEmpty else { throw .malformed("stream ended inside a frame") }
    }

    private struct Envelope: Decodable {
        var type: String
        var binaryBytes: Int32?
    }
}
