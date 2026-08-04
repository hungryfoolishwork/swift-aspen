# Party

The reference Aspen integration: the smallest complete app on the library, a CLI where each peer keeps a list of text records and every peer converges on everyone's records within a sweep. The other examples copy this file-for-file shape and add layers on top — read this one first to see what belongs to an app and what the library already does.

## Anatomy

Three files, three responsibilities:

- **`Main.swift`** — the CLI (`init | peer | state | watch`). Every subcommand is one-shot: build a `Session`, start it if the command needs the network, act, stop, exit. Only `watch` stays running.
- **`Session.swift`** — the integration layer, and the file worth studying. It owns the pieces Aspen hands an app: an `Identity` and `Roster` loaded from the store directory, and a `Node` built at `start()` with the app's ALPN (`example-party/0`), a state provider that snapshots the ledger into one JSON envelope, and a handler that decodes peer state back into the ledger. It also drives the rhythm: a sweep pinging every rostered peer at startup and every 30 seconds after.
- **`Ledger.swift`** — the app-owned state and persistence Aspen deliberately knows nothing about: my records, the last state heard from each peer, and the seq that bumps on every local change so the sync layer knows who's behind. One JSON file, `snapshot.json`.

Each store directory (`--path`/`-p`, default `~/.config`) gets an `example-party/` folder holding `identity.key`, `roster.json`, and `snapshot.json`, which is how several peers run on one machine.

## Commands

```bash
party init                # create or load this store's identity, print its endpoint id
party peer add <id>       # put a peer on the roster and ping it
party peer                # list peers with record counts and last-seen times
party state add <text>    # append a record and push to peers
party state               # print my records
party watch               # stay online, printing everyone's records as they change
```

The two-terminal walkthrough lives in the [root README](../../README.md) — including the part where peer A never adds B but hears from it anyway, because being dialed grows the roster.

## Where the other examples go from here

[`../Pool`](../Pool) keeps the structure but merges every device's records into one shared set — one person's devices converging on a single ledger instead of keeping per-peer piles. [`../Identity`](../Identity) and [`../IdentityChain`](../IdentityChain) add one concern: proving which human owns each device, so `peer list` can group endpoints by identity instead of listing them flat.
