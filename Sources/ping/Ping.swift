import Foundation

@main struct Ping {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)  // sync lines must land even when piped to a file
        var args = Array(CommandLine.arguments.dropFirst())
        let dir = takeDirFlag(&args)
        let identity = try Identity.loadOrCreate(dir: dir)
        let store = Store(dir: dir)

        switch args.first {
        case "id":
            print(identity.endpointId)
        case "add":
            guard let id = args.dropFirst().first else { fail("usage: ping add <endpoint-id>") }
            await store.addPeer(id)
            print("added \(id.prefix(8))…")
        case "status":
            await store.setStatus(args.dropFirst().joined(separator: " "))
            let seq = await store.myState.seq
            print("status set (seq \(seq))")
        case "run":
            let node = Node(identity: identity, store: store)
            try await node.start()
            let count = await store.peers.count
            print("ping \(identity.endpointId.prefix(8))… up, \(count) peers on roster")
            while true {
                let ids = await Array(store.peers.keys)   // snapshot: accept-side syncs
                await withTaskGroup(of: Void.self) { group in  // may grow the roster mid-sweep
                    for id in ids {                       // concurrent sweep: one dead
                        group.addTask { await node.ping(id) }  // peer can't stall the rest
                    }
                }
                try await Task.sleep(for: .seconds(30))
            }
        default:
            fail("usage: ping [--dir <path>] id | add <id> | status <text> | run")
        }
    }

    /// Pull `--dir <path>` out of the arg list; default to ~/.config/ping/.
    static func takeDirFlag(_ args: inout [String]) -> URL {
        if let i = args.firstIndex(of: "--dir"), i + 1 < args.count {
            let path = args.remove(at: i + 1)
            args.remove(at: i)
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ping")
    }

    static func fail(_ msg: String) -> Never { print(msg); exit(1) }
}
