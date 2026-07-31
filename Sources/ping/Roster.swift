import Foundation

struct PeerRecord: Codable {
    var endpointId: String
    var cachedAddrs: [String] = []   // "ip:port" strings from the last successful contact
    var lastSeenSeq: UInt64 = 0      // cursor: skip re-sending state the peer already has
    var lastContact: Date? = nil
}

struct MyState: Codable {
    var seq: UInt64 = 0
    var status: String = "(unset)"
}

actor Store {
    let dir: URL
    private(set) var peers: [String: PeerRecord]
    private(set) var myState: MyState

    init(dir: URL) {
        self.dir = dir
        self.peers = Self.load(dir.appendingPathComponent("roster.json")) ?? [:]
        self.myState = Self.load(dir.appendingPathComponent("state.json")) ?? MyState()
    }

    func addPeer(_ id: String) {
        guard peers[id] == nil else { return }
        peers[id] = PeerRecord(endpointId: id)
        save()
    }

    func setStatus(_ s: String) {
        // seq bumps before assign: a peer holding seq N must see this as N+1.
        myState.seq += 1
        myState.status = s
        save()
    }

    func update(_ id: String, _ mutate: (inout PeerRecord) -> Void) {
        // Create if missing — an unknown peer dialing *us* is how B learns about A.
        var rec = peers[id] ?? PeerRecord(endpointId: id)
        mutate(&rec)
        peers[id] = rec
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        try? (try? enc.encode(peers))?
            .write(to: dir.appendingPathComponent("roster.json"), options: .atomic)
        try? (try? enc.encode(myState))?
            .write(to: dir.appendingPathComponent("state.json"), options: .atomic)
    }

    private static func load<T: Codable>(_ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
