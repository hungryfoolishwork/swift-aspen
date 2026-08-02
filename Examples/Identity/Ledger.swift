import Foundation

actor Ledger {

    private(set) var snapshot: Snapshot

    private let url: URL

    struct Snapshot: Codable {
        var seq: UInt64 = 0
        var state = State()
        var peers: [String: Peer] = [:]
    }

    struct Peer: Codable, Identifiable {
        var id: String
        var state: State
        var lastSeen: Date
    }

    struct State: Codable {
        var name = ""
        var root = ""
        var records: [String] = []
    }

    init(baseURL: URL) {
        url = baseURL.appending(path: "snapshot.json")
        snapshot = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    func set(state: State) {
        snapshot.seq += 1
        snapshot.state = state
        save()
    }

    func set(peer id: String, state: State) {
        snapshot.peers[id] = .init(id: id, state: state, lastSeen: .now)
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            print(error)
        }
    }
}
