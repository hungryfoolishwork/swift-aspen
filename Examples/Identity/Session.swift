import Foundation
import Observation
import Aspen

@Observable @MainActor
final class Session {

    let alpn = Data("example-identity/0".utf8)
    let id: String
    let ledger: Ledger

    // Instance observables
    private(set) var state = Ledger.State()
    private(set) var peers: [Ledger.Peer] = []
    private(set) var running = false

    // Who this session belongs to; signs the device cert carried in state.
    private(set) var root: Root

    // Iroh accounting
    private let identity: Aspen::Identity
    private let roster: Aspen::Roster
    private var node: Aspen::Node?

    private let dir: URL
    private var sweepTask: Task<Void, Never>?

    init(baseURL: URL) async throws {
        let url = baseURL.appending(path: "example-identity")
        self.dir = url
        self.ledger = Ledger(baseURL: url)
        self.root = try Root.loadOrCreate(dir: url)
        self.identity = try Identity.loadOrCreate(dir: url)
        self.roster = Roster(dir: url)
        self.id = identity.endpointId

        await ensureCert()
        await refresh()
    }

    func start() async throws {
        guard node == nil else { return }
        await refresh()

        let ledger = ledger
        let snapshot = await ledger.snapshot

        node = Aspen::Node(identity: identity, roster: roster, alpn: alpn) { _ in
            let payload = (try? JSONEncoder().encode(snapshot.state)) ?? Data()
            return Aspen::OutboundState(seq: snapshot.seq, items: [
                .init(contentType: "application/json+state", payload: payload)
            ])
        }
        await node?.on("application/json+state") { [weak self] envelope, peer in
            guard var state = try? JSONDecoder().decode(Ledger.State.self, from: envelope.payload) else {
                return
            }
            if let cert = state.cert, !cert.verifies(for: peer) {
                state.cert = nil  // a claim without proof: keep the records, drop the certification
            }
            await ledger.set(peer: peer, state: state)
            await self?.refresh()
        }
        
        try await node?.start()
        running = true
        await refresh()

        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweep()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() async {
        sweepTask?.cancel()
        sweepTask = nil
        await node?.stop()
        node = nil
        running = false
    }

    func set(state: Ledger.State) async {
        await ledger.set(state: state)
        self.state = state
        await sweep()
    }

    func add(remote endpointID: String) async {
        let trimmed = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != self.id else { return }
        await roster.add(trimmed)
        await refresh()
        if let node {
            try? await node.ping(trimmed)
        }
        await refresh()
    }

    /// Replace this device's root with one exported from another device and
    /// re-certify. Peers pick up the new cert on the next sync.
    func adopt(rootTransfer transfer: String) async throws {
        root = try Root.adopt(transfer, dir: dir)
        await ensureCert()
        await refresh()
    }

    /// Make sure the current state carries a valid certificate from the current
    /// root. Sign a new certificate if the state has none, or if it has a stale one,
    /// meaning it has a different device or different root.
    private func ensureCert() async {
        var state = await ledger.snapshot.state
        if let cert = state.cert, cert.root == root.publicKeyData, cert.verifies(for: id) {
            return
        }
        guard let cert = try? root.certify(device: id) else {
            return
        }
        state.cert = cert
        await ledger.set(state: state)
    }

    func knownPeers() async -> [String] {
        await Array(roster.peers.keys).sorted()
    }

    func sweep() async {
        guard let node else { return }
        let endpointIDs = await Array(roster.peers.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in endpointIDs {
                group.addTask { try? await node.ping(id) }
            }
        }
        await refresh()
    }

    private func refresh() async {
        let snapshot = await ledger.snapshot
        state = snapshot.state
        peers = snapshot.peers.values.sorted { $0.id < $1.id }
    }
}
