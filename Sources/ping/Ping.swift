import Foundation
import Aspen

@main struct Ping {
    /// This app's protocol id — bump the suffix on breaking changes.
    static let alpn = Data("ping/0".utf8)

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)  // sync lines must land even when piped to a file
        var args = Array(CommandLine.arguments.dropFirst())
        let dir = takeDirFlag(&args)
        let identity = try Identity.loadOrCreate(dir: dir)
        let roster = Roster(dir: dir)
        let status = StatusStore(dir: dir)

        switch args.first {
        case "id":
            print(identity.endpointId)
        case "add":
            guard let id = args.dropFirst().first else { fail("usage: ping add <endpoint-id>") }
            await roster.add(id)
            print("added \(id.prefix(8))…")
        case "status":
            await status.set(args.dropFirst().joined(separator: " "))
            let seq = await status.state.seq
            print("status set (seq \(seq))")
        case "run":
            let node = Node(identity: identity, roster: roster, alpn: alpn) {
                let s = await status.state
                let payload = (try? JSONEncoder().encode(s.status)) ?? Data()
                return OutboundState(seq: s.seq, items: [
                    .init(contentType: "state/status", payload: payload)
                ])
            }
            node.on("state/status") { env, remote in
                let text = (try? JSONDecoder().decode(String.self, from: env.payload)) ?? "?"
                print("● \(remote.prefix(8)) → seq \(env.seq): \(text)")
            }
            node.log = { print($0) }
            try await node.start()
            let count = await roster.peers.count
            print("ping \(identity.endpointId.prefix(8))… up, \(count) peers on roster")
            while true {
                let ids = await Array(roster.peers.keys)  // snapshot: accept-side syncs
                await withTaskGroup(of: Void.self) { group in  // may grow the roster mid-sweep
                    for id in ids {                       // concurrent sweep: one dead
                        group.addTask {                   // peer can't stall the rest
                            do { try await node.ping(id) }
                            catch { print("[ping \(id.prefix(8))] failed: \(error)") }
                        }
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
