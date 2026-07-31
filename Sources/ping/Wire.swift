import Foundation
import IrohLib

enum Wire {
    /// Version your protocol in the ALPN — bump the suffix on breaking changes
    /// and old/new peers simply won't complete a handshake with each other.
    static let alpn = Data("ping/0".utf8)
    static let maxFrame: UInt32 = 1 << 20  // 1 MiB sanity cap

    struct Envelope: Codable {
        let contentType: String   // "sync/hello", "state/status", "sync/bye"
        let sender: String        // hex EndpointId
        let seq: UInt64           // sender's state sequence number
        let payload: Data
    }

    static func write(_ env: Envelope, to send: SendStream) async throws {
        let body = try JSONEncoder().encode(env)
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        try await send.writeAll(buf: frame)
    }

    static func read(from recv: RecvStream) async throws -> Envelope {
        let header = try await recv.readExact(size: 4)
        let len = header.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        guard len > 0, len <= maxFrame else { throw WireError.badFrame }
        let body = try await recv.readExact(size: len)
        return try JSONDecoder().decode(Envelope.self, from: body)
    }

    enum WireError: Error { case badFrame }
}
