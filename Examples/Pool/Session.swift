import Foundation
import Observation
import Aspen

@Observable @MainActor
final class Session {

    let alpn = Data("example-pool/0".utf8)
    let id: String
    let ledger: Ledger

    // Instance observables
    private(set) var records: [Ledger.Record] = []
    private(set) var peers: [Ledger.Peer] = []
    private(set) var running = false

    // Iroh accounting
    private let identity: Aspen::Identity
    private let roster: Aspen::Roster
    private var node: Aspen::Node?

    private var sweepTask: Task<Void, Never>?

    init(baseURL: URL) throws {
        let url = baseURL.appending(path: "example-pool")
        self.ledger = Ledger(baseURL: url)

        self.identity = try Identity.loadOrCreate(dir: url)
        self.roster = Roster(dir: url)
        self.id = identity.endpointId
    }

    func start() async throws {
        guard node == nil else { return }
        await refresh()

        let ledger = ledger

        // The ledger is read fresh on every exchange: one-shot commands
        // mutate state after start(), and what goes out must be the merged
        // set as of now, not as of startup.
        node = Aspen::Node(identity: identity, roster: roster, alpn: alpn) {
            let snapshot = await ledger.snapshot
            let payload = (try? JSONEncoder().encode(snapshot.records)) ?? Data()
            return Aspen::OutboundState(seq: snapshot.seq, items: [
                .init(contentType: "application/json+records", payload: payload)
            ])
        }
        await node?.on("application/json+records") { [weak self] envelope, peer in
            guard let records = try? JSONDecoder().decode([String: Ledger.Record].self, from: envelope.payload) else {
                return
            }
            let changed = await ledger.merge(records, from: peer)
            await self?.refresh()
            if changed {
                // A merge that grew the pool is news the rest of the roster
                // hasn't heard; relay it without holding this exchange open.
                Task { await self?.sweep() }
            }
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

    @discardableResult
    func add(text: String) async -> Ledger.Record {
        let record = await ledger.add(text)
        await refresh()
        await sweep()
        return record
    }

    @discardableResult
    func update(id: String, text: String) async -> Ledger.Record? {
        guard let record = await ledger.update(id: id, text: text) else { return nil }
        await refresh()
        await sweep()
        return record
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
        records = await ledger.records
        peers = snapshot.peers.values.sorted { $0.id < $1.id }
    }
}
