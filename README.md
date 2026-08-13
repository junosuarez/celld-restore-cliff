# celld restore cliff — minimal reproduction

A [celld](https://github.com/denoland/celld) cell becomes **permanently unactivatable** once its
LTX replica chain outgrows the activation deadline. Every request triggers a full restore, the
restore outlives the request, the work is discarded, and the next request repeats it. The daemon
stays healthy; one cell is simply gone.

```sh
./run.sh                      # celld v0.2.0 (default): recovers — the fix works
CELLD_VERSION=v0.1.0 ./run.sh # the original failure: hangs forever
```

About two minutes, one command. Needs Docker (or Podman) and `curl`.

**Fixed in celld v0.2.0** ([denoland/celld#143](https://github.com/denoland/celld/issues/143)),
which added LTX compaction (~256:1) and 64-way restore concurrency. This repo now serves two
purposes: `CELLD_VERSION=v0.1.0` still demonstrates the original bug, and the default runs as a
regression test that it stays fixed. Tag `v0.1.0` marks the state of this repo when the bug was
live.

There is also `./run-backlog.sh`, a second probe described at the end.

## What you should see

```
== 4/6  starting celld, then 2000 writes at full speed (no latency yet)
   done in 36s — counter is now {"n":2002,"url":"http://localhost:18080/"}

== 5/6  injecting 60ms latency on every object fetch
== 6/6  killing celld — the cell must now be rebuilt from the bucket

== RESULT
  t+10  s ... route failed: RestoreFailed [500]
  t+20  s  [000]
  ...
  t+120 s  [000]

REPRODUCED — the cell is permanently unactivatable.
  completed-and-discarded restores so far: 6
  INFO celld::ltx_repl: restored remote replica cell="Counter:32f7ce…" from=1 to=2
  INFO celld::ltx_repl: restored remote replica cell="Counter:32f7ce…" from=1 to=2
```

The counter reached 2002 and is now unreachable. `from`/`to` never advance, because activation
never completes.

## Why it happens

`activate()` calls `replica::restore(client, dst, TXID(0))`, which downloads the whole restore
plan **serially — one object per round trip**. Without compaction the plan is every L0 file the
cell has ever written, so restore time scales with lifetime transaction count, not data size.

The request that triggered activation times out first. Because activation runs on that request's
task it is cancelled at the next await, and the following attempt calls `remove_file(&dst)` and
starts over — so no progress carries between attempts. Past a threshold, no request ever lives
long enough to see a restore finish.

It is a livelock, not a race: once restore time exceeds the deadline, the outcome is
deterministic. There is no lucky schedule to wait for.

## Why latency is injected

The failure condition is

```
chain_length × per-object fetch latency  >  activation deadline
```

Against a local MinIO with sub-millisecond objects you would need roughly ten thousand of them
to cross it. Toxiproxy sits between celld and MinIO, and `run.sh` adds the latency **after** the
chain is built — so the write phase runs at full speed and a couple of thousand writes suffice.

Both knobs push on the same product:

```sh
./run.sh 5000 40      # more writes, less latency
./run.sh 800 150      # fewer writes, more latency
```

If a run prints `NOT REPRODUCED`, the chain still fits inside the deadline; the script tells you
what to try next.

That product is also why the threshold belongs to *celld × the store* rather than to celld: a
faster store buys proportionally more headroom, a WAN-latency one far less.

## Observed on real infrastructure

Without injected latency, on a 3-node fleet against an S3 store averaging ~2 ms per object:

| writes | LTX objects | chain | activation |
|---|---|---|---|
| 3 | 1 | 1 MB | 0.17 s |
| 7,395 | 2,334 | 146 MB | 4.35 s |
| 8,191 | 2,585 | 162 MB | 8.16 s |
| 37,233 | 10,675 | 668 MB | **never completes** |

The workload is a single row, updated. That cell's live SQLite database is **36 KB** behind a
**668 MB** chain, and object size is a constant ~62.6 KB regardless of cell, so the chain is
purely a function of transaction count. Each log file is larger than the whole database it
describes.

Two smaller things in the same code path: `restore` accumulates every file into a
`Vec<Vec<u8>>` before merging, so the entire chain is resident in memory during a restore (668 MB
in that case) — a large enough cell is OOM-killed rather than timing out; and a cell that cannot
possibly restore inside the deadline retries forever rather than reporting why.

## Notes

- **celld v0.1.0**, the current release. It publishes no container image past v0.0.2, so `run.sh`
  fetches the release binary and verifies its SHA-256. Works on arm64 and x86_64.
- **One node on purpose.** The cliff is about restore time versus the deadline, not ownership
  handoff — a lone node restarting rebuilds from the bucket too, so one node shows it.
- **The worker is stock.** `worker/` is `examples/counter` copied verbatim from celld; every
  request hits `room-42`, so driving `/` is driving one cell. See `NOTICE`.
- Compaction is presumably the intended fix, and the code anticipates it (`replica.rs`, *"L0-only
  … so adding compaction later 'just works'"*). Until then, either carrying restore progress
  across attempts or running activation off the request path would break the loop on its own.

## `run-backlog.sh` — a probe that (correctly) fails to reproduce

Model-checking v0.2.0's compaction suggested a surviving liveness hole: compaction runs only on
a **resident, owned** cell, so it cannot rescue a cell that has already grown too large to open —
opening it is exactly what is impossible. The way in would be upstream's own rolling-upgrade
instruction, `CELLD_LTX_COMPACTION=0` on every node, during which a write-hot cell rebuilds an
uncompacted backlog.

`run-backlog.sh` builds that backlog and then "finishes the upgrade" by restarting with
compaction on. **It does not reproduce**, and the reason is worth stating: the deadlock needs one
more premise — that a restore outliving its triggering request is *discarded*. v0.1.0 did that.
v0.2.0 does not. Measured here with a **16,019-object** uncompacted backlog at 250 ms/object, the
cell recovered in ~48 s while individual requests were timing out at 12 s.

So it is kept as a **regression test** for the property that makes the rest safe: activation must
outlive the request that triggered it. If that ever regresses, compaction cannot paper over it.

One incidental finding from building it: inject enough latency (~3 s/object) and celld halts with
`SELF-FENCE: node lease not renewed within TTL` (exit 3) rather than serving. That is correct —
a node that cannot reach the store must not keep owning cells — but it means a sufficiently slow
store takes the whole node down, not one cell. It also puts a ceiling on latency injection as a
test technique, since the lease TTL trips before the restore deadline does.

## `run-backlog.sh` — a probe that (correctly) fails to reproduce

Model-checking v0.2.0's compaction suggested a surviving liveness hole: compaction runs only on
a **resident, owned** cell, so it cannot rescue a cell that has already grown too large to open —
opening it is exactly what is impossible. The way in would be upstream's own rolling-upgrade
instruction, `CELLD_LTX_COMPACTION=0` on every node, during which a write-hot cell rebuilds an
uncompacted backlog.

`run-backlog.sh` builds that backlog and then "finishes the upgrade" by restarting with
compaction on. **It does not reproduce**, and the reason is worth stating: the deadlock needs one
more premise — that a restore outliving its triggering request is *discarded*. v0.1.0 did that.
v0.2.0 does not. Measured here with a **16,019-object** uncompacted backlog at 250 ms/object, the
cell recovered in ~48 s while individual requests were timing out at 12 s.

So it is kept as a **regression test** for the property that makes the rest safe: activation must
outlive the request that triggered it. If that ever regresses, compaction cannot paper over it.

One incidental finding from building it: inject enough latency (~3 s/object) and celld halts with
`SELF-FENCE: node lease not renewed within TTL` (exit 3) rather than serving. That is correct —
a node that cannot reach the store must not keep owning cells — but it means a sufficiently slow
store takes the whole node down, not one cell. It also puts a ceiling on latency injection as a
test technique, since the lease TTL trips before the restore deadline does.

## Teardown

```sh
docker compose down -v
```
