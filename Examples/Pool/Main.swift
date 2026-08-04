import Foundation
import ArgumentParser

@main
struct Main: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "One pool of records shared by every device.",
        subcommands: [Init.self, Peer.self, Record.self, Watch.self]
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
                    print("No peers. Add one with `pool peer add <endpoint-id>`.")
                    return
                }
                for id in known {
                    if let peer = snapshot.peers[id] {
                        print("\(id)  seen \(peer.lastSeen.formatted(.relative(presentation: .named)))")
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

    struct Record: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            abstract: "Record related commands.",
            subcommands: [List.self, Add.self, Update.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "List the pool.")

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                try? await session.start()  // best effort, so the pool reflects the mesh
                await session.sweep()
                await session.stop()

                let records = await session.records
                guard !records.isEmpty else {
                    print("Empty pool. Add a record with `pool record add <text>`.")
                    return
                }
                for record in records {
                    print("\(record.id.prefix(8))  \(record.text)")
                }
            }
        }

        struct Add: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "Add a record to the pool.")

            @Argument(help: "The content to record.")
            var content: String

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                try? await session.start()  // best effort, so the record gets pushed to peers

                let record = await session.add(text: content)

                await session.stop()
                print("Recorded: \(record.id.prefix(8))  \(record.text)")
            }
        }

        struct Update: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "Update a record in the pool.")

            @Argument(help: "The record id, or a unique prefix of it.")
            var id: String

            @Argument(help: "The new content.")
            var content: String

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                let matches = await session.ledger.records(matching: id)
                guard matches.count == 1, let match = matches.first else {
                    throw ValidationError(matches.isEmpty
                        ? "No record matches '\(id)'."
                        : "'\(id)' matches \(matches.count) records; use more of the id.")
                }

                try? await session.start()  // best effort, so the edit gets pushed to peers
                await session.update(id: match.id, text: content)
                await session.stop()
                print("Updated: \(match.id.prefix(8))  \(content)")
            }
        }
    }

    struct Watch: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(abstract: "Watch the pool converge.")

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
            let records = snapshot.records.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            var lines = ["", "Pool: \(records.count) record(s)"]
            lines += records.map { "  • \($0.id.prefix(8))  \($0.text)" }
            if !snapshot.peers.isEmpty {
                lines.append("Heard from \(snapshot.peers.count) peer(s)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
