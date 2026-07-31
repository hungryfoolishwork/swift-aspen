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
        let body = try JSONEncoder().encode(env)
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        try await send.writeAll(buf: frame)
    }

    public static func read(from recv: RecvStream) async throws -> Envelope {
        let header = try await recv.readExact(size: 4)
        let len = header.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        guard len > 0, len <= maxFrame else { throw WireError.badFrame }
        let body = try await recv.readExact(size: len)
        return try JSONDecoder().decode(Envelope.self, from: body)
    }

    public enum WireError: Error { case badFrame }
}
