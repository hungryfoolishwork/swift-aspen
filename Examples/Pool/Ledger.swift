import Foundation

actor Ledger {

    private(set) var snapshot: Snapshot

    private let url: URL

    struct Snapshot: Codable {
        var seq: UInt64 = 0
        var records: [String: Record] = [:]
        var peers: [String: Peer] = [:]
    }

    struct Record: Codable, Identifiable {
        let id: String
        var text: String
        let createdAt: Date
        var updatedAt: Date
    }

    struct Peer: Codable, Identifiable {
        var id: String
        var lastSeen: Date
    }

    init(baseURL: URL) {
        url = baseURL.appending(path: "snapshot.json")
        snapshot = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    var records: [Record] {
        snapshot.records.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    func records(matching prefix: String) -> [Record] {
        records.filter { $0.id.lowercased().hasPrefix(prefix.lowercased()) }
    }

    func add(_ text: String) -> Record {
        let record = Record(id: UUID().uuidString, text: text, createdAt: .now, updatedAt: .now)
        snapshot.records[record.id] = record
        snapshot.seq += 1
        save()
        return record
    }

    func update(id: String, text: String) -> Record? {
        guard var record = snapshot.records[id] else { return nil }
        record.text = text
        record.updatedAt = .now
        snapshot.records[id] = record
        snapshot.seq += 1
        save()
        return record
    }

    /// Union the incoming set into ours: unseen ids are inserted, known ids
    /// keep whichever edit is newer, with ties broken on text so every device
    /// resolves the same conflict the same way. seq bumps only when something
    /// actually changed — absorbing records is a state change the rest of the
    /// mesh hasn't heard yet.
    func merge(_ incoming: [String: Record], from peerId: String) -> Bool {
        var changed = false
        for (id, theirs) in incoming {
            guard let ours = snapshot.records[id] else {
                snapshot.records[id] = theirs
                changed = true
                continue
            }
            if (theirs.updatedAt, theirs.text) > (ours.updatedAt, ours.text) {
                snapshot.records[id] = theirs
                changed = true
            }
        }
        if changed { snapshot.seq += 1 }
        snapshot.peers[peerId] = .init(id: peerId, lastSeen: .now)
        save()
        return changed
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
