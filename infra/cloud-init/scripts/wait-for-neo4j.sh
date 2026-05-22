#!/usr/bin/env bash
# Wait for Neo4j to accept connections on either HTTP (7474) or Bolt (7687),
# with a hard timeout. On failure, dump systemd status and the tail of
# neo4j.log so the deploy CLI / operator can investigate.
#
# Usage: wait-for-neo4j.sh <max-attempts>
#   Each attempt waits 5s, so attempts * 5 = total seconds.
#   standalone: 60  attempts = 5 min
#   cluster:    180 attempts = 15 min (allow time for quorum formation)

set -euo pipefail

ATTEMPTS=${1:-60}
for i in $(seq 1 "$ATTEMPTS"); do
  if curl -s -o /dev/null -w '%{http_code}' http://localhost:7474 2>/dev/null | grep -q "200" \
     || bash -c 'echo > /dev/tcp/localhost/7687' 2>/dev/null; then
    echo "Neo4j is ready!"
    exit 0
  fi
  echo "Waiting for Neo4j to be ready... ($i/$ATTEMPTS)"
  sleep 5
done

echo "FATAL: Neo4j did not become ready within $((ATTEMPTS * 5))s" \
  | tee /var/log/neo4j-not-ready
systemctl --no-pager status neo4j || true
tail -100 /var/log/neo4j/neo4j.log 2>/dev/null || true
exit 1
