import Foundation
import IrohLib

final class Node {
    let identity: Identity
    let store: Store
    private var endpoint: Endpoint!

    init(identity: Identity, store: Store) {
        self.identity = identity
        self.store = store
    }

    func start() async throws {
        endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),                     // n0's public relays + DNS discovery
            secretKey: identity.secretKey.toBytes(),
            alpns: [Wire.alpn]
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
                    guard try await accepting.alpn() == Wire.alpn else { return }
                    let conn = try await accepting.connect()
                    let bi = try await conn.acceptBi()
                    let remote = conn.remoteId().description
                    try await self.runSync(bi: bi, conn: conn, remote: remote, initiator: false)
                } catch {
                    print("[accept] \(error)")
                }
            }
        }
    }

    // MARK: outgoing

    func ping(_ peerId: String) async {
        do {
            let conn = try await dial(peerId)
            let bi = try await conn.openBi()
            try await runSync(bi: bi, conn: conn, remote: peerId, initiator: true)
        } catch {
            print("[ping \(peerId.prefix(8))] failed: \(error)")
        }
    }

    private func dial(_ peerId: String) async throws -> Connection {
        let id = try EndpointId.fromString(s: peerId)
        // Cached addrs are hints: iroh tries them alongside discovery, which
        // makes LAN dials work even when DNS is slow, stale, or offline.
        let hints = await store.peers[peerId]?.cachedAddrs ?? []
        let addr = EndpointAddr(id: id, relayUrl: nil, addresses: hints)
        let ep = endpoint!
        return try await withThrowingTaskGroup(of: Connection.self) { group in
            group.addTask { try await ep.connect(addr: addr, alpn: Wire.alpn) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw DialError.timeout
            }
            let conn = try await group.next()!
            group.cancelAll()
            return conn
        }
    }

    enum DialError: Error { case timeout }

    // MARK: sync exchange

    private func runSync(bi: BiStream, conn: Connection, remote: String, initiator: Bool) async throws {
        let send = bi.send()
        let recv = bi.recv()

        // One snapshot of my state for the whole exchange — seq and status read
        // together, so a concurrent `status` command can't tear them apart.
        let my = await store.myState

        // 1. Exchange hellos. Payload carries the cursor: "highest seq of YOURS I've seen."
        let myCursor = await store.peers[remote]?.lastSeenSeq ?? 0
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
            try await Wire.write(Wire.Envelope(
                contentType: "state/status",
                sender: identity.endpointId,
                seq: my.seq,
                payload: try JSONEncoder().encode(my.status)
            ), to: send)
        }
        try await Wire.write(Wire.Envelope(
            contentType: "sync/bye", sender: identity.endpointId,
            seq: my.seq, payload: Data()
        ), to: send)

        // 3. Read their side until bye, dispatching on contentType.
        while true {
            let env = try await Wire.read(from: recv)
            if env.contentType == "sync/bye" { break }
            await handle(env, from: remote)
        }

        // 4. Contact bookkeeping: cursor floor from the hello, fresh addresses, timestamp.
        let paths = conn.paths().filter { $0.isIp }.map { $0.remoteAddr }
        await store.update(remote) { rec in
            rec.lastSeenSeq = max(rec.lastSeenSeq, theirHello.seq)
            if !paths.isEmpty { rec.cachedAddrs = paths }
            rec.lastContact = Date()
        }
    }

    private func handle(_ env: Wire.Envelope, from remote: String) async {
        let cursor = await store.peers[remote]?.lastSeenSeq ?? 0
        guard env.seq > cursor else { return }  // stale
        switch env.contentType {
        case "state/status":
            let status = (try? JSONDecoder().decode(String.self, from: env.payload)) ?? "?"
            print("● \(remote.prefix(8)) → seq \(env.seq): \(status)")
            await store.update(remote) { $0.lastSeenSeq = env.seq }
        default:
            print("● \(remote.prefix(8)) → unknown contentType \(env.contentType), ignoring")
        }
    }
}
