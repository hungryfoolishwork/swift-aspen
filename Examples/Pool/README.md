# Pool

[Party](../Party) with the walls knocked down: instead of each peer keeping its own records and everyone else's in separate piles, every device merges everything into one shared set. It models one person's devices — a laptop, a phone, a desktop — converging on a single ledger, which is why records carry no author. Add or edit a record on any device and the whole mesh ends up with the same pool.

## The merge rule

There is no CRDT library here — just a dictionary union, which is all a grow-only set needs:

- Every record gets a stable `id` (a UUID stamped once at creation), so the same record arriving via two paths dedupes instead of duplicating.
- `merge` inserts ids it hasn't seen and, for ids it has, keeps whichever edit has the newer `updatedAt` — last write wins on device clocks, which is a fair bet when all the clocks belong to one person. Ties break on the text itself, so every device resolves the same conflict the same way.
- Union is idempotent and order-independent, so devices converge no matter who talks to whom in what order.

The one line that makes gossip flow: a merge that changed anything **bumps `seq`**, not just local edits. In Party, seq moves only on your own changes; in Pool, absorbing another device's records is also news your other peers haven't heard. The bump makes them pull it on the next contact, and the handler sweeps immediately so it travels without waiting — device C learns device A's records through B even if A and C never connect.

Deletion is deliberately out of scope: an append-and-update set converges for free, while removal needs tombstones (keep the id, mark it dead) so a delete isn't resurrected by the next merge. That's the natural next step if you extend this example.

## Anatomy

The same three files as Party, same responsibilities:

- **`Main.swift`** — the CLI (`init | peer | record | watch`). `record update` takes a unique prefix of the id shown by `record`, so you don't type whole UUIDs.
- **`Session.swift`** — the integration layer: `Identity` and `Roster` from the store directory, a `Node` with this app's ALPN (`example-pool/0`), a state provider that snapshots the merged pool, and a handler that merges inbound pools and relays fresh news. The provider reads the ledger fresh on every exchange, so what goes out is the pool as of now.
- **`Ledger.swift`** — the app-owned state: one record dictionary keyed by id, the merge rule, and the seq. One JSON file, `snapshot.json`, under `example-pool/` in the store directory (`--path`/`-p`, default `~/.config`).

## Commands

```bash
pool init                        # create or load this store's identity, print its endpoint id
pool peer add <id>               # put a peer on the roster and ping it
pool peer                        # list peers with last-seen times
pool record add <text>           # add a record to the pool and push it
pool record update <id> <text>   # rewrite a record (id prefix is enough)
pool record                      # sweep, then print the merged pool
pool watch                       # stay online, printing the pool as it converges
```

To see it work on one machine, run two stores: `pool -p /tmp/a init`, `pool -p /tmp/b init`, cross-add the printed ids with `peer add`, then `watch` one store while you `record add` and `record update` from the other — both sides settle on the identical list.
