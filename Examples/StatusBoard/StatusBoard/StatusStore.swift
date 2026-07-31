import Foundation

/// The app-side state, persisted to state.json: my status string under a
/// monotonically increasing seq, plus the last status heard from each peer.
/// Remote statuses must persist too — Aspen's cursors mean a peer never
/// re-sends state this node has already seen, so anything dropped here is
/// gone until that peer next changes its status.
actor StatusStore {
    struct State: Codable {
        var seq: UInt64 = 0
        var status: String = ""
        var remotes: [String: String] = [:]  // peer endpoint id → last heard status
    }

    private let file: URL
    private(set) var state: State

    init(dir: URL) {
        file = dir.appendingPathComponent("state.json")
        state = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func set(_ s: String) {
        // seq bumps before assign: a peer holding seq N must see this as N+1.
        state.seq += 1
        state.status = s
        save()
    }

    func setRemote(_ s: String, from id: String) {
        state.remotes[id] = s
        save()
    }

    private func save() {
        try? (try? JSONEncoder().encode(state))?.write(to: file, options: .atomic)
    }
}
