#!/usr/bin/env bash
# Reproduce the celld restore cliff, end to end, on a laptop.
#
#   ./run.sh              2000 writes, 60ms injected latency  (~2 minutes)
#   ./run.sh 5000 40      more writes, less latency
#   ./run.sh 800  150     fewer writes, more latency
#
# Both knobs push on the same product: chain_length x per-object latency. The
# latency is injected only AFTER the chain is built, so the write phase runs at
# full local speed.
set -euo pipefail

WRITES=${1:-2000}
LATENCY_MS=${2:-60}

if command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
elif docker compose version >/dev/null 2>&1;  then COMPOSE="docker compose"
elif command -v podman-compose >/dev/null 2>&1; then COMPOSE="podman-compose"
else echo "need docker compose or podman-compose" >&2; exit 1; fi
COMPOSE=${COMPOSE_OVERRIDE:-$COMPOSE}

API=http://localhost:8474
APP=http://localhost:18080

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
poll() { curl -s -m 12 -w ' [%{http_code}]' "$APP/" 2>/dev/null | tail -c 110; }

cleanup_hint() { printf '\nteardown:  %s down -v\n' "$COMPOSE"; }
trap cleanup_hint EXIT

say "1/6  starting MinIO and Toxiproxy"
$COMPOSE up -d minio toxiproxy
for _ in $(seq 30); do curl -fsS "$API/proxies" >/dev/null 2>&1 && break; sleep 1; done

say "2/6  creating the bucket, fetching celld v0.1.0 and esbuild"
$COMPOSE run --rm createbucket >/dev/null
$COMPOSE run --rm tools

say "3/6  deploying the stock examples/counter worker"
$COMPOSE run --rm deploy 2>&1 | grep -E "Version ID|Uploaded|Binding|error" || true

say "4/6  starting celld, then $WRITES writes at full speed (no latency yet)"
$COMPOSE up -d celld
up=0
for _ in $(seq 60); do
  if curl -fsS -m 2 "$APP/" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "$up" = 1 ] || { echo "celld did not come up:"; $COMPOSE logs --tail=20 celld; exit 1; }
start=$(date +%s)
for _ in $(seq "$WRITES"); do curl -fsS -m 5 "$APP/" >/dev/null 2>&1 || true; done
echo "   done in $(( $(date +%s) - start ))s — counter is now $(curl -fsS -m 5 "$APP/")"

say "5/6  injecting ${LATENCY_MS}ms latency on every object fetch"
curl -fsS -X POST "$API/proxies/store/toxics" -H 'Content-Type: application/json' \
  -d "{\"name\":\"slow\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$LATENCY_MS,\"jitter\":0}}" \
  >/dev/null
echo "   applied"

say "6/6  killing celld — the cell must now be rebuilt from the bucket"
$COMPOSE kill celld >/dev/null 2>&1 || true
$COMPOSE up -d celld
sleep 5

say "RESULT"
recovered=0
for i in $(seq 12); do
  out=$(poll || true)
  printf '  t+%-4ss %s\n' "$((i*10))" "$out"
  case "$out" in *'"n"'*) recovered=1; break;; esac
  sleep 10
done

echo
if [ "$recovered" = 1 ]; then
  cat <<EOF
NOT REPRODUCED — this chain still fits inside the activation deadline.
Push harder and run again (either knob works):
    ./run.sh $((WRITES * 3)) $LATENCY_MS
    ./run.sh $WRITES $((LATENCY_MS * 3))
EOF
else
  echo "REPRODUCED — the cell is permanently unactivatable."
  echo
  echo "celld is healthy and looping: it finishes a restore, the request that"
  echo "triggered it has already timed out, the work is discarded, repeat."
  $COMPOSE logs --tail=200 celld 2>&1 | grep -c "restored remote replica" \
    | sed 's/^/  completed-and-discarded restores so far: /'
  $COMPOSE logs --tail=200 celld 2>&1 | grep "restored remote replica" | tail -2 | sed 's/^/  /'
fi
