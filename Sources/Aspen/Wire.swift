import Foundation
import IrohLib

public enum Wire {
    public static let maxFrame: UInt32 = 1 << 20  // 1 MiB sanity cap

    public struct Envelope: Codable, Sendable {
        public let contentType: String   // app-defined, e.g. "state/status"
        public let sender: String        // hex EndpointId
        public let seq: UInt64           // sender's state sequence number
        public let payload: Data

        public init(contentType: String, sender: String, seq: UInt64, payload: Data) {
            self.contentType = contentType
            self.sender = sender
            self.seq = seq
            self.payload = payload
        }
    }

    public static func write(_ env: Envelope, to send: SendStream) async throws {
        try await send.writeAll(buf: encodeFrame(env))
    }

    public static func read(from recv: RecvStream) async throws -> Envelope {
        let len = try frameLength(header: try await recv.readExact(size: 4))
        let body = try await recv.readExact(size: len)
        return try JSONDecoder().decode(Envelope.self, from: body)
    }

    static func encodeFrame(_ env: Envelope) throws -> Data {
        let body = try JSONEncoder().encode(env)
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        return frame
    }

    static func frameLength(header: Data) throws -> UInt32 {
        let len = header.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        guard len > 0, len <= maxFrame else { throw WireError.badFrame }
        return len
    }

    public enum WireError: Error { case badFrame }
}
