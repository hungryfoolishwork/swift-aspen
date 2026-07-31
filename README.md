# Aspen

Aspen is a small Swift library for peer-to-peer state sync over [iroh](https://iroh.computer): peers dial each other directly by EndpointId, exchange typed envelope messages over QUIC streams, and periodically pull state updates from a roster of known peers. The repo also ships `demo`, a command-line demo app that syncs a single status string between peers — it doubles as the reference integration. Everything is plain SwiftPM on top of [iroh-ffi](https://github.com/n0-computer/iroh-ffi)'s prebuilt xcframework; no Rust toolchain, no Xcode project.

## Sync model

Every piece of app state carries a sequence number that only increases, bumped by the owner on each change. For each peer on the roster, the library keeps a cursor: the highest seq it has seen from that peer. On every contact — whether this node dialed or was dialed — both sides run the same short exchange: a `sync/hello` carrying my current seq and my cursor of you, then app state envelopes only if the other side's cursor says it's behind, then `sync/bye`. It's last-write-wins with a local counter, so there are no clocks to trust, and when nothing has changed a contact costs two tiny frames each way — cheap enough to sweep the whole roster every 30 seconds.

Dials race a deadline (default 5 seconds), and the sweep pings all peers concurrently, so a dead peer costs one timeout, not a stalled sweep. Peers you never added show up on your roster the first time they dial you, which is how a mesh grows from one side adding the other.

## Envelopes

Messages are JSON envelopes — `contentType`, `sender`, `seq`, opaque `payload` — length-prefixed on the wire. The header exists so the sync layer can route and order without understanding any payload; what the payload means belongs entirely to the app. Additive protocol changes are new content types (an old peer logs and skips what it doesn't know); breaking changes are a new ALPN string (old and new peers simply never complete a handshake).

## What Aspen owns vs. what your app owns

Aspen owns the transport (endpoint, accept loop, deadline dials), the roster with its cursors and cached direct addresses, and the sync exchange. Your app owns its state model and persistence, and hands the library three things:

- **An ALPN** naming your protocol, passed to `Node(identity:roster:alpn:...)` — every app picks its own, e.g. `Data("myapp/0".utf8)`.
- **A state provider**, an async closure returning `OutboundState` — the current seq plus the envelope items to send when a peer is behind. It's called once per contact, so seq and payloads are read as one consistent snapshot.
- **Handlers** registered per content type with `node.on("state/thing") { envelope, remote in ... }` before `start()`. Aspen gates staleness by seq and advances the cursor after your handler runs; the handler just interprets the payload.

Optionally pass `log:` to the initializer to see accept-loop errors and ignored envelopes; the library never prints on its own.

## Layout

```
Package.swift            # library product Aspen + executable demo
Sources/
├── Aspen/
│   ├── Identity.swift   # Ed25519 secret key on disk; EndpointId is public key
│   ├── Wire.swift       # Envelope + length-prefixed framing over QUIC streams
│   ├── Roster.swift     # Peer records, cursors, cached addrs (roster.json)
│   └── Node.swift       # endpoint bind, accept loop, deadline dials, sync exchange
└── demo/
    ├── Demo.swift       # CLI: id | add | status | run, --dir state directories
    └── StatusStore.swift # the app-owned state: one status string under a seq
```

## Importing Aspen

From a local checkout:

```swift
dependencies: [
    .package(path: "../Aspen"),
],
targets: [
    .target(name: "myapp", dependencies: [
        .product(name: "Aspen", package: "Aspen"),
    ]),
]
```

## Demo

```bash
swift build

# Terminal A
swift run demo --dir ~/tmp/peer-a id        # copy this
swift run demo --dir ~/tmp/peer-a status "hello from A"
swift run demo --dir ~/tmp/peer-a run

# Terminal B
swift run demo --dir ~/tmp/peer-b add <A's id>
swift run demo --dir ~/tmp/peer-b status "B checking in"
swift run demo --dir ~/tmp/peer-b run
```

Within one sweep each terminal prints the other's status — including terminal A, which never added B. Each `--dir` (default `~/.config/demo/`) holds one peer's `identity.key`, `roster.json`, and `state.json`, which is how several peers run on one machine.

## Limits and non-goals

This is a prototype-grade library. State is whatever fits the single-seq model — last-write-wins, no CRDTs or version vectors. Sync is full-mesh only; peers don't gossip or relay for each other. The secret key is a plain file, not Keychain. The package builds in Swift 6 language mode with strict concurrency enforced; `Node` and `Roster` are actors.
