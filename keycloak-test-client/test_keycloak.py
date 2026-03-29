#!/usr/bin/env python3
"""
Keycloak test client - acquires a token via client credentials and displays decoded claims.

Start Keycloak first:

    docker run -d --name keycloak -p 8080:8080 \
      -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
      -v $(pwd)/realm-export.json:/opt/keycloak/data/import/realm-export.json \
      quay.io/keycloak/keycloak:latest start-dev --import-realm

Then run:

    uv run test_keycloak.py
"""

import argparse
import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx

DEFAULTS = {
    "server_url": "http://localhost:8080",
    "realm": "neo4j",
    "client_id": "neo4j-client",
    "client_secret": "neo4j-client-secret",
}


def decode_jwt_payload(token: str) -> dict:
    """Decode JWT payload without signature verification (for inspection only)."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError(f"Invalid JWT: expected 3 parts, got {len(parts)}")
    payload = parts[1]
    padding = 4 - len(payload) % 4
    if padding != 4:
        payload += "=" * padding
    return json.loads(base64.urlsafe_b64decode(payload))


def acquire_token(server_url: str, realm: str, client_id: str, client_secret: str) -> dict:
    """Acquire token from Keycloak using client credentials grant."""
    token_url = f"{server_url}/realms/{realm}/protocol/openid-connect/token"

    response = httpx.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        },
    )
    response.raise_for_status()
    return response.json()


def format_timestamp(ts: int) -> str:
    """Format a Unix timestamp as a human-readable string."""
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def load_azure_deployment() -> dict:
    """Load connection details from keycloak-infra/.deployment.json."""
    deployment_path = Path(__file__).resolve().parent.parent / "keycloak-infra" / ".deployment.json"
    if not deployment_path.exists():
        print(f"ERROR: Deployment file not found: {deployment_path}")
        print("Deploy Keycloak to Azure first (see keycloak-infra/README.md)")
        sys.exit(1)
    data = json.loads(deployment_path.read_text())
    return {
        "server_url": data["keycloak_url"],
        "realm": "neo4j",
        "client_id": data["oidc"]["client_id"],
        "client_secret": data["oidc"]["client_secret"],
    }


def main():
    parser = argparse.ArgumentParser(description="Keycloak test client")
    parser.add_argument("--azure", action="store_true", help="Use Azure deployment from keycloak-infra/.deployment.json")
    parser.add_argument("--server-url", default=None)
    parser.add_argument("--realm", default=None)
    parser.add_argument("--client-id", default=None)
    parser.add_argument("--client-secret", default=None)
    args = parser.parse_args()

    if args.azure:
        defaults = load_azure_deployment()
    else:
        defaults = DEFAULTS

    server_url = args.server_url or defaults["server_url"]
    realm = args.realm or defaults["realm"]
    client_id = args.client_id or defaults["client_id"]
    client_secret = args.client_secret or defaults["client_secret"]

    print(f"Keycloak server: {server_url}")
    print(f"Realm:           {realm}")
    print(f"Client ID:       {client_id}")
    if args.azure:
        print(f"Source:          keycloak-infra/.deployment.json")
    print()

    # Check Keycloak is reachable via OIDC discovery
    discovery_url = f"{server_url}/realms/{realm}/.well-known/openid-configuration"
    print(f"Discovery URL: {discovery_url}")
    try:
        resp = httpx.get(discovery_url)
        resp.raise_for_status()
        discovery = resp.json()
        print("Keycloak discovery endpoint is reachable")
    except httpx.ConnectError:
        print(f"ERROR: Cannot connect to Keycloak at {server_url}")
        if args.azure:
            print("Is the Azure Container App running?")
        else:
            print("Is Keycloak running? Start it with:")
            print()
            print("  docker run -d --name keycloak -p 8080:8080 \\")
            print("    -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \\")
            print("    -v $(pwd)/realm-export.json:/opt/keycloak/data/import/realm-export.json \\")
            print("    quay.io/keycloak/keycloak:latest start-dev --import-realm")
        sys.exit(1)
    except httpx.HTTPStatusError as e:
        print(f"ERROR: Keycloak returned {e.response.status_code}")
        print(f"Does the realm '{realm}' exist?")
        sys.exit(1)
    print()

    # Display discovery endpoint fields that Neo4j consumes
    print("=== Discovery endpoint fields (used by Neo4j) ===")
    print(f"  issuer:         {discovery.get('issuer')}")
    print(f"  token_endpoint: {discovery.get('token_endpoint')}")
    print(f"  jwks_uri:       {discovery.get('jwks_uri')}")
    print()

    # Acquire token via client credentials grant
    print("Acquiring token via client credentials grant...")
    try:
        token_response = acquire_token(
            server_url, realm, client_id, client_secret
        )
    except httpx.HTTPStatusError as e:
        print(f"ERROR: Token acquisition failed with status {e.response.status_code}")
        print(f"Response: {e.response.text}")
        sys.exit(1)

    access_token = token_response["access_token"]
    print(
        f"Token acquired (type: {token_response.get('token_type')}, "
        f"expires_in: {token_response.get('expires_in')}s)"
    )
    print()

    # Decode and display all claims
    claims = decode_jwt_payload(access_token)
    print("=== Full decoded JWT claims ===")
    print(json.dumps(claims, indent=2))
    print()

    # Highlight claims relevant to Neo4j OIDC integration
    print("=== Key claims for Neo4j OIDC integration ===")
    print(f"  Issuer (iss):           {claims.get('iss')}")
    print(f"  Subject (sub):          {claims.get('sub')}")
    print(f"  Authorized party (azp): {claims.get('azp')}")

    # Audience validation — Neo4j's dbms.security.oidc.m2m.audience must match
    aud = claims.get("aud")
    print(f"  Audience (aud):         {aud}")
    expected_aud = client_id
    if isinstance(aud, list):
        aud_ok = expected_aud in aud
    else:
        aud_ok = aud == expected_aud
    if aud_ok:
        print(f"  Audience check:         PASS — contains '{expected_aud}'")
    else:
        print(f"  Audience check:         FAIL — expected '{expected_aud}' in aud claim")
        print(f"                          Neo4j will reject this token. Add an audience")
        print(f"                          protocol mapper to the Keycloak client.")

    # Top-level roles claim (via User Client Role protocol mapper)
    # This is what Neo4j reads via dbms.security.oidc.*.claims.groups=roles
    top_level_roles = claims.get("roles", [])
    print(f"  Roles (top-level):      {top_level_roles}")
    if isinstance(top_level_roles, str):
        print(f"  Roles type:             single string (supported by current Neo4j)")
    elif isinstance(top_level_roles, list):
        print(f"  Roles type:             array ({len(top_level_roles)} entries)")
    else:
        print(f"  Roles type:             WARNING — unexpected type: {type(top_level_roles).__name__}")

    # Also show native nested locations for reference
    realm_roles = claims.get("realm_access", {}).get("roles", [])
    if realm_roles:
        print(f"  realm_access.roles:     {realm_roles}")

    resource_access = claims.get("resource_access", {})
    for client, access in resource_access.items():
        client_roles = access.get("roles", [])
        if client_roles:
            print(f"  resource_access.{client}: {client_roles}")

    if claims.get("exp"):
        print(f"  Expires (exp):          {format_timestamp(claims['exp'])}")
    if claims.get("iat"):
        print(f"  Issued at (iat):        {format_timestamp(claims['iat'])}")
    print()

    # Raw token for manual testing
    print("=== Raw access token ===")
    print(access_token)


if __name__ == "__main__":
    main()
