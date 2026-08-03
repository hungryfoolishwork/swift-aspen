# Identity

A CLI example on top of Aspen where one human owns many devices: a long-lived root key identifies the human, and every device carries a certificate — signed by that root — binding its endpoint to it. Certificates ride along in gossiped state, so `peer list` collapses a pile of endpoint ids into humans with their devices grouped under a verified root.

This is the direct-signing variant of [`../IdentityChain`](../IdentityChain), which solves the same problem without ever moving the root secret. Here the root secret travels to each device (`root export` / `root import`) and signs each certificate itself. The trade: enrollment requires carrying the secret, and every device holding it is a full-blast-radius compromise — but verification is a single signature check, there are no chains to walk, and no revocation-ordering questions to answer.

## Roots and certificates

`init` gives every store a root of its own — a CryptoKit signing keypair in `root.json` — so each device starts as a one-device identity. Enrolling a device into an existing identity means replacing its root: `root export` on an enrolled device prints the secret base64-encoded, `root import` on the new device adopts it and re-certifies. The root's public key is the human's stable identifier; devices come and go underneath it.

A `DeviceCert` is the root's signed statement that an endpoint belongs to it: root public key, device endpoint id, an issuance counter, and a signature over a domain-separated message. The gossiped state field is proof, not claim — receivers verify the signature and, critically, that the cert names the endpoint that actually sent it, which is what stops one peer replaying another's cert. A cert that fails either check is stripped on receive: the peer's records still sync, but it lands in `Unverified` instead of a root group.

Certs carry a monotonic counter so a re-issued cert supersedes older ones — that is the hook revocation would hang off, deliberately left unbuilt here. Revocation is the subject of the [IdentityChain example](../IdentityChain/README.md), where it earns its complexity.

## Layout

```
Main.swift     # CLI: init | root | peer | state | watch
Root.swift     # Root keypair + DeviceCert — all the crypto
Session.swift  # wires Root and Ledger to an Aspen Node; certifies at startup, verifies on receive
Ledger.swift   # snapshot.json: own state (records + cert), last-seen peer states
```

Each store directory (`--path`/`-p`, default `~/.config`) gets an `example-identity/` folder holding `identity.key`, `root.json`, `roster.json`, and `snapshot.json` — which is how several devices run on one machine. The structure is [Party](../Party) plus `Root.swift`; the sync layer underneath is Aspen's, covered in the [root README](../../README.md).

## Running it

```bash
swift build --product identity
idn="$(swift build --show-bin-path)/identity"

# Two devices, each initially its own identity
"$idn" init -p "$HOME/tmp/laptop"     # prints device endpoint id + root id
"$idn" init -p "$HOME/tmp/phone"

# Enroll the phone: carry the root secret over and re-certify
blob=$("$idn" root export -p "$HOME/tmp/laptop")
"$idn" root import -p "$HOME/tmp/phone" "$blob"
"$idn" root show -p "$HOME/tmp/phone"   # same root as the laptop now, cert valid
```

Enrolled is not yet connected — introduce the devices like any Aspen peers, then watch the grouping appear:

```bash
"$idn" peer add -p "$HOME/tmp/phone" <laptop endpoint id>   # id printed by init
"$idn" watch -p "$HOME/tmp/laptop"                          # leave running

# in another terminal
"$idn" state add -p "$HOME/tmp/phone" "hello from the phone"
"$idn" peer list -p "$HOME/tmp/phone"                       # devices grouped by root, yours marked "mine"
```

The laptop never added the phone — being dialed grew its roster, and the exchange runs both ways, so each side ends up holding the other's cert.

A device with a different root — any store you `init` and don't enroll — shows up under its own root group: a different human.
