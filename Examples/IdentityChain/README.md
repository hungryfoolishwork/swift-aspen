# IdentityChain

A CLI example on top of Aspen where one human owns many devices, and each device proves membership with a chain of signatures leading back to the human's root key. The root secret never leaves the founding device: enrollment means an already-enrolled device vouching for the newcomer, and revocation is a signed, gossiped record whose authority flows only down the chain. The payoff is in `peer list` — a pile of endpoint ids collapses into humans, each with their devices grouped under a verified root.

This is the chain-of-trust variant of [`../Identity`](../Identity), which solves the same problem by moving the root secret to every device so it can sign each one directly. Here the trade flips: no secret ever travels, any device can enroll the next, and in exchange verification must walk a chain and revocation gets interesting.

## Keys

Each device holds three keys, with distinct jobs:

- **Endpoint key** — the iroh transport key (`identity.key`), managed by the Aspen library. It authenticates connections; its public half is the endpoint id peers dial.
- **Device signing key** — this example's identity key (`keyring.json`). It signs enrollments and revocations. Kept separate from the endpoint key because the transport key shouldn't double as the identity key.
- **Root key** — the human's long-lived key, generated at `init` and present only on the founding device. Its public half is the human's stable identifier. It signs exactly one thing — the founding device's first link — and could be deleted afterwards, at the cost of never founding another chain.

## Chains

A `DeviceChain` is a list of `Link`s from the root down to one device. Each link is a signed statement: whoever holds `parent` vouches that the device holding `child`, reachable at endpoint `device`, belongs to this identity. The first link's parent is the root key; every later link is signed by an already-enrolled device's key.

Verifying a chain means checking every signature, checking each link's parent is the previous link's child, and checking the final link names the endpoint that actually sent it — that last binding is what stops one peer replaying another's chain. Chains ride along in gossiped state, so verification needs nothing but the chain itself plus the revocation set.

Trust is transitive: every device on the path vouched for the next one, so a compromised device can enroll impostors until it's revoked. That is the cost of enrollment without the root secret.

## Enrollment

Three steps, hand-carrying base64 blobs that contain only public material:

1. `enroll request` on the new device prints its endpoint id and device signing key.
2. `enroll approve <blob>` on any enrolled device extends its own chain with a link for the requester and prints the grant. Signed with the device key — the root plays no part, which is the point.
3. `enroll accept <blob>` back on the new device adopts the granted chain, replacing the self-founded one it got at `init`.

A device that knows it is revoked refuses to approve, and a grant that passes through a key the acceptor knows is burned is refused.

## Revocation

`revoke <endpoint-id>` signs a `Revocation`: "key X is burned." Revocations are self-authenticating, permanent, and gossiped as a grow-only set — every device merges signature-valid records from any sender and re-gossips the union, so the news spreads through whatever sync paths exist. There is no un-revoke; a recovered device re-enrolls with a fresh key.

Whether a revocation has any effect is decided by each verifier, per chain: it counts only if its signer is the root or a key that appears earlier on that same chain. Authority flows only downward — ancestors can cut off what they vouched for, while a stolen leaf can't revoke the tree above it, siblings can't touch each other, and a revoked device's own revocations die with its place on the path. Revoking a mid-chain device also cuts every chain that runs through it. Because a revocation can arrive long after the chain it cuts, validity is evaluated when chains are read (`peer list`, `watch`, `chain show`), not when they're received.

The honest limits: a revocation only protects peers it has reached — until it syncs, a device accepts grants through the burned key — and a compromised founding device is unrecoverable, since it outranks everything. Real systems answer that with external anchors or key rotation; this example just says it out loud.

## Layout

```
Main.swift     # CLI: init | chain | enroll | revoke | peer | state | watch
Chain.swift    # Link, DeviceChain, Revocation, Keyring — all the crypto
Session.swift  # wires the Keyring and Ledger to an Aspen Node; enrollment, revocation, merging
Ledger.swift   # snapshot.json: own state, last-seen peer states, the revocation set
```

Each store directory (`--path`, default `~/.config`) gets an `example-identitychain/` folder holding `identity.key`, `keyring.json`, `roster.json`, and `snapshot.json` — which is how several devices run on one machine. The sync layer underneath (seqs, cursors, envelopes, the 30-second sweep) is Aspen's; see the [root README](../../README.md).

## Running it

```bash
swift build --product identitychain
idc="$(swift build --show-bin-path)/identitychain"

# The laptop founds an identity; the phone starts as its own one-device island
"$idc" init -p "$HOME/tmp/laptop"
"$idc" init -p "$HOME/tmp/phone"

# Enroll the phone: request → approve → accept, no secrets moved
req=$("$idc" enroll request -p "$HOME/tmp/phone")
grant=$("$idc" enroll approve -p "$HOME/tmp/laptop" "$req")
"$idc" enroll accept -p "$HOME/tmp/phone" "$grant"

# The phone's proof now walks back to the laptop's root
"$idc" chain show -p "$HOME/tmp/phone"
```

Enrolled is not yet connected — introduce the devices to the sync layer like any Aspen peers, then watch state and chains flow:

```bash
"$idc" peer add -p "$HOME/tmp/phone" <laptop endpoint id>   # id printed by init
"$idc" watch -p "$HOME/tmp/laptop"                          # leave running

# in another terminal
"$idc" state add -p "$HOME/tmp/phone" "hello from the phone"
"$idc" peer list -p "$HOME/tmp/phone"                       # devices grouped by root
```

The laptop never added the phone — being dialed grew its roster, and the exchange runs both ways, so each side ends up holding the other's chain.

A third device enrolled by the phone demonstrates the chain growing without the root: run the same request/approve/accept round against `-p "$HOME/tmp/tablet"` with the phone approving. And to burn a device:

```bash
"$idc" revoke -p "$HOME/tmp/laptop" <phone endpoint id>
```

The revocation needs the target's chain to have synced to the revoking device first, and it spreads from there — `chain show` on the phone reports `Valid: false` once it hears, and everyone's `peer list` moves the phone to a `Revoked` section.
