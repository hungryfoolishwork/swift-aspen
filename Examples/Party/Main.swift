import Foundation
import ArgumentParser

@main
struct Main: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Start a party of peers.",
        subcommands: [Init.self, Peer.self, State.self, Watch.self]
    )

    struct Options: ParsableArguments {
        @Option(
            name: [.short, .long],
            help: "Path to store.",
            transform: { URL(filePath: NSString(string: $0).expandingTildeInPath) }
        )
        var path: URL = URL(filePath: NSString(string: "~/.config").expandingTildeInPath)
    }

    struct Init: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(abstract: "Initialize new or existing instance.")

        func run() async throws {
            let session = try await Session(baseURL: options.path)
            print(session.id)
        }
    }

    struct Peer: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            abstract: "Peer related commands.",
            subcommands: [List.self, Add.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "List known peers.")

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                let known = await session.knownPeers()
                let snapshot = await session.ledger.snapshot

                print("Me: \(session.id)")
                guard !known.isEmpty else {
                    print("No peers. Add one with `keeper peer add <endpoint-id>`.")
                    return
                }
                for id in known {
                    if let peer = snapshot.peers[id] {
                        let name = peer.state.name.isEmpty ? "unnamed" : peer.state.name
                        print("\(id)  \(name), \(peer.state.records.count) record(s), seen \(peer.lastSeen.formatted(.relative(presentation: .named)))")
                    } else {
                        print("\(id)  never synced")
                    }
                }
            }
        }

        struct Add: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "Add peer.")

            @Argument(help: "The peer endpoint identifier to add.")
            var endpointID: String

            func run() async throws {
                let trimmed = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw ValidationError("Peer endpoint ID is empty.")
                }

                let session = try await Session(baseURL: options.path)
                guard trimmed != session.id else {
                    throw ValidationError("That's this node's own endpoint ID.")
                }

                try? await session.start()  // best effort, so the new peer gets pinged right away
                await session.add(remote: trimmed)
                await session.stop()
                print("Peer Added: \(trimmed)")
            }
        }
    }

    struct State: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            abstract: "State related commands.",
            subcommands: [Show.self, Add.self],
            defaultSubcommand: Show.self
        )

        struct Show: AsyncParsableCommand {
            @OptionGroup var options: Options

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                try? await session.start()

                let records = await session.state.records
                print(records.joined(separator: "\n"))
            }
        }

        struct Add: AsyncParsableCommand {
            @OptionGroup var options: Options

            @Argument(help: "The content to record.")
            var content: String

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                try? await session.start()  // best effort, so the record gets pushed to peers

                var state = await session.ledger.snapshot.state
                state.records.append(content)
                await session.set(state: state)

                await session.stop()
                print("Recorded: \(content)")
            }
        }
    }

    struct Watch: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(abstract: "Watch for changes from peers.")

        func run() async throws {
            let session = try await Session(baseURL: options.path)
            try await session.start()

            print("Me: \(session.id)")
            print("Watching... (ctrl-c to stop)")

            var last = ""
            while true {
                let snapshot = render(await session.ledger.snapshot)
                if snapshot != last {
                    print(snapshot)
                    last = snapshot
                }
                try await Task.sleep(for: .seconds(1))
            }
        }

        private func render(_ snapshot: Ledger.Snapshot) -> String {
            var lines = ["", "Me: \(snapshot.state.records.count) record(s)"]
            lines += snapshot.state.records.map { "  • \($0)" }
            for peer in snapshot.peers.values.sorted(by: { $0.id < $1.id }) {
                lines.append("\(peer.id): \(peer.state.records.count) record(s)")
                lines += peer.state.records.map { "  • \($0)" }
            }
            return lines.joined(separator: "\n")
        }
    }
}
