#!/bin/bash
# Reads Neo4j deployment info, generates .env, and runs the JDBC bearer auth test.
#
# Usage:
#   ./run.sh                              # auto-detect latest deployment
#   ./run.sh standalone-v2025             # specify scenario name
#   ./run.sh /path/to/deployment.json     # specify deployment file directly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOYMENTS_DIR="$SCRIPT_DIR/../.deployments"

# ---------------------------------------------------------------------------
# Find the deployment JSON
# ---------------------------------------------------------------------------
resolve_deployment_file() {
    local arg="${1:-}"

    # Explicit path to a JSON file
    if [ -n "$arg" ] && [ -f "$arg" ]; then
        echo "$arg"
        return
    fi

    # Scenario name (e.g. "standalone-v2025")
    if [ -n "$arg" ] && [ -f "$DEPLOYMENTS_DIR/$arg.json" ]; then
        echo "$DEPLOYMENTS_DIR/$arg.json"
        return
    fi

    # Auto-detect: most recently modified file in .deployments/
    if [ -d "$DEPLOYMENTS_DIR" ]; then
        local latest
        latest=$(ls -t "$DEPLOYMENTS_DIR"/*.json 2>/dev/null | head -1)
        if [ -n "$latest" ]; then
            echo "$latest"
            return
        fi
    fi

    echo ""
}

DEPLOYMENT_FILE=$(resolve_deployment_file "${1:-}")

if [ -z "$DEPLOYMENT_FILE" ]; then
    echo "ERROR: No deployment file found."
    echo ""
    echo "Run 'uv run neo4j-deploy deploy' first, or pass a scenario name:"
    echo "  ./run.sh standalone-v2025"
    exit 1
fi

echo "Reading deployment info from: $DEPLOYMENT_FILE"

# ---------------------------------------------------------------------------
# Extract values with python3 (available everywhere)
# ---------------------------------------------------------------------------
read_json() {
    python3 -c "
import json, sys
data = json.load(open('$DEPLOYMENT_FILE'))
keys = '$1'.split('.')
val = data
for k in keys:
    val = val[k]
print(val)
" 2>/dev/null
}

NEO4J_URI=$(read_json "connection.neo4j_uri")
M2M_ENABLED=$(read_json "m2m_auth.enabled")

if [ "$M2M_ENABLED" != "True" ]; then
    echo "ERROR: M2M auth is not enabled in this deployment."
    echo "Redeploy with M2M/Keycloak enabled."
    exit 1
fi

TOKEN_ENDPOINT=$(read_json "m2m_auth.token_endpoint")
CLIENT_ID=$(read_json "m2m_auth.client_id")
CLIENT_SECRET=$(read_json "m2m_auth.client_secret")

# Derive Keycloak base URL from token endpoint
# e.g. https://host/realms/neo4j/protocol/openid-connect/token -> https://host
KEYCLOAK_URL=$(python3 -c "
from urllib.parse import urlparse
url = urlparse('$TOKEN_ENDPOINT')
print(f'{url.scheme}://{url.netloc}')
")

# ---------------------------------------------------------------------------
# Write .env
# ---------------------------------------------------------------------------
cat > "$SCRIPT_DIR/.env" <<EOF
# Auto-generated from: $DEPLOYMENT_FILE
# Re-run ./run.sh to regenerate.
NEO4J_URI=$NEO4J_URI
KEYCLOAK_URL=$KEYCLOAK_URL
TOKEN_ENDPOINT=$TOKEN_ENDPOINT
CLIENT_ID=$CLIENT_ID
CLIENT_SECRET=$CLIENT_SECRET
REALM=neo4j
EOF

echo "Generated .env:"
echo "  NEO4J_URI=$NEO4J_URI"
echo "  KEYCLOAK_URL=$KEYCLOAK_URL"
echo "  CLIENT_ID=$CLIENT_ID"
echo ""

# ---------------------------------------------------------------------------
# Build and run
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"
./gradlew -q run
