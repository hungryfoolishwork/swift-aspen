import Foundation
import ArgumentParser

@main
struct Main: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Devices certified by a shared root identity.",
        subcommands: [InitCommand.self, RootCommand.self, PeerCommand.self, StateCommand.self, WatchCommand.self]
    )

    struct Options: ParsableArguments {
        @Option(
            name: [.short, .long],
            help: "Path to store.",
            transform: { URL(filePath: NSString(string: $0).expandingTildeInPath) }
        )
        var path: URL = URL(filePath: NSString(string: "~/.config").expandingTildeInPath)
    }

    struct InitCommand: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Initialize new or existing instance."
        )

        func run() async throws {
            let session = try await Session(baseURL: options.path)

            print(
                """
                Session
                ├─ Root:   \(await session.root.id)
                └─ Device: \(session.id)
                """
            )
        }
    }

    struct RootCommand: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "root",
            abstract: "The root identity this device belongs to.",
            subcommands: [Show.self, Export.self, Import.self],
            defaultSubcommand: Show.self
        )

        struct Show: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "Show the root and this device's cert.")

            func run() async throws {
                let session = try await Session(baseURL: options.path)

                print(
                    """
                    Session
                    ├─ Root:   \(await session.root.id)
                    └─ Device: \(session.id)    
                    """
                )
                if let cert = await session.ledger.snapshot.state.cert {
                    print("Certificate \(cert.verifies(for: session.id) ? "is valid" : "is NOT valid") (seq \(cert.seq)).")
                }
            }
        }

        struct Export: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(
                abstract: "Print the root secret for enrolling another device."
            )

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                print(
                    """
                    \(await session.root.export)
                    
                    This is the root secret, on the new device call: 
                        $ identity root import <blob>
                    """
                )
            }
        }

        struct Import: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(
                abstract: "Adopt a root exported from another device and re-certify this one."
            )

            @Argument(help: "The blob printed by `identity root export`.")
            var transfer: String

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                do {
                    try await session.adopt(rootTransfer: transfer)
                } catch {
                    throw ValidationError("Not a valid root transfer blob.")
                }
                try? await session.start()  // best effort, so peers learn the new cert right away
                await session.sweep()
                await session.stop()

                print(
                    """
                    Session
                    ├─ Root (adopted): \(await session.root.id)
                    └─ Device:         \(session.id)
                    
                    This device is re-certified; peers learn on next sync.
                    """
                )
                print("Adopted root: \(await session.root.id)")
                print("This device is re-certified; peers learn on next sync.")
            }
        }
    }

    struct PeerCommand: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            commandName: "peer",
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
                let root = await session.root.id

                print(
                    """
                    Session
                    ├─ Root:   \(root)
                    └─ Device: \(session.id)
                    """
                )

                guard !known.isEmpty else {
                    print(
                        """
                        No peers, add one with:
                            $ identity peer add <endpoint-id>
                        """
                    )
                    return
                }

                // Group by verified root — the endpoint list collapses into
                // humans. Peers with no (valid) cert land in "unverified".
                var byRoot: [String: [Ledger.Peer]] = [:]
                var unverified: [String] = []
                for id in known {
                    if let peer = snapshot.peers[id], let cert = peer.state.cert {
                        byRoot[cert.rootId, default: []].append(peer)
                    } else {
                        unverified.append(id)
                    }
                }

                for (rootId, peers) in byRoot.sorted(by: { $0.key < $1.key }) {
                    let mine = rootId == root ? ", mine" : ""
                    print("Root \(rootId.prefix(7))... (\(peers.count) device(s)\(mine))")
                    for (index, peer) in peers.sorted(by: { $0.id < $1.id }).enumerated() {
                        let name = peer.state.name.isEmpty ? "unnamed" : peer.state.name
                        let prefix = (index < (peers.count - 1)) ? "├─" : "└─"
                        print("\(prefix) \(peer.id.prefix(7)) (\(name)) seen \(peer.lastSeen.formatted(.relative(presentation: .named)))")
                    }
                }
                
                if !unverified.isEmpty {
                    print("Unverified")
                    for (index, id) in unverified.sorted().enumerated() {
                        let prefix = (index < (unverified.count - 1)) ? "├─" : "└─"
                        if let peer = snapshot.peers[id] {
                            print("\(prefix) \(id.prefix(7)) \(peer.state.records.count) record(s), no cert")
                        } else {
                            print("\(prefix) \(id.prefix(7)) never synced")
                        }
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

    struct StateCommand: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            commandName: "state",
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

    struct WatchCommand: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            commandName: "watch",
            abstract: "Watch for changes from peers."
        )

        func run() async throws {
            let session = try await Session(baseURL: options.path)
            try await session.start()
            let rootId = await session.root.id
            print(
                """
                Session
                ├─ Root:   \(rootId)
                └─ Device: \(session.id)
                
                Watching... (ctrl-c to stop)
                """
            )
            var last = ""
            while true {
                let snapshot = render(await session.ledger.snapshot, myRoot: rootId)
                if snapshot != last {
                    print(snapshot)
                    last = snapshot
                }
                try await Task.sleep(for: .seconds(1))
            }
        }

        private func render(_ snapshot: Ledger.Snapshot, myRoot: String) -> String {
            var lines = ["", "Me: \(snapshot.state.records.count) record(s)"]
            lines += snapshot.state.records.map { "  • \($0)" }

            var byRoot: [String: [Ledger.Peer]] = [:]
            var unverified: [Ledger.Peer] = []
            for peer in snapshot.peers.values.sorted(by: { $0.id < $1.id }) {
                if let cert = peer.state.cert {
                    byRoot[cert.rootId, default: []].append(peer)
                } else {
                    unverified.append(peer)
                }
            }
            for (rootId, peers) in byRoot.sorted(by: { $0.key < $1.key }) {
                lines.append("Root \(rootId.prefix(8))…\(rootId == myRoot ? " (mine)" : "")")
                for peer in peers {
                    lines.append("  \(peer.id): \(peer.state.records.count) record(s)")
                    lines += peer.state.records.map { "    • \($0)" }
                }
            }
            if !unverified.isEmpty {
                lines.append("Unverified")
                for peer in unverified {
                    lines.append("  \(peer.id): \(peer.state.records.count) record(s)")
                    lines += peer.state.records.map { "    • \($0)" }
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}
