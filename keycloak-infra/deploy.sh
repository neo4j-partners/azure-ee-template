#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_INFO="$SCRIPT_DIR/.deployment.json"
REGISTRY_DEPLOYMENT="keycloak-registry"
DEPLOYMENT_NAME="keycloak"

# Deploy generates a fresh resource group; all other commands read from .deployment.json
_load_resource_group() {
    if [ -n "${KEYCLOAK_RESOURCE_GROUP:-}" ]; then
        RESOURCE_GROUP="$KEYCLOAK_RESOURCE_GROUP"
    elif [ -f "$DEPLOYMENT_INFO" ]; then
        RESOURCE_GROUP=$(python3 -c "import json; print(json.load(open('$DEPLOYMENT_INFO'))['resource_group'])" 2>/dev/null || echo "")
        if [ -z "$RESOURCE_GROUP" ]; then
            err "Could not read resource_group from $DEPLOYMENT_INFO"
            exit 1
        fi
    else
        err "No deployment info file found. Run '$0 deploy' first."
        exit 1
    fi
    LOCATION=$(python3 -c "import json; print(json.load(open('$DEPLOYMENT_INFO')).get('location', 'eastus'))" 2>/dev/null || echo "eastus")
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}$*${NC}"; }
ok()    { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
err()   { echo -e "${RED}$*${NC}" >&2; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# ── helpers ──────────────────────────────────────────────────────────────────

get_output() {
    az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --query "properties.outputs.$1.value" \
        -o tsv 2>/dev/null
}

get_registry_output() {
    az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$REGISTRY_DEPLOYMENT" \
        --query "properties.outputs.$1.value" \
        -o tsv 2>/dev/null
}

require_deployment() {
    if ! az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" &>/dev/null; then
        err "No deployment found. Run '$0 deploy' first."
        exit 1
    fi
}

# ── commands ─────────────────────────────────────────────────────────────────

deploy() {
    TIMESTAMP=$(date +%m%d%H%M)
    RESOURCE_GROUP="${KEYCLOAK_RESOURCE_GROUP:-rg-keycloak-${TIMESTAMP}}"
    LOCATION="${KEYCLOAK_LOCATION:-eastus}"

    bold "Deploying Keycloak to Azure Container Apps"
    echo "  Resource group: $RESOURCE_GROUP"
    echo "  Location:       $LOCATION"
    echo ""

    # Prompt for admin password if not set
    if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
        read -rsp "Keycloak admin password: " KEYCLOAK_ADMIN_PASSWORD
        echo ""
        if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
            err "Password cannot be empty."
            exit 1
        fi
    fi

    # Step 1: Create resource group
    info "Creating resource group..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

    # Step 2: Deploy ACR
    info "Step 1/3: Deploying Container Registry..."
    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$REGISTRY_DEPLOYMENT" \
        --template-file "$SCRIPT_DIR/registry.bicep" \
        -o none

    # Step 3: Build and push custom Keycloak image with a generated client secret
    ACR_NAME=$(get_registry_output "acrName")
    ACR_ID=$(get_registry_output "acrId")
    CLIENT_SECRET=$(uuidgen | tr '[:upper:]' '[:lower:]')

    info "Step 2/3: Building and pushing Keycloak image to ACR ($ACR_NAME)..."
    BUILD_DIR=$(mktemp -d)
    trap 'rm -rf "$BUILD_DIR"' EXIT
    cp "$SCRIPT_DIR/Dockerfile" "$BUILD_DIR/"
    sed "s/neo4j-client-secret/$CLIENT_SECRET/g" "$SCRIPT_DIR/realm-export.json" > "$BUILD_DIR/realm-export.json"

    az acr build \
        --registry "$ACR_NAME" \
        --image keycloak:26.5.6 \
        "$BUILD_DIR/" \
        -o none

    rm -rf "$BUILD_DIR"
    trap - EXIT

    # Step 4: Deploy identity, Container Apps environment, and Keycloak (image already exists)
    info "Step 3/3: Deploying Container Apps + Keycloak..."
    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --template-file "$SCRIPT_DIR/main.bicep" \
        --parameters \
            keycloakAdminPassword="$KEYCLOAK_ADMIN_PASSWORD" \
            acrName="$ACR_NAME" \
            acrId="$ACR_ID" \
            deploymentId="$CLIENT_SECRET" \
        -o none

    echo ""
    ok "Deployment complete!"
    echo ""
    _save_deployment_info "$CLIENT_SECRET"
    _print_outputs
    echo ""
    warn "Note: Keycloak may take 30-90 seconds to start. Run '$0 status' to check."
}

status() {
    _load_resource_group
    require_deployment

    bold "Keycloak Deployment Status"
    echo ""

    KEYCLOAK_URL=$(get_output "keycloakUrl")
    DISCOVERY_URI=$(get_output "oidcDiscoveryUri")

    echo "  Resource group: $RESOURCE_GROUP"
    echo "  Keycloak URL:   $KEYCLOAK_URL"
    echo ""

    # Check container app status
    APP_NAME=$(az containerapp list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
    if [ -z "$APP_NAME" ]; then
        err "No Container App found in resource group."
        return 1
    fi

    RUNNING=$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" --query "properties.runningStatus" -o tsv 2>/dev/null || echo "Unknown")
    PROVISIONING=$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    info "Container App: $APP_NAME"
    echo "  Provisioning: $PROVISIONING"
    echo "  Running:      $RUNNING"
    echo ""

    # Check if Keycloak is responding
    info "Checking OIDC discovery endpoint..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DISCOVERY_URI" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        ok "Keycloak is ready (HTTP $HTTP_CODE)"

        # Check realm
        ISSUER=$(curl -s "$DISCOVERY_URI" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")
        if [ -n "$ISSUER" ]; then
            echo "  Issuer: $ISSUER"
        fi
    elif [ "$HTTP_CODE" = "000" ]; then
        warn "Keycloak is not reachable yet (connection failed)"
    else
        warn "Keycloak returned HTTP $HTTP_CODE (may still be starting)"
    fi
}

test_token() {
    _load_resource_group
    require_deployment

    if [ ! -f "$DEPLOYMENT_INFO" ]; then
        err "No deployment info file found. Run '$0 deploy' first."
        exit 1
    fi

    CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$DEPLOYMENT_INFO'))['oidc']['client_secret'])" 2>/dev/null || echo "")
    if [ -z "$CLIENT_SECRET" ]; then
        err "Could not read client secret from $DEPLOYMENT_INFO"
        exit 1
    fi

    bold "Testing Token Acquisition"
    echo ""

    TOKEN_ENDPOINT=$(get_output "oidcTokenEndpoint")
    DISCOVERY_URI=$(get_output "oidcDiscoveryUri")

    # Check if Keycloak is up
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DISCOVERY_URI" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" != "200" ]; then
        err "Keycloak is not reachable (HTTP $HTTP_CODE). Run '$0 status' to check."
        exit 1
    fi

    # Acquire a token
    info "Acquiring token from $TOKEN_ENDPOINT ..."
    RESPONSE=$(curl -s -X POST "$TOKEN_ENDPOINT" \
        -d "grant_type=client_credentials" \
        -d "client_id=neo4j-client" \
        -d "client_secret=$CLIENT_SECRET")

    ACCESS_TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [ -z "$ACCESS_TOKEN" ]; then
        err "Token acquisition failed."
        echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
        exit 1
    fi

    ok "Token acquired successfully"
    echo ""

    # Decode and display claims
    bold "JWT Claims:"
    echo "$ACCESS_TOKEN" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
for key in ['iss', 'aud', 'azp', 'sub', 'roles', 'exp']:
    if key in claims:
        print(f'  {key}: {claims[key]}')
"

    echo ""

    # Check that roles are present
    HAS_ROLES=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
roles = claims.get('roles', [])
print('yes' if 'neo4j-admin' in roles else 'no')
" 2>/dev/null || echo "no")

    if [ "$HAS_ROLES" = "yes" ]; then
        ok "Top-level 'roles' claim contains neo4j roles"
    else
        warn "Warning: expected roles not found in token"
    fi

    # Check audience matches expected value
    EXPECTED_AUDIENCE=$(get_output "oidcAudience")
    TOKEN_AUDIENCE=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
aud = claims.get('aud', '')
if isinstance(aud, list):
    print(','.join(aud))
else:
    print(aud)
" 2>/dev/null || echo "")

    if echo "$TOKEN_AUDIENCE" | grep -q "$EXPECTED_AUDIENCE"; then
        ok "Audience check: token aud contains '$EXPECTED_AUDIENCE'"
    else
        err "AUDIENCE MISMATCH — Neo4j will reject tokens!"
        echo "  Expected: $EXPECTED_AUDIENCE"
        echo "  Token:    $TOKEN_AUDIENCE"
        exit 1
    fi

    # Check issuer matches discovery
    info "Verifying issuer matches discovery document..."
    DISCOVERY_ISSUER=$(curl -s "$DISCOVERY_URI" | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")
    TOKEN_ISSUER=$(echo "$ACCESS_TOKEN" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(claims.get('iss', ''))
" 2>/dev/null || echo "")

    if [ "$DISCOVERY_ISSUER" = "$TOKEN_ISSUER" ]; then
        ok "Issuer match: $TOKEN_ISSUER"
    else
        err "ISSUER MISMATCH — Neo4j will reject tokens!"
        echo "  Discovery: $DISCOVERY_ISSUER"
        echo "  Token:     $TOKEN_ISSUER"
        exit 1
    fi

    echo ""
    ok "All checks passed."
    echo ""
    _print_neo4j_config
}

outputs() {
    _load_resource_group
    require_deployment
    _print_outputs
    echo ""
    _print_neo4j_config
}

cleanup() {
    _load_resource_group
    bold "Deleting Keycloak deployment"
    echo "  Resource group: $RESOURCE_GROUP"
    echo ""

    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        warn "Resource group '$RESOURCE_GROUP' does not exist."
        return 0
    fi

    read -rp "Are you sure? This deletes all resources. [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        info "Cancelled."
        return 0
    fi

    info "Deleting resource group (this takes a few minutes)..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait

    if [ -f "$DEPLOYMENT_INFO" ]; then
        rm "$DEPLOYMENT_INFO"
        info "Removed deployment info file."
    fi

    ok "Deletion started (running in background)."
}

# ── output helpers ───────────────────────────────────────────────────────────

_get_client_secret() {
    if [ -f "$DEPLOYMENT_INFO" ]; then
        python3 -c "import json; print(json.load(open('$DEPLOYMENT_INFO'))['oidc']['client_secret'])" 2>/dev/null || echo "(not found)"
    else
        echo "(no deployment info file — run '$0 deploy')"
    fi
}

_save_deployment_info() {
    local client_secret="$1"
    local keycloak_url admin_console_url acr_name
    local discovery_uri token_endpoint audience client_id role_mapping token_type_config display_name

    keycloak_url=$(get_output keycloakUrl)
    admin_console_url=$(get_output adminConsoleUrl)
    acr_name=$(get_registry_output acrName)
    discovery_uri=$(get_output oidcDiscoveryUri)
    token_endpoint=$(get_output oidcTokenEndpoint)
    audience=$(get_output oidcAudience)
    client_id=$(get_output oidcClientId)
    role_mapping=$(get_output oidcRoleMapping)
    token_type_config=$(get_output oidcTokenTypeConfig)
    display_name=$(get_output oidcDisplayName)

    python3 -c '
import json, sys
_, path, rg, loc, kc_url, admin_url, acr, disc, token_ep, aud, cid, secret, roles, ttc, dname = sys.argv
info = {
    "resource_group": rg,
    "location": loc,
    "keycloak_url": kc_url,
    "admin_console_url": admin_url,
    "acr_name": acr,
    "oidc": {
        "discovery_uri": disc,
        "token_endpoint": token_ep,
        "audience": aud,
        "client_id": cid,
        "client_secret": secret,
        "role_mapping": roles,
        "token_type_config": ttc,
        "display_name": dname,
        "visible": False
    }
}
with open(path, "w") as f:
    json.dump(info, f, indent=2)
' "$DEPLOYMENT_INFO" "$RESOURCE_GROUP" "$LOCATION" \
      "$keycloak_url" "$admin_console_url" "$acr_name" \
      "$discovery_uri" "$token_endpoint" "$audience" "$client_id" \
      "$client_secret" "$role_mapping" "$token_type_config" "$display_name"

    info "Deployment info saved to $DEPLOYMENT_INFO"
}

_print_outputs() {
    local client_secret
    client_secret=$(_get_client_secret)

    bold "Deployment Outputs"
    echo ""
    echo "  Keycloak URL:      $(get_output 'keycloakUrl')"
    echo "  Admin Console:     $(get_output 'adminConsoleUrl')"
    echo "  ACR Name:          $(get_registry_output 'acrName')"
    echo ""
    bold "OIDC Configuration (for Neo4j)"
    echo ""
    echo "  Discovery URI:     $(get_output 'oidcDiscoveryUri')"
    echo "  Token Endpoint:    $(get_output 'oidcTokenEndpoint')"
    echo "  Audience:          $(get_output 'oidcAudience')"
    echo "  Client ID:         $(get_output 'oidcClientId')"
    echo "  Client Secret:     $client_secret"
    echo "  Role Mapping:      $(get_output 'oidcRoleMapping')"
    echo "  Token Type Config: $(get_output 'oidcTokenTypeConfig')"
    echo "  Display Name:      $(get_output 'oidcDisplayName')"
    echo "  Visible:           false"
}

_print_neo4j_config() {
    bold "Neo4j OIDC Config (for neo4j.conf or manual OIDC setup wizard)"
    echo ""
    echo "  discovery_uri:      $(get_output 'oidcDiscoveryUri')"
    echo "  audience:           $(get_output 'oidcAudience')"
    echo "  username_claim:     sub"
    echo "  groups_claim:       roles"
    echo "  role_mapping:       $(get_output 'oidcRoleMapping')"
    echo "  token_type_config:  $(get_output 'oidcTokenTypeConfig')"
    echo "  display_name:       $(get_output 'oidcDisplayName')"
    echo "  visible:            false"
}

# ── main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    deploy)   deploy ;;
    status)   status ;;
    test)     test_token ;;
    outputs)  outputs ;;
    cleanup)  cleanup ;;
    *)
        echo "Usage: $0 {deploy|status|test|outputs|cleanup}"
        echo ""
        echo "Commands:"
        echo "  deploy   Deploy Keycloak to Azure Container Apps"
        echo "  status   Check deployment and Keycloak health"
        echo "  test     Acquire a token and validate claims"
        echo "  outputs  Show deployment outputs and Neo4j OIDC config"
        echo "  cleanup  Delete the resource group and all resources"
        echo ""
        echo "Environment variables:"
        echo "  KEYCLOAK_RESOURCE_GROUP  Resource group name (default: rg-keycloak-demo)"
        echo "  KEYCLOAK_LOCATION        Azure region (default: eastus)"
        echo "  KEYCLOAK_ADMIN_PASSWORD  Admin password (prompted if not set)"
        exit 1
        ;;
esac
