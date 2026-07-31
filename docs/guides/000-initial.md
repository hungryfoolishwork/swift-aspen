# Ping — a minimal Swift CLI for iroh peer state sync

This walks you through building a small macOS command-line tool where multiple peers dial each other by EndpointId, exchange typed envelope messages over iroh QUIC streams, and periodically pull state updates from a roster of known peers. When you're done, you'll have two (or more) terminal windows acting as independent peers, pinging each other on a timer, syncing a toy "status" state, and caching each other's direct addresses between contacts.

## Scope

| In scope | Deliberately left out |
|---|---|
| SwiftPM executable, all Swift, no Rust toolchain | iOS app lifecycle, BGAppRefreshTask |
| Persistent identity (Ed25519 secret key on disk) | Keychain storage (plain file is fine for a prototype) |
| Length-prefixed JSON envelopes with a `contentType` field | Protobuf (swap in later — the framing layer won't change) |
| Accept loop + dial-with-timeout | mDNS/Bluetooth discovery (Rust-only in the FFI for now) |
| Roster file + cached direct addresses as dialing hints | Gossip/relaying between peers (full mesh only) |
| Seq-based "only send if newer" sync | CRDTs, version vectors, multi-key state |

## What you'll end up with

```
ping/
├── Package.swift                ← depends on n0-computer/iroh-ffi (IrohLib)
└── Sources/ping/
    ├── Ping.swift           ← @main: arg parsing, run loop
    ├── Identity.swift           ← SecretKey persistence per --dir
    ├── Wire.swift               ← Envelope + length-prefixed framing
    ├── Roster.swift             ← peer list + cached addresses + cursors (JSON on disk)
    └── Node.swift               ← Endpoint bind, accept loop, dial+timeout, sync exchange
```

Each running instance points at its own state directory via `--dir` (defaulting to `~/.config/ping/` when the flag is omitted), which is what lets you run several peers on one Mac:

```
~/tmp/peer-a/   ← identity.key, roster.json, state.json
~/tmp/peer-b/
```

---

## Step 1 — Create the package and pull in IrohLib

iroh-ffi ships a prebuilt `xcframework` as an SPM binary target, so a plain `swift build` on your Mac downloads it and links it — no Xcode project, no cargo. This is the payoff of the 1.0 bindings and the reason a CLI is the fastest possible start.

```bash
mkdir ping && cd ping
swift package init --type executable --name ping
```

Replace `Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ping",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ping",
            dependencies: [.product(name: "IrohLib", package: "iroh-ffi")]
        )
    ]
)
```

Tools version 5.10 rather than 6.0 keeps strict-concurrency checking in "warnings, not errors" mode. The IrohLib types come from UniFFI-generated code and you'll be moving them across task boundaries; fighting Swift 6 `Sendable` errors is real work, and it's not the point of this prototype.

The platform is spelled `.macOS("15.0")` rather than `.v15` because the enum cases for recent OS versions were introduced in PackageDescription 6.x and are unavailable to a 5.10 manifest — the string form works under any tools version. (iroh-ffi's own floor is macOS 14.5, so 15.0 comfortably clears it.)

### Verify

```bash
swift build
```

First build downloads the xcframework zip from the GitHub release (~a minute), then compiles. It should succeed with the template `main.swift` still in place. If the download is blocked, that's your network — the binary comes from `release-assets.githubusercontent.com`.

---

## Step 2 — Persistent identity

Your EndpointId *is* your public key, so persisting the secret key is what makes a peer's identity stable across launches — the whole roster concept depends on it. The official demo uses `UserDefaults`; for a CLI with multiple instances on one machine, a file inside the per-peer state directory is the right move.

Create `Sources/ping/Identity.swift`:

```swift
import Foundation
import IrohLib

struct Identity {
    let secretKey: SecretKey
    var endpointId: String { secretKey.public().description }

    static func loadOrCreate(dir: URL) throws -> Identity {
        let keyFile = dir.appendingPathComponent("identity.key")
        if let data = try? Data(contentsOf: keyFile),
           let key = try? SecretKey.fromBytes(bytes: data) {
            return Identity(secretKey: key)
        }
        let key = SecretKey.generate()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try key.toBytes().write(to: keyFile, options: .completeFileProtection)
        return Identity(secretKey: key)
    }
}
```

Note the API shape: `SecretKey.generate()`, `toBytes()`/`fromBytes(bytes:)`, and `secretKey.public().description` gives you the hex EndpointId string. That's the string you'll paste between terminals.

### Verify

Compiles with `swift build`. Runtime check comes in Step 5 when `id` prints the same value across two runs.

---

## Step 3 — The envelope and wire framing

This is your "predictable envelopes with content-types" idea, and it's worth getting the shape right now because everything above the transport dispatches on it. Two layers, deliberately separated:

**Framing** answers "where does one message end?" QUIC streams are ordered byte pipes, not message pipes, so you prefix every message with a 4-byte big-endian length. **Envelope** answers "what kind of message is this?" — a small JSON header wrapping an opaque payload. Keeping them separate means swapping JSON for protobuf later touches only the encode/decode functions, not the framing.

Create `Sources/ping/Wire.swift`:

```swift
import Foundation
import IrohLib

enum Wire {
    /// Version your protocol in the ALPN — bump the suffix on breaking changes
    /// and old/new peers simply won't complete a handshake with each other.
    static let alpn = Data("ping/0".utf8)
    static let maxFrame: UInt32 = 1 << 20  // 1 MiB sanity cap

    struct Envelope: Codable {
        let contentType: String   // "sync/hello", "state/status", "sync/bye"
        let sender: String        // hex EndpointId
        let seq: UInt64           // sender's state sequence number
        let payload: Data
    }

    static func write(_ env: Envelope, to send: SendStream) async throws {
        let body = try JSONEncoder().encode(env)
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        try await send.writeAll(buf: frame)
    }

    static func read(from recv: RecvStream) async throws -> Envelope {
        let header = try await recv.readExact(size: 4)
        let len = header.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        guard len > 0, len <= maxFrame else { throw WireError.badFrame }
        let body = try await recv.readExact(size: len)
        return try JSONDecoder().decode(Envelope.self, from: body)
    }

    enum WireError: Error { case badFrame }
}
```

The stream API here is real IrohLib surface: a `BiStream` gives you `send()` → `SendStream` with `writeAll(buf:)` and `recv()` → `RecvStream` with `readExact(size:)`. `readExact` blocking until exactly N bytes arrive is what makes length-prefixed framing this simple — no buffering loop of your own.

Why is `seq` in the header instead of the payload? Because the sync layer needs it to decide staleness *without* understanding any particular content-type. Header fields are for routing and ordering; payload is for the handler. That division is the same one MIME made, which you know well from your syntax-highlighting work.

### Verify

`swift build`. For a real unit check, round-trip an envelope through `JSONEncoder`/`JSONDecoder` in a scratch `main` — full wire verification lands in Step 6.

---

## Step 4 — Roster, address cache, and state

The roster is the heart of your pull model: the list of EndpointIds this device is always interested in, plus two things learned per contact — cached direct addresses (dialing hints) and a cursor (highest `seq` seen from that peer). One JSON file, rewritten atomically on change; at prototype scale there's no reason for anything fancier.

Create `Sources/ping/Roster.swift`:

```swift
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

    func addPeer(_ id: String) { /* insert PeerRecord if absent, save() */ }
    func setStatus(_ s: String) { /* bump myState.seq, set status, save() */ }
    func update(_ id: String, _ mutate: (inout PeerRecord) -> Void) { /* mutate, save() */ }

    private func save() { /* JSONEncoder both files, .atomic write */ }
    private static func load<T: Codable>(_ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
```

`Store` is an `actor` rather than a class, and that's load-bearing, not ceremony. The sweep (Step 7) pings every roster peer in a concurrent task group, the accept loop (Step 5) spawns a task per incoming connection, and with two peers on 30-second timers both happen at once routinely — A dials B while B is dialing A, and each side's sync calls `update(_:_:)`. As a class that's a real data race on the `peers` dictionary plus interleaved file writes, and tools 5.10 would only warn about it. The actor serializes every access; the only cost is that callers say `await`, which you'll see sprinkled through Steps 5–7.

The stubbed methods are one-to-three-liners following the pattern already shown — fill them in:

| Method | Behavior |
|---|---|
| `addPeer(_:)` | No-op if the id already exists; otherwise insert a fresh `PeerRecord` and `save()` |
| `setStatus(_:)` | `myState.seq += 1` **before** assigning — a peer that has seq N must treat your new state as N+1 |
| `update(_:_:)` | Look up the record (create if missing — an unknown peer dialing *you* is how B learns about A), apply the closure, `save()` |
| `save()` | Encode `peers` and `myState` to their files with `.atomic` so a crash mid-write can't corrupt the roster |

The seq-before-assign detail in `setStatus` is the entire consistency model of this prototype: monotonically increasing seq per peer, receiver keeps max. It's last-write-wins with a local counter — no clocks to trust, which is why it's the right minimal choice over timestamps.

### Verify

`swift build`, then in Step 5 you'll see `roster.json` and `state.json` appear on disk.

---

## Step 5 — The Node: bind, accept, dial with a deadline

Now the iroh core. A `Node` owns the `Endpoint`, runs the accept loop for incoming pings, and dials outbound with the 5-second deadline discussed earlier — because a stale discovery record for an offline peer will otherwise hang your sweep for up to 30 seconds.

Create `Sources/ping/Node.swift`:

```swift
import Foundation
import IrohLib

final class Node {
    let identity: Identity
    let store: Store
    private var endpoint: Endpoint!

    init(identity: Identity, store: Store) {
        self.identity = identity
        self.store = store
    }

    func start() async throws {
        endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),                     // n0's public relays + DNS discovery
            secretKey: identity.secretKey.toBytes(),
            alpns: [Wire.alpn]
        ))
        Task { await runAcceptLoop() }
    }

    // MARK: incoming

    private func runAcceptLoop() async {
        while true {
            guard let incoming = await endpoint.acceptNext() else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let accepting = try await incoming.accept()
                    guard try await accepting.alpn() == Wire.alpn else { return }
                    let conn = try await accepting.connect()
                    let bi = try await conn.acceptBi()
                    let remote = conn.remoteId().description
                    try await self.runSync(bi: bi, conn: conn, remote: remote, initiator: false)
                } catch {
                    print("[accept] \(error)")
                }
            }
        }
    }

    // MARK: outgoing

    func ping(_ peerId: String) async {
        do {
            let conn = try await dial(peerId)
            let bi = try await conn.openBi()
            try await runSync(bi: bi, conn: conn, remote: peerId, initiator: true)
        } catch {
            print("[ping \(peerId.prefix(8))] failed: \(error)")
        }
    }

    private func dial(_ peerId: String) async throws -> Connection {
        let id = try EndpointId.fromString(s: peerId)
        // Cached addrs are hints: iroh tries them alongside discovery, which
        // makes LAN dials work even when DNS is slow, stale, or offline.
        let hints = await store.peers[peerId]?.cachedAddrs ?? []
        let addr = EndpointAddr(id: id, relayUrl: nil, addresses: hints)
        let ep = endpoint!
        return try await withThrowingTaskGroup(of: Connection.self) { group in
            group.addTask { try await ep.connect(addr: addr, alpn: Wire.alpn) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw DialError.timeout
            }
            let conn = try await group.next()!
            group.cancelAll()
            return conn
        }
    }

    enum DialError: Error { case timeout }
}
```

Three things worth understanding rather than copying:

**The accept loop spawns a task per connection.** `acceptNext()` must get back to waiting immediately, or a slow peer blocks all others. The ALPN check is your protocol gate — anything else dialing this endpoint gets dropped before you read a byte.

**Dialer opens the stream, acceptor accepts it.** `openBi()` and `acceptBi()` pair up — that's the QUIC contract. Both sides then run the *same* `runSync` (next step); only stream setup differs, which is what the `initiator` flag records.

**The deadline races the dial in a task group.** When `connect` wins, `cancelAll()` kills the timer; when the timer wins, the thrown error cancels the dial. This is the standard Swift pattern for "give up after N seconds".

### Verify

Wire up a temporary `Ping.swift` main to prove identity persistence works. The `takeDirFlag` helper is permanent — Step 7 replaces `main` but keeps it:

```swift
import Foundation

@main struct Ping {
    static func main() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let dir = takeDirFlag(&args)
        let identity = try Identity.loadOrCreate(dir: dir)
        print("endpoint id: \(identity.endpointId)")
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
}
```

```bash
swift run ping --dir ~/tmp/peer-a
```

Run it twice with the same `--dir` — the id must not change. Run with `--dir ~/tmp/peer-b` — the id must differ. That's your multi-peer-on-one-Mac setup working, no `cd` juggling required. (The directory is created on first use by `Identity.loadOrCreate`.)

---

## Step 6 — The sync exchange

Every contact — whether you dialed or were dialed — runs the same short conversation, which is what makes one ping serve both directions:

```
initiator                          acceptor
    │── sync/hello (my seq, your cursor) ──▶│
    │◀── sync/hello (their seq, my cursor) ─│
    │── state/status (only if they're behind) ─▶
    │◀── state/status (only if I'm behind) ──│
    │── sync/bye ──▶ / ◀── sync/bye ──│      close
```

Add to `Node.swift`:

```swift
    private func runSync(bi: BiStream, conn: Connection, remote: String, initiator: Bool) async throws {
        let send = bi.send()
        let recv = bi.recv()

        // One snapshot of my state for the whole exchange — seq and status read
        // together, so a concurrent `status` command can't tear them apart.
        let my = await store.myState

        // 1. Exchange hellos. Payload carries the cursor: "highest seq of YOURS I've seen."
        let myCursor = await store.peers[remote]?.lastSeenSeq ?? 0
        try await Wire.write(Wire.Envelope(
            contentType: "sync/hello",
            sender: identity.endpointId,
            seq: my.seq,
            payload: try JSONEncoder().encode(myCursor)
        ), to: send)
        let theirHello = try await Wire.read(from: recv)
        let theirCursorOfMe = try JSONDecoder().decode(UInt64.self, from: theirHello.payload)

        // 2. Send state only if the peer is behind — this is the "pull updates" part.
        if my.seq > theirCursorOfMe {
            try await Wire.write(Wire.Envelope(
                contentType: "state/status",
                sender: identity.endpointId,
                seq: my.seq,
                payload: try JSONEncoder().encode(my.status)
            ), to: send)
        }
        try await Wire.write(Wire.Envelope(
            contentType: "sync/bye", sender: identity.endpointId,
            seq: my.seq, payload: Data()
        ), to: send)

        // 3. Read their side until bye, dispatching on contentType.
        while true {
            let env = try await Wire.read(from: recv)
            if env.contentType == "sync/bye" { break }
            await handle(env, from: remote)
        }

        // 4. Contact bookkeeping: cursor floor from the hello, fresh addresses, timestamp.
        let paths = conn.paths().filter { $0.isIp }.map { $0.remoteAddr }
        await store.update(remote) { rec in
            rec.lastSeenSeq = max(rec.lastSeenSeq, theirHello.seq)
            if !paths.isEmpty { rec.cachedAddrs = paths }
            rec.lastContact = Date()
        }
    }

    private func handle(_ env: Wire.Envelope, from remote: String) async {
        let cursor = await store.peers[remote]?.lastSeenSeq ?? 0
        guard env.seq > cursor else { return }  // stale
        switch env.contentType {
        case "state/status":
            let status = (try? JSONDecoder().decode(String.self, from: env.payload)) ?? "?"
            print("● \(remote.prefix(8)) → seq \(env.seq): \(status)")
            await store.update(remote) { $0.lastSeenSeq = env.seq }
        default:
            print("● \(remote.prefix(8)) → unknown contentType \(env.contentType), ignoring")
        }
    }
```

Design notes:

**Both sides write before draining reads.** Each side's sends and receives are independent QUIC directions, so writing your hello, state, and bye up front and *then* reading theirs can't deadlock — the bytes flow concurrently even though your code is sequential. If you instead did strict request/response turns, you'd double the round-trips for nothing.

**Unknown content-types are ignored, not fatal.** That's what makes the envelope scheme extensible: a newer peer can emit `state/battery` tomorrow and today's build just logs and skips it. Version *breaking* changes with the ALPN; version *additive* changes with new content-types.

**Address caching harvests from `conn.paths()`.** After a successful contact you overwrite the cache with the IP paths the connection actually used — the freshest possible hint, exactly as you proposed. Filtering `isIp` keeps relay paths out of the hint list.

**The hello's `seq` field updates the cursor even when no state is sent.** If nothing changed, the exchange is two tiny frames each way and done — cheap enough to run every 30 seconds without thinking.

### Verify

Full verification is the run loop in Step 7 — one step away.

---

## Step 7 — The CLI run loop

Replace `main` in `Ping.swift` with real argument handling, keeping the `takeDirFlag` helper from Step 5. Bare-bones `CommandLine.arguments` parsing is fine — ArgumentParser is a dependency you don't need yet.

```swift
import Foundation

@main struct Ping {
    static func main() async throws {
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
```

The sweep pings all roster peers concurrently in a task group and only then sleeps — with the 5-second dial deadline, a sweep costs at most ~5 seconds regardless of how many peers are dead. That's the property that makes the pull model tolerate flaky peers.

### Verify — the whole thing, end to end

Two terminals, both in the package directory — `--dir` is what keeps the peers separate:

```bash
# Terminal A
cd ~/src/ping
swift run ping --dir ~/tmp/peer-a id        # copy this
swift run ping --dir ~/tmp/peer-a status "hello from A"
swift run ping --dir ~/tmp/peer-a run

# Terminal B
cd ~/src/ping
swift run ping --dir ~/tmp/peer-b add <A's id>
swift run ping --dir ~/tmp/peer-b status "B checking in"
swift run ping --dir ~/tmp/peer-b run
```

Within one sweep you should see, in terminal B, `● <A-prefix> → seq 1: hello from A` — and in terminal A the reverse, *even though A never added B*, because A's accept-side sync created the roster entry. Then:

1. Ctrl-C peer B, run `swift run ping --dir ~/tmp/peer-b status "B was away"`, restart `run` — A picks up the new seq on the next contact. Offline catch-up works.
2. Check `~/tmp/peer-a/roster.json` — B's entry should have `cachedAddrs` with a real `ip:port` and a `lastContact` timestamp.
3. Kill B and leave A running — A's sweep logs `failed: timeout` after ~5s and keeps cycling. That's your fast-fail behavior verified.

---

## How it comes together

At runtime: `run` binds the endpoint (publishing your relay + addresses to n0's discovery), starts the accept loop, and sweeps the roster every 30 seconds. Each ping dials with cached addresses as hints under a 5-second deadline, then both sides run the identical hello → state-if-newer → bye exchange, so a single contact syncs both directions and refreshes the address cache from the connection's live paths. State is a single seq-numbered status string; the cursor in each hello means unchanged state costs almost nothing on the wire.

## What's next

- **Add a second content-type** (`state/battery`, anything) without touching framing or sync — the dispatch in `handle` is the only edit. Proving that extension point is cheap is the real test of the envelope design.
- **Backoff for dead peers**: track consecutive failures in `PeerRecord` and skip peers exponentially — pull loops make this trivial since it's just sweep-time filtering.
- **Lift Node into a SwiftUI app**: `Node`, `Wire`, `Roster`, and `Identity` move unchanged; the CLI loop becomes foreground-timer + reconcile-on-launch, which is where the iOS backgrounding realities from our earlier discussion come in.
- **Extract a reusable package (`PingKit`)**: once the sync works end-to-end, split `Identity`, `Wire`, `Roster`, and `Node` into a library target with a `.library` product, leaving `Ping.swift` as a thin executable — consumers (future p2p projects, including iOS 17.5+) get IrohLib transitively. Three things to address at that point, none structural: mark the intended surface `public` (including inits — Swift won't synthesize public ones); move the app-specific bits out of the generic bits (ALPN becomes a constructor parameter, `handle`'s switch becomes a pluggable handler registry, `MyState` belongs to the app); and clean up the remaining `Sendable` warnings, since a library exports its concurrency story to Swift 6 consumers. Deliberately deferred until the prototype proves out — public-API decisions come easier after you've felt which parts you reach for.
- **Third peer**: spin up `peer-c`, add A and B to its roster, and watch the full mesh converge — no code changes needed.
