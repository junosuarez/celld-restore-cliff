#!/usr/bin/env bash
# Regression probe: activation must outlive the request that triggered it.
#
# RESULT ON v0.2.0: does not reproduce. Kept as a regression test, because the
# property it checks is the one that made v0.1.0 fatal.
#
# Model-checking v0.2.0's compaction (CelldCompaction.tla in the cave repo)
# predicted a surviving liveness hole:
#
#   compaction only runs on a RESIDENT, OWNED cell (maybe_queue_compaction is
#   called from the durable-sync path, and cancel_compaction drops the queued
#   attempt when the cell goes away)
#
# so compaction cannot rescue a cell that has already grown too large to open.
#
# That deadlock needs one more premise: that a restore which outlives its
# triggering request is DISCARDED. v0.1.0 did exactly that. v0.2.0 does not —
# measured here with a 16,019-object uncompacted backlog at 250ms/object, the
# cell recovered in ~48s while individual requests were timing out at 12s. So
# the modelled deadlock is unreachable as shipped, and the model's value is in
# naming the property that has to keep holding.
#
# The way in is upstream's own instruction. For a mixed-version rolling upgrade
# the docs say to set CELLD_LTX_COMPACTION=0 on EVERY node, because "an old
# reader cannot take over a cell after its first L1 publication". During that
# window a write-hot cell accumulates an uncompacted tail exactly as it did in
# v0.1.0. This script uses that window, then finishes the upgrade by turning
# compaction back on — and asks whether the cell can dig itself out.
#
#   ./run-backlog.sh              4000 writes, 500ms latency
#   ./run-backlog.sh 8000 300     more writes, less latency
#
# Compare with ./run.sh, which is the same shape but leaves compaction on
# throughout and therefore never builds the backlog.
set -euo pipefail

WRITES=${1:-4000}
LATENCY_MS=${2:-500}

if command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
elif docker compose version >/dev/null 2>&1;  then COMPOSE="docker compose"
elif command -v podman-compose >/dev/null 2>&1; then COMPOSE="podman-compose"
else echo "need docker compose or podman-compose" >&2; exit 1; fi
COMPOSE=${COMPOSE_OVERRIDE:-$COMPOSE}

API=http://localhost:8474
APP=http://localhost:18080

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
poll() { curl -s -m 12 -w ' [%{http_code}]' "$APP/" 2>/dev/null | tail -c 110; }

trap 'printf "\nteardown:  %s down -v\n" "$COMPOSE"' EXIT

say "1/7  MinIO + Toxiproxy"
$COMPOSE up -d minio toxiproxy
for _ in $(seq 30); do curl -fsS "$API/proxies" >/dev/null 2>&1 && break; sleep 1; done

say "2/7  bucket, celld ${CELLD_VERSION:-v0.2.0}, esbuild"
$COMPOSE run --rm createbucket >/dev/null
$COMPOSE run --rm tools

say "3/7  deploying the stock examples/counter worker"
$COMPOSE run --rm deploy 2>&1 | grep -E "Version ID|error" || true

say "4/7  starting celld with CELLD_LTX_COMPACTION=0 (the rolling-upgrade window)"
CELLD_LTX_COMPACTION=0 $COMPOSE up -d celld
up=0
for _ in $(seq 60); do
  if curl -fsS -m 2 "$APP/" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "$up" = 1 ] || { echo "celld did not come up:"; $COMPOSE logs --tail=20 celld; exit 1; }
start=$(date +%s)
for _ in $(seq "$WRITES"); do curl -fsS -m 5 "$APP/" >/dev/null 2>&1 || true; done
echo "   $WRITES writes in $(( $(date +%s) - start ))s — counter $(curl -fsS -m 5 "$APP/")"

say "5/7  confirming the tail is uncompacted (expect L0 only, no 0001)"
$COMPOSE run --rm --entrypoint sh createbucket -c '
  mc alias set m http://minio:9000 celld celldcelld >/dev/null 2>&1
  mc ls --recursive m/celld/cells > /tmp/o.txt 2>/dev/null || true
  echo -n "   objects: "; wc -l < /tmp/o.txt
  echo -n "   L1 (compacted) objects: "; grep -c "/0001/" /tmp/o.txt || echo 0
' 2>/dev/null | grep -E "objects" || true

say "6/7  injecting ${LATENCY_MS}ms per-object latency, then killing celld"
curl -fsS -X POST "$API/proxies/store/toxics" -H 'Content-Type: application/json' \
  -d "{\"name\":\"slow\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$LATENCY_MS,\"jitter\":0}}" \
  >/dev/null
$COMPOSE kill celld >/dev/null 2>&1 || true

say "7/7  restarting WITH compaction enabled — the upgrade is 'finished'"
CELLD_LTX_COMPACTION=1 $COMPOSE up -d celld
sleep 5

say "RESULT — can a fixed node dig the cell out?"
# Poll well past the expected restore time: at LATENCY_MS per object, 64-way,
# a chain of N needs about N/64*LATENCY seconds. Declaring "stuck" before that
# has elapsed just measures impatience.
expect_s=$(( WRITES * LATENCY_MS / 64 / 1000 ))
echo "   expected restore ~${expect_s}s; polling to $(( expect_s * 3 + 120 ))s"
recovered=0
node_died=0
deadline=$(( $(date +%s) + expect_s * 3 + 120 ))
t0=$(date +%s)
while [ "$(date +%s)" -lt "$deadline" ]; do
  # A halted node is NOT a stuck cell. celld self-fences and exits when it
  # cannot renew its node lease, which high store latency alone can cause —
  # that is correct behaviour and a different finding entirely.
  # NB: `compose ps <service>` is not portable (podman-compose rejects the
  # argument and prints usage), which silently made this guard fire on a
  # healthy node. Match the container by name instead.
  if ! $COMPOSE ps 2>/dev/null | grep -i celld | grep -qiE "up|running"; then
    node_died=1; break
  fi
  out=$(poll || true)
  printf '  t+%-4ss %s\n' "$(( $(date +%s) - t0 ))" "$out"
  case "$out" in *'"n"'*) recovered=1; break;; esac
  sleep 15
done

echo
if [ "$node_died" = 1 ]; then
  cat <<EOF
INCONCLUSIVE — celld exited rather than the cell being stuck.

Almost certainly the self-fence: at high store latency the node cannot renew
its own lease inside the TTL, so it halts (exit 3). That is celld working as
designed — a node that cannot reach the store must not keep owning cells — but
it is NOT the restore livelock this script is probing.

Lower the latency and raise the write count instead; the product is what
matters, and only the write count is free of the lease TTL:
    ./run-backlog.sh $((WRITES * 4)) $((LATENCY_MS / 4))

  $COMPOSE logs --tail=20 celld | grep -iE "self-fence|lease"
EOF
elif [ "$recovered" = 1 ]; then
  cat <<EOF
PASS (expected on v0.2.0) — the cell recovered despite a fully uncompacted
backlog and individual requests timing out along the way. Activation therefore
outlived the request that triggered it, which is the property v0.1.0 lacked,
and compaction can now drain the backlog normally.
EOF
else
  cat <<EOF
FAIL / REGRESSION — the node is healthy but the cell never opened, well past
the time its restore should take.

That means activation is again being discarded when its triggering request
times out, so no request lives long enough to finish one. Compaction cannot
help: it runs only on a resident, owned cell, and this cell can never become
resident. Check whether restore progress is being carried across attempts.

  $COMPOSE logs --tail=20 celld | grep -E "restored remote replica|RestoreFailed"
EOF
fi
