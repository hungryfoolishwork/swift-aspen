import Foundation
import ArgumentParser

@main
struct Main: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Devices vouching for each other in a chain back to a root identity.",
        subcommands: [Init.self, ChainCommand.self, Enroll.self, Revoke.self, Peer.self, State.self, Watch.self]
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
            print("Device: \(session.id)")
            print("Root:   \(await session.ledger.snapshot.state.chain?.rootId ?? "none")")
        }
    }

    struct ChainCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "chain",
            abstract: "This device's chain of trust.",
            subcommands: [Show.self],
            defaultSubcommand: Show.self
        )

        struct Show: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(abstract: "Show the links from the root to this device.")

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                let state = await session.ledger.snapshot.state
                let revocations = state.revocations ?? []
                print("Device: \(session.id)")
                guard let chain = state.chain else {
                    print("No chain. Enroll with `identitychain enroll request`.")
                    return
                }
                print("Root:   \(chain.rootId ?? "none")")
                let structural = chain.verifies(for: session.id)
                let valid = chain.verifies(for: session.id, revocations: revocations)
                print("Valid:  \(valid)\(structural && !valid ? " (a key on the path is revoked)" : "")")
                for (i, link) in chain.links.enumerated() {
                    let signer = i == 0 ? "root" : "device key \(link.parent.hexString.prefix(8))…"
                    print("  \(i + 1). \(link.device.prefix(8))… (key \(link.child.hexString.prefix(8))…) vouched for by \(signer), seq \(link.seq)")
                }
                if !revocations.isEmpty {
                    print("Revocations known:")
                    for r in revocations {
                        print("  key \(r.revoked.hexString.prefix(8))… burned by \(r.signer.hexString.prefix(8))…, seq \(r.seq)")
                    }
                }
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        @OptionGroup var options: Options

        static let configuration = CommandConfiguration(
            abstract: "Burn a device's key. Only the root or an ancestor of that device carries authority."
        )

        @Argument(help: "The endpoint id of the device to revoke (its chain must have synced here).")
        var endpointID: String

        func run() async throws {
            let session = try await Session(baseURL: options.path)
            do {
                try await session.revoke(device: endpointID.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch ChainError.unknownDevice {
                throw ValidationError("No chain for that endpoint — a device can only be revoked from one that has synced with it.")
            }
            try? await session.start()  // best effort, so the revocation spreads right away
            await session.sweep()
            await session.stop()
            print("Revoked: \(endpointID)")
            print("Spreads on sync. Verifiers ignore it unless this device outranks the target on its chain.")
        }
    }

    struct Enroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Enroll a new device by hand-carrying blobs. No secret ever moves.",
            subcommands: [Request.self, Approve.self, Accept.self]
        )

        struct Request: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(
                abstract: "On the NEW device: print a request blob to hand to an enrolled device."
            )

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                print(try await session.enrollmentRequest())
                FileHandle.standardError.write(Data(
                    "On an enrolled device: identitychain enroll approve <blob>\n".utf8
                ))
            }
        }

        struct Approve: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(
                abstract: "On an ENROLLED device: sign the request into this chain and print the grant."
            )

            @Argument(help: "The blob printed by `identitychain enroll request`.")
            var request: String

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                let grant: String
                do {
                    grant = try await session.approve(request: request)
                } catch ChainError.badBlob {
                    throw ValidationError("Not a valid enrollment request blob.")
                } catch ChainError.selfEnrollment {
                    throw ValidationError("That request came from this device.")
                } catch ChainError.notEnrolled {
                    throw ValidationError("This device has no valid chain to extend.")
                }
                print(grant)
                FileHandle.standardError.write(Data(
                    "Back on the new device: identitychain enroll accept <blob>\n".utf8
                ))
            }
        }

        struct Accept: AsyncParsableCommand {
            @OptionGroup var options: Options

            static let configuration = CommandConfiguration(
                abstract: "On the NEW device: adopt the granted chain."
            )

            @Argument(help: "The blob printed by `identitychain enroll approve`.")
            var grant: String

            func run() async throws {
                let session = try await Session(baseURL: options.path)
                do {
                    try await session.accept(grant: grant)
                } catch ChainError.badBlob {
                    throw ValidationError("Not a valid enrollment grant blob.")
                } catch ChainError.notForThisDevice {
                    throw ValidationError("That grant was issued to a different device or key.")
                }
                try? await session.start()  // best effort, so peers learn the new chain right away
                await session.sweep()
                await session.stop()
                let chain = await session.ledger.snapshot.state.chain
                print("Enrolled under root: \(chain?.rootId ?? "none")")
                print("Chain length: \(chain?.links.count ?? 0) link(s)")
            }
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

                let myRoot = snapshot.state.chain?.rootId
                print("Me: \(session.id)")
                print("Root: \(myRoot ?? "none")")
                guard !known.isEmpty else {
                    print("No peers. Add one with `identitychain peer add <endpoint-id>`.")
                    return
                }

                // Group by the root the chain walks back to — the endpoint
                // list collapses into humans. Structurally bad chains were
                // stripped on receive, so a stored chain that fails now was
                // cut by a revocation.
                let revocations = snapshot.state.revocations ?? []
                var byRoot: [String: [Ledger.Peer]] = [:]
                var revoked: [Ledger.Peer] = []
                var unverified: [String] = []
                for id in known {
                    guard let peer = snapshot.peers[id], let chain = peer.state.chain else {
                        unverified.append(id)
                        continue
                    }
                    if let rootId = chain.rootId, chain.verifies(for: id, revocations: revocations) {
                        byRoot[rootId, default: []].append(peer)
                    } else {
                        revoked.append(peer)
                    }
                }

                for (rootId, peers) in byRoot.sorted(by: { $0.key < $1.key }) {
                    let mine = rootId == myRoot ? ", mine" : ""
                    print("Root \(rootId.prefix(8))… (\(peers.count) device(s)\(mine))")
                    for peer in peers.sorted(by: { $0.id < $1.id }) {
                        let name = peer.state.name.isEmpty ? "unnamed" : peer.state.name
                        let hops = peer.state.chain?.links.count ?? 0
                        print("  \(peer.id)  \(name), \(hops) link(s) from root, \(peer.state.records.count) record(s), seen \(peer.lastSeen.formatted(.relative(presentation: .named)))")
                    }
                }
                if !revoked.isEmpty {
                    print("Revoked")
                    for peer in revoked.sorted(by: { $0.id < $1.id }) {
                        print("  \(peer.id)  \(peer.state.records.count) record(s), chain cut by revocation")
                    }
                }
                if !unverified.isEmpty {
                    print("Unverified")
                    for id in unverified.sorted() {
                        if let peer = snapshot.peers[id] {
                            print("  \(id)  \(peer.state.records.count) record(s), no chain")
                        } else {
                            print("  \(id)  never synced")
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
            setbuf(stdout, nil)  // line output survives piping/redirection
            let session = try await Session(baseURL: options.path)
            try await session.start()

            let myRoot = await session.ledger.snapshot.state.chain?.rootId
            print("Me: \(session.id)")
            print("Root: \(myRoot ?? "none")")
            print("Direct: \(await session.directAddresses().joined(separator: " "))")
            print("Watching... (ctrl-c to stop)")

            var last = ""
            while true {
                let snapshot = render(await session.ledger.snapshot, myRoot: myRoot)
                if snapshot != last {
                    print(snapshot)
                    last = snapshot
                }
                try await Task.sleep(for: .seconds(1))
            }
        }

        private func render(_ snapshot: Ledger.Snapshot, myRoot: String?) -> String {
            var lines = ["", "Me: \(snapshot.state.records.count) record(s)"]
            lines += snapshot.state.records.map { "  • \($0)" }

            let revocations = snapshot.state.revocations ?? []
            var byRoot: [String: [Ledger.Peer]] = [:]
            var revoked: [Ledger.Peer] = []
            var unverified: [Ledger.Peer] = []
            for peer in snapshot.peers.values.sorted(by: { $0.id < $1.id }) {
                if let chain = peer.state.chain {
                    if let rootId = chain.rootId, chain.verifies(for: peer.id, revocations: revocations) {
                        byRoot[rootId, default: []].append(peer)
                    } else {
                        revoked.append(peer)
                    }
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
            if !revoked.isEmpty {
                lines.append("Revoked")
                for peer in revoked {
                    lines.append("  \(peer.id): \(peer.state.records.count) record(s)")
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
