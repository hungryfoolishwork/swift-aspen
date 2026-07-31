import Foundation
import Observation
import Aspen

/// Owns the Aspen pieces and mirrors sync state into observable properties
/// for SwiftUI. A fresh Node is built on every start() — a stopped node
/// can't be restarted, and iOS tears down its sockets on suspend anyway —
/// while identity, roster, and statuses live on disk, so each new node
/// resumes exactly where the last one left off.
@Observable @MainActor
final class SyncManager {
    /// This app's protocol id — bump the suffix on breaking changes.
    static let alpn = Data("aspen-statusboard/0".utf8)

    struct Peer: Identifiable {
        let id: String  // endpoint id
        var status: String?
        var lastContact: Date?
    }

    let myId: String
    private(set) var myStatus = ""
    private(set) var peers: [Peer] = []
    private(set) var running = false

    private let identity: Identity
    private let roster: Roster
    private let store: StatusStore
    private var node: Node?
    private var sweepTask: Task<Void, Never>?

    init() throws {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("aspen", isDirectory: true)
        identity = try Identity.loadOrCreate(dir: dir)
        roster = Roster(dir: dir)
        store = StatusStore(dir: dir)
        myId = identity.endpointId
    }

    func start() async throws {
        guard node == nil else { return }
        myStatus = await store.state.status
        let store = store
        let node = Node(identity: identity, roster: roster, alpn: Self.alpn) {
            let s = await store.state
            let payload = (try? JSONEncoder().encode(s.status)) ?? Data()
            return OutboundState(seq: s.seq, items: [
                .init(contentType: "state/status", payload: payload)
            ])
        }
        await node.on("state/status") { [weak self] env, remote in
            guard let text = try? JSONDecoder().decode(String.self, from: env.payload) else { return }
            await store.setRemote(text, from: remote)
            await self?.refresh()
        }
        try await node.start()
        self.node = node
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

    func setStatus(_ text: String) async {
        await store.set(text)
        myStatus = text
        await sweep()  // contacts push as well as pull, so peers see this now
    }

    func addPeer(_ id: String) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != myId else { return }
        await roster.add(trimmed)
        await refresh()
        if let node { try? await node.ping(trimmed) }
        await refresh()
    }

    /// Contact every roster peer concurrently, like the CLI demo's sweep.
    func sweep() async {
        guard let node else { return }
        let ids = await Array(roster.peers.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { try? await node.ping(id) }
            }
        }
        await refresh()
    }

    private func refresh() async {
        let records = await roster.peers
        let remotes = await store.state.remotes
        peers = records.values
            .map { Peer(id: $0.endpointId, status: remotes[$0.endpointId], lastContact: $0.lastContact) }
            .sorted { $0.id < $1.id }
    }
}
