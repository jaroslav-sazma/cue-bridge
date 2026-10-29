import Foundation
import Testing

@Suite("messages.json")
struct MessageVectorTests {
    @Test("the version and limits match the Swift constants")
    func limits() throws {
        let file = try #require(Vectors.messages)
        #expect(file.bridgeProtocolVersion == BridgeProtocol.version)
        #expect(file.maxBodyBytes == BridgeProtocol.maxBodyBytes)
        #expect(file.maxBinaryBytes == BridgeProtocol.maxBinaryBytes)
    }

    @Test(arguments: Vectors.messages?.examples ?? [])
    func example(_ example: MessagesFile.Example) throws {
        var decoder = TcpFrameDecoder()
        decoder.append(Data(vectorHex: example.frame))
        let event = try decoder.next()
        try decoder.finish()
        guard case .message(let message) = event else {
            Issue.record("expected a message, got \(String(describing: event))")
            return
        }
        #expect(message.type == example.type)
        if let binary = example.binary {
            #expect(message == .iconData(hash: Self.hash(of: example.body), png: Data(vectorHex: binary)))
        }

        let encoded = try TcpFrame.encode(message)
        let (body, sidecar) = try message.encodedBody()
        #expect(Int(encoded.uint32(at: 0)) == body.count)
        #expect(body.count == example.body.utf8.count)
        #expect(sidecar?.hex == example.binary)
        #expect(try Self.object(body) == Self.object(Data(example.body.utf8)))

        var roundTrip = TcpFrameDecoder()
        roundTrip.append(encoded)
        #expect(try roundTrip.next() == .message(message))
    }

    @Test(arguments: Vectors.messages?.streams ?? [])
    func stream(_ vector: MessagesFile.Stream) {
        let bytes = Data(vectorHex: vector.stream)
        #expect(Self.outcomes(bytes, chunk: max(bytes.count, 1)) == vector.expect, "whole stream")
        #expect(Self.outcomes(bytes, chunk: 1) == vector.expect, "one byte at a time")
    }

    private static func outcomes(_ bytes: Data, chunk: Int) -> [MessagesFile.Expectation] {
        var decoder = TcpFrameDecoder()
        var results: [MessagesFile.Expectation] = []
        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunk, bytes.count)
                decoder.append(bytes.subdata(in: offset ..< end))
                offset = end
                while let event = try decoder.next() {
                    switch event {
                    case .message(let message): results.append(.init(result: "message", type: message.type))
                    case .unknown(let type): results.append(.init(result: "ignore", type: type))
                    }
                }
            }
            try decoder.finish()
        } catch {
            results.append(.init(result: "reject", type: nil))
        }
        return results
    }

    private static func object(_ data: Data) throws -> NSDictionary? {
        try JSONSerialization.jsonObject(with: data) as? NSDictionary
    }

    private static func hash(of body: String) -> String {
        ((try? object(Data(body.utf8)))?["hash"] as? String) ?? ""
    }
}
