import Foundation

/// The app-side state: one status string under a monotonically increasing
/// seq, persisted to state.json. Aspen never sees this type — it only gets
/// the seq and an encoded payload through the node's state provider.
actor StatusStore {
    struct State: Codable {
        var seq: UInt64 = 0
        var status: String = "(unset)"
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
        try? (try? JSONEncoder().encode(state))?.write(to: file, options: .atomic)
    }
}
