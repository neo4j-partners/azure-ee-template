#!/usr/bin/env bash
# Install neo4j-enterprise from the Neo4j yum repo with retries.
#
# The Azure RHEL marketplace base image relies on rhui4-1.microsoft.com for
# RHEL BaseOS/AppStream metadata. That endpoint intermittently returns 4xx/5xx
# during dnf metadata refresh. A single failure breaks dependency resolution
# and leaves the VM without Neo4j, with no signal to ARM. The retry loop rides
# out those transient errors; the explicit rpm check + failure marker make the
# unrecoverable case observable to the deploy CLI and the operator.
#
# --refresh is passed on every attempt: if a previous attempt populated dnf's
# cache with partial/broken state, --refresh forces a clean re-fetch instead
# of failing the same way again from cache.

set -euo pipefail

INSTALL_OK=false
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "=== dnf install neo4j-enterprise (attempt $i/10) ==="
  if dnf install -y --refresh neo4j-enterprise; then
    INSTALL_OK=true
    break
  fi
  # Jittered backoff (25-35s) so clustered nodes don't retry in lockstep
  SLEEP=$((RANDOM % 10 + 25))
  echo "dnf install failed; sleeping ${SLEEP}s before retry..."
  sleep "$SLEEP"
done

if [ "$INSTALL_OK" != "true" ] || ! rpm -q neo4j-enterprise >/dev/null 2>&1; then
  echo "FATAL: neo4j-enterprise install failed after 10 attempts" \
    | tee /var/log/neo4j-install-failed
  exit 1
fi
echo "Installed: $(rpm -q neo4j-enterprise)"
