import Foundation
import IrohLib

/// What the app hands the node to send when a peer is behind: the current
/// state seq plus the envelope bodies that carry it. Every item goes out
/// stamped with `seq`.
public struct OutboundState: Sendable {
    public struct Item: Sendable {
        public var contentType: String
        public var payload: Data
        public init(contentType: String, payload: Data) {
            self.contentType = contentType
            self.payload = payload
        }
    }

    public var seq: UInt64
    public var items: [Item]
    public init(seq: UInt64, items: [Item]) {
        self.seq = seq
        self.items = items
    }
}

/// Owns the iroh Endpoint: accept loop for incoming syncs, deadline-bounded
/// outbound dials, and the hello → state-if-newer → bye exchange both sides
/// run on every contact. App-specific pieces are injected: the ALPN names
/// your protocol, `stateProvider` supplies what to send, and `on(_:_:)`
/// registers handlers per content type. Register all handlers before start().
public final class Node {
    public typealias StateProvider = @Sendable () async -> OutboundState
    public typealias Handler = @Sendable (Wire.Envelope, _ remote: String) async -> Void

    public let identity: Identity
    public let roster: Roster
    public let alpn: Data
    public let dialTimeout: Duration
    /// Optional diagnostics sink (accept-loop errors, ignored envelopes).
    public var log: (@Sendable (String) -> Void)?

    private let stateProvider: StateProvider
    private var handlers: [String: Handler] = [:]
    private var endpoint: Endpoint!

    public init(
        identity: Identity,
        roster: Roster,
        alpn: Data,
        dialTimeout: Duration = .seconds(5),
        stateProvider: @escaping StateProvider
    ) {
        self.identity = identity
        self.roster = roster
        self.alpn = alpn
        self.dialTimeout = dialTimeout
        self.stateProvider = stateProvider
    }

    public func on(_ contentType: String, _ handler: @escaping Handler) {
        handlers[contentType] = handler
    }

    public func start() async throws {
        endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),                     // n0's public relays + DNS discovery
            secretKey: identity.secretKey.toBytes(),
            alpns: [alpn]
        ))
        Task { await runAcceptLoop() }
    }

    // MARK: incoming

    private func runAcceptLoop() async {
        while true {
            guard let incoming = await endpoint.acceptNext() else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let accepting = try await incoming.accept()
                    guard try await accepting.alpn() == self.alpn else { return }
                    let conn = try await accepting.connect()
                    let bi = try await conn.acceptBi()
                    let remote = conn.remoteId().description
                    try await self.runSync(bi: bi, conn: conn, remote: remote, initiator: false)
                } catch {
                    self.log?("[accept] \(error)")
                }
            }
        }
    }

    // MARK: outgoing

    public func ping(_ peerId: String) async throws {
        let conn = try await dial(peerId)
        let bi = try await conn.openBi()
        try await runSync(bi: bi, conn: conn, remote: peerId, initiator: true)
    }

    private func dial(_ peerId: String) async throws -> Connection {
        let id = try EndpointId.fromString(s: peerId)
        // Cached addrs are hints: iroh tries them alongside discovery, which
        // makes LAN dials work even when DNS is slow, stale, or offline.
        let hints = await roster.peers[peerId]?.cachedAddrs ?? []
        let addr = EndpointAddr(id: id, relayUrl: nil, addresses: hints)
        let ep = endpoint!
        let alpn = self.alpn
        let deadline = dialTimeout
        return try await withThrowingTaskGroup(of: Connection.self) { group in
            group.addTask { try await ep.connect(addr: addr, alpn: alpn) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw DialError.timeout
            }
            let conn = try await group.next()!
            group.cancelAll()
            return conn
        }
    }

    public enum DialError: Error { case timeout }

    // MARK: sync exchange

    private func runSync(bi: BiStream, conn: Connection, remote: String, initiator: Bool) async throws {
        let send = bi.send()
        let recv = bi.recv()

        // One snapshot of app state for the whole exchange — seq and payloads
        // read together, so a concurrent state change can't tear them apart.
        let my = await stateProvider()

        // 1. Exchange hellos. Payload carries the cursor: "highest seq of YOURS I've seen."
        let myCursor = await roster.peers[remote]?.lastSeenSeq ?? 0
        try await Wire.write(Wire.Envelope(
            contentType: "sync/hello",
            sender: identity.endpointId,
            seq: my.seq,
            payload: try JSONEncoder().encode(myCursor)
        ), to: send)
        let theirHello = try await Wire.read(from: recv)
        let theirCursorOfMe = try JSONDecoder().decode(UInt64.self, from: theirHello.payload)

        // 2. Send state only if the peer is behind — this is the "pull updates" part.
        if my.seq > theirCursorOfMe {
            for item in my.items {
                try await Wire.write(Wire.Envelope(
                    contentType: item.contentType,
                    sender: identity.endpointId,
                    seq: my.seq,
                    payload: item.payload
                ), to: send)
            }
        }
        try await Wire.write(Wire.Envelope(
            contentType: "sync/bye", sender: identity.endpointId,
            seq: my.seq, payload: Data()
        ), to: send)
        try? await send.finish()  // FIN: nothing further on this stream

        // 3. Read their side until bye, dispatching on contentType.
        while true {
            let env = try await Wire.read(from: recv)
            if env.contentType == "sync/bye" { break }
            await handle(env, from: remote)
        }

        // 4. Contact bookkeeping: cursor floor from the hello, fresh addresses, timestamp.
        let paths = conn.paths().filter { $0.isIp }.map { $0.remoteAddr }
        await roster.update(remote) { rec in
            rec.lastSeenSeq = max(rec.lastSeenSeq, theirHello.seq)
            if !paths.isEmpty { rec.cachedAddrs = paths }
            rec.lastContact = Date()
        }

        // 5. Deterministic close. Dropping the Connection closes it immediately,
        //    and whoever finishes first would kill the other side's pending
        //    reads (ReadError(ConnectionLost)). So the close gets one owner:
        //    the acceptor closes once it has drained both directions, and the
        //    dialer parks the connection in a grace task instead of dropping
        //    it — the acceptor's close normally lands in milliseconds and the
        //    timer only fires if the peer vanished mid-exchange.
        if initiator {
            Task.detached {
                try? await Task.sleep(for: .seconds(3))
                try? conn.close(errorCode: 0, reason: Data())
            }
        } else {
            try? conn.close(errorCode: 0, reason: Data())
        }
    }

    private func handle(_ env: Wire.Envelope, from remote: String) async {
        let cursor = await roster.peers[remote]?.lastSeenSeq ?? 0
        guard env.seq > cursor else { return }  // stale
        guard let handler = handlers[env.contentType] else {
            log?("● \(remote.prefix(8)) → unknown contentType \(env.contentType), ignoring")
            return
        }
        await handler(env, remote)
        await roster.update(remote) { $0.lastSeenSeq = env.seq }
    }
}
