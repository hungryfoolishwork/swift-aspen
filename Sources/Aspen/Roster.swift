import Foundation

public struct PeerRecord: Codable, Sendable {
    public var endpointId: String
    public var cachedAddrs: [String] = []   // "ip:port" strings from the last successful contact
    public var lastSeenSeq: UInt64 = 0      // cursor: skip re-sending state the peer already has
    public var lastContact: Date? = nil
}

/// The peer list plus everything learned per contact: cached direct addresses
/// (dialing hints) and cursors. Persisted to roster.json in `dir`. An actor
/// because accept-side syncs and concurrent sweep dials mutate it at once.
public actor Roster {
    public let dir: URL
    public private(set) var peers: [String: PeerRecord]

    public init(dir: URL) {
        self.dir = dir
        let file = dir.appendingPathComponent("roster.json")
        self.peers = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: PeerRecord].self, from: $0) } ?? [:]
    }

    public func add(_ id: String) {
        guard peers[id] == nil else { return }
        peers[id] = PeerRecord(endpointId: id)
        save()
    }

    public func update(_ id: String, _ mutate: (inout PeerRecord) -> Void) {
        // Create if missing — an unknown peer dialing *us* is how the roster grows.
        var rec = peers[id] ?? PeerRecord(endpointId: id)
        mutate(&rec)
        peers[id] = rec
        save()
    }

    /// Forget a peer: stop dialing it and drop everything learned about it.
    /// Note the accept side re-adds any peer that dials *us* (see `update`),
    /// so removal only sticks while the removed peer doesn't call back.
    public func remove(_ id: String) {
        guard peers[id] != nil else { return }
        peers[id] = nil
        save()
    }

    private func save() {
        try? (try? JSONEncoder().encode(peers))?
            .write(to: dir.appendingPathComponent("roster.json"), options: .atomic)
    }
}
