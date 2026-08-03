import Foundation
import Observation
import Aspen

@Observable @MainActor
final class Session {

    let alpn = Data("example-identitychain/0".utf8)
    let id: String
    let ledger: Ledger

    // Instance observables
    private(set) var state = Ledger.State()
    private(set) var peers: [Ledger.Peer] = []
    private(set) var running = false

    // This device's signing key and (on the founding device) the root secret.
    private(set) var keyring: Keyring

    // Iroh accounting
    private let identity: Aspen::Identity
    private let roster: Aspen::Roster
    private var node: Aspen::Node?

    private let dir: URL
    private var sweepTask: Task<Void, Never>?

    init(baseURL: URL) async throws {
        let url = baseURL.appending(path: "example-identitychain")
        self.dir = url
        self.ledger = Ledger(baseURL: url)

        self.identity = try Identity.loadOrCreate(dir: url)
        self.roster = Roster(dir: url)
        self.id = identity.endpointId
        self.keyring = try Keyring.loadOrCreate(dir: url)

        await ensureChain()
        await refresh()
    }

    func start() async throws {
        guard node == nil else { return }
        await refresh()

        let ledger = ledger

        let node = Aspen::Node(identity: identity, roster: roster, alpn: alpn, log: { msg in
            FileHandle.standardError.write(Data("[node] \(msg)\n".utf8))
        }) {
            let snapshot = await ledger.snapshot
            let payload = (try? JSONEncoder().encode(snapshot.state)) ?? Data()
            return Aspen::OutboundState(seq: snapshot.seq, items: [
                .init(contentType: "application/json+state", payload: payload)
            ])
        }

        await node.on("application/json+state") { [weak self] envelope, peer in
            guard var state = try? JSONDecoder().decode(Ledger.State.self, from: envelope.payload) else { return }
            // Structural check only — revocations are applied at read time,
            // since one can arrive long after the chain it cuts.
            if let chain = state.chain, !chain.verifies(for: peer) {
                state.chain = nil  // a claim without proof: keep the records, drop the grouping
            }
            await ledger.set(peer: peer, state: state)
            // Revocations are self-authenticating, so merge them from any
            // sender — even one whose own chain didn't check out.
            await self?.merge(revocations: state.revocations ?? [])
            await self?.refresh()
        }
        try await node.start()
        self.node = node
        running = true
        await refresh()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweep()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() async {
        sweepTask?.cancel()
        sweepTask = nil
        await node?.stop()
        node = nil
        running = false
    }

    func set(state: Ledger.State) async {
        await ledger.set(state: state)
        self.state = state
        await sweep()
    }

    func add(remote endpointID: String) async {
        let trimmed = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != self.id else { return }
        await roster.add(trimmed)
        await refresh()
        if let node {
            try? await node.ping(trimmed)
        }
        await refresh()
    }

    // MARK: enrollment

    /// Blob a new device hands to an already-enrolled one: endpoint id plus
    /// device signing public key. Nothing secret.
    func enrollmentRequest() throws -> String {
        let request = EnrollmentRequest(device: id, key: keyring.devicePublicKey)
        return try JSONEncoder().encode(request).base64EncodedString()
    }

    /// Run on an enrolled device: extend my chain with a link vouching for
    /// the requester and return the grant blob to hand back. Signed with the
    /// device key — the root secret plays no part. A device that knows it is
    /// revoked refuses: its vouching carries no weight anymore.
    func approve(request blob: String) async throws -> String {
        guard let data = Data(base64Encoded: blob.trimmingCharacters(in: .whitespacesAndNewlines)),
              let request = try? JSONDecoder().decode(EnrollmentRequest.self, from: data)
        else { throw ChainError.badBlob }
        guard request.device != id else { throw ChainError.selfEnrollment }

        let snapshot = await ledger.snapshot
        guard let chain = snapshot.state.chain,
              chain.verifies(for: id, revocations: snapshot.state.revocations ?? [])
        else { throw ChainError.notEnrolled }
        let grant = EnrollmentGrant(chain: try keyring.extend(chain, to: request))
        return try JSONEncoder().encode(grant).base64EncodedString()
    }

    /// Run on the new device: adopt the granted chain as our proof of
    /// membership, replacing the self-founded one. Peers pick it up on the
    /// next sync. A grant through a device we know is revoked is refused.
    func accept(grant blob: String) async throws {
        guard let data = Data(base64Encoded: blob.trimmingCharacters(in: .whitespacesAndNewlines)),
              let grant = try? JSONDecoder().decode(EnrollmentGrant.self, from: data)
        else { throw ChainError.badBlob }

        let chain = grant.chain
        let revocations = await ledger.snapshot.state.revocations ?? []
        guard chain.links.last?.child == keyring.devicePublicKey,
              chain.verifies(for: id, revocations: revocations)
        else { throw ChainError.notForThisDevice }
        var state = await ledger.snapshot.state
        state.chain = chain
        await ledger.set(state: state)
        await refresh()
    }

    /// Burn a device's key. The revocation gossips from here; whether it has
    /// any effect is decided by each verifier — only the root or an ancestor
    /// of the target on its chain carries authority.
    func revoke(device endpointID: String) async throws {
        let snapshot = await ledger.snapshot
        let key = endpointID == id
            ? snapshot.state.chain?.links.last?.child
            : snapshot.peers[endpointID]?.state.chain?.links.last?.child
        guard let key else { throw ChainError.unknownDevice }
        let revocation = try keyring.revoke(key: key, chainRoot: snapshot.state.chain?.rootKey)
        await merge(revocations: [revocation])
        await refresh()
    }

    /// Union new, signature-valid revocations into our gossiped state. The
    /// set only grows; any growth bumps our seq so peers pull the news.
    private func merge(revocations incoming: [Revocation]) async {
        var state = await ledger.snapshot.state
        var current = state.revocations ?? []
        let fresh = incoming.filter { $0.verifies() && !current.contains($0) }
        guard !fresh.isEmpty else { return }
        current.append(contentsOf: fresh)
        state.revocations = current
        await ledger.set(state: state)
    }

    /// Make sure our gossiped state carries a valid chain. A fresh device
    /// founds its own identity (root signs it, one link); an adopted chain
    /// from enrollment is left alone.
    private func ensureChain() async {
        var state = await ledger.snapshot.state
        if let chain = state.chain, chain.verifies(for: id) { return }
        guard let chain = try? keyring.selfChain(device: id) else { return }
        state.chain = chain
        await ledger.set(state: state)
    }

    /// The direct (ip:port) addresses this node listens on while running —
    /// hand them to a peer out-of-band to let it dial without discovery.
    func directAddresses() async -> [String] {
        await node?.directAddresses() ?? []
    }

    func knownPeers() async -> [String] {
        await Array(roster.peers.keys).sorted()
    }

    func sweep() async {
        guard let node else { return }
        let endpointIDs = await Array(roster.peers.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in endpointIDs {
                group.addTask {
                    do { try await node.ping(id) } catch {
                        FileHandle.standardError.write(Data("[sync] \(id.prefix(8))… unreachable: \(error)\n".utf8))
                    }
                }
            }
        }
        await refresh()
    }

    private func refresh() async {
        let snapshot = await ledger.snapshot
        state = snapshot.state
        peers = snapshot.peers.values.sorted { $0.id < $1.id }
    }
}
