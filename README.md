# Aspen

Aspen is a small Swift library for peer-to-peer state sync over [iroh](https://iroh.computer): peers dial each other directly by EndpointId, exchange typed envelope messages over QUIC streams, and periodically pull state updates from a roster of known peers. The repo also ships four examples — `party`, the reference CLI that syncs a list of records between peers; `identity` and `identitychain`, two takes on grouping many devices under one human's root identity; and StatusBoard, a SwiftUI iOS app. The library and CLIs are plain SwiftPM on top of [iroh-ffi](https://github.com/n0-computer/iroh-ffi)'s prebuilt xcframework — no Rust toolchain, no Xcode project; only the iOS example carries a (tiny) Xcode project, because iOS app bundles require one.

## Sync model

Every piece of app state carries a sequence number that only increases, bumped by the owner on each change. For each peer on the roster, the library keeps a cursor: the highest seq it has seen from that peer. On every contact — whether this node dialed or was dialed — both sides run the same short exchange: a `sync/hello` carrying my current seq and my cursor of you, then app state envelopes only if the other side's cursor says it's behind, then `sync/bye`. It's last-write-wins with a local counter, so there are no clocks to trust, and when nothing has changed a contact costs two tiny frames each way — cheap enough to sweep the whole roster every 30 seconds.

Dials race a deadline (default 5 seconds), and the sweep pings all peers concurrently, so a dead peer costs one timeout, not a stalled sweep. Teardown is bounded the same way: `stop()` gives the endpoint 5 seconds to close and then returns regardless, because a stalled relay must not hang shutdown. Peers you never added show up on your roster the first time they dial you, which is how a mesh grows from one side adding the other.

## Envelopes

Messages are JSON envelopes — `contentType`, `sender`, `seq`, opaque `payload` — length-prefixed on the wire. The header exists so the sync layer can route and order without understanding any payload; what the payload means belongs entirely to the app. Additive protocol changes are new content types (an old peer logs and skips what it doesn't know); breaking changes are a new ALPN string (old and new peers simply never complete a handshake).

## What Aspen owns vs. what your app owns

Aspen owns the transport (endpoint, accept loop, deadline dials), the roster with its cursors and cached direct addresses, and the sync exchange. It also owns the endpoint key: `Identity.loadOrCreate` keeps an Ed25519 secret in `identity.key`, readable even while the machine is locked, and throws rather than regenerate if the file exists but can't be read — an unreadable key must never silently become a new endpoint id. Your app owns its state model and persistence, and hands the library three things:

- **An ALPN** naming your protocol, passed to `Node(identity:roster:alpn:...)` — every app picks its own, e.g. `Data("myapp/0".utf8)`.
- **A state provider**, an async closure returning `OutboundState` — the current seq plus the envelope items to send when a peer is behind. It's called once per contact, so seq and payloads are read as one consistent snapshot.
- **Handlers** registered per content type with `node.on("state/thing") { envelope, remote in ... }` before `start()`. Aspen gates staleness by seq and advances the cursor after your handler runs; the handler just interprets the payload.

Two optional knobs on the initializer: `log:` surfaces accept-loop errors and ignored envelopes (the library never prints on its own), and `preset:` configures the iroh endpoint — `presetN0()` (the default) uses n0's public relays and DNS discovery, while `presetMinimal()` binds with no external dependencies for direct-address dialing, which is what the tests use to run offline. A node's current direct addresses are available from `directAddresses()` after `start()`; handed to a peer out-of-band and cached on its roster, they let a dial succeed even when discovery is slow or down.

## Layout

```
Package.swift             # library Aspen + executables party, identity, identitychain
Sources/
└── Aspen/
    ├── Identity.swift    # Ed25519 secret key on disk; EndpointId is public key
    ├── Wire.swift        # Envelope + length-prefixed framing over QUIC streams
    ├── Roster.swift      # Peer records, cursors, cached addrs (roster.json)
    └── Node.swift        # endpoint bind, accept loop, deadline dials, sync exchange
Tests/
└── AspenTests/           # unit tests + an end-to-end sync over loopback (presetMinimal)
Examples/
├── Party/                # reference CLI: init | peer | state | watch
├── Identity/             # root identity signs each device directly; secret moves via export/import
├── IdentityChain/        # devices vouch for each other in a chain back to the root; adds revocation
└── StatusBoard/          # SwiftUI iOS app; Xcode project depends on ../.. by path
    └── StatusBoard/
        ├── App.swift          # node lifecycle tied to scenePhase
        ├── SyncManager.swift  # owns Identity/Roster/Node, sweeps every 30s
        ├── StatusStore.swift  # persists my status + statuses heard from peers
        └── RootView.swift     # share my id, add peers, see everyone's status
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

## Examples

### Party (reference CLI)

Each `--path`/`-p` store directory (default `~/.config`) holds one peer's keys, roster, and state, which is how several peers run on one machine:

```bash
swift build --product party
party="$(swift build --show-bin-path)/party"

# Terminal A
"$party" init -p "$HOME/tmp/peer-a"                  # prints A's endpoint id
"$party" state add -p "$HOME/tmp/peer-a" "hello from A"
"$party" watch -p "$HOME/tmp/peer-a"

# Terminal B
"$party" peer add -p "$HOME/tmp/peer-b" <A's id>
"$party" state add -p "$HOME/tmp/peer-b" "B checking in"
"$party" watch -p "$HOME/tmp/peer-b"
```

Within one sweep each terminal prints the other's records — including terminal A, which never added B.

### Identity and IdentityChain

Both build a "one human, many devices" layer on top of the sync: a long-lived root key identifies the human, devices carry proof of membership in their gossiped state, and `peer list` groups endpoints by verified root instead of listing them flat. They differ in how a device gets its proof. In `identity`, the root secret travels to each device (`root export` / `root import`) and signs each one directly. In `identitychain`, the root secret never leaves the founding device: any enrolled device vouches for the next, proofs are chains of signatures, and signed revocations — with authority flowing only down the chain — cut devices off. The trade-offs are the subject matter; [Examples/IdentityChain/README.md](Examples/IdentityChain/README.md) walks through them.

### StatusBoard (iOS)

Open `Examples/StatusBoard/StatusBoard.xcodeproj` and run — the project depends on the Aspen package by relative path, so there's nothing to resolve or configure beyond a signing team (and a unique bundle id in place of `com.example.StatusBoard`) if you're deploying to a device; the simulator needs neither. It's the party CLI with a UI: share your endpoint id from one device, paste it on another, and both statuses converge within a sweep. It also shows the two things an iOS integration adds:

- **Lifecycle**: a stopped `Node` can't be restarted and suspension kills its sockets, so the app builds a fresh node on every return to foreground (`scenePhase`) — cheap, because identity, roster, and cursors are on disk.
- **Persisting received state**: cursors mean a peer never re-sends what you've already seen, so the app writes statuses it hears to disk instead of holding them in memory like the CLI's print handler does.

`NSLocalNetworkUsageDescription` is set in the project; without it iOS blocks the direct LAN paths and traffic falls back to relays.

## Tests

`swift test` runs the suite, including an end-to-end sync between two real iroh endpoints wired together by direct address over loopback — `presetMinimal()` means no relays or discovery are involved, so the tests pass offline.

## Limits and non-goals

This is a prototype-grade library. State is whatever fits the single-seq model — last-write-wins, no CRDTs or version vectors. Sync is full-mesh only; peers don't gossip or relay for each other. The secret key is a file under Data Protection, not the Keychain. The package builds in Swift 6 language mode with strict concurrency enforced; `Node` and `Roster` are actors.
