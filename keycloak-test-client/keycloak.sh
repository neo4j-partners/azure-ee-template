#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="keycloak"
IMAGE="quay.io/keycloak/keycloak:latest"

start() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Keycloak is already running"
        return
    fi

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Starting existing Keycloak container..."
        docker start "$CONTAINER_NAME"
    else
        echo "Starting Keycloak..."
        docker run -d --name "$CONTAINER_NAME" -p 8080:8080 \
            -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
            -v "$SCRIPT_DIR/realm-export.json:/opt/keycloak/data/import/realm-export.json" \
            "$IMAGE" start-dev --import-realm
    fi

    echo "Waiting for Keycloak to be ready..."
    for i in $(seq 1 30); do
        if curl -sf http://localhost:8080/realms/master > /dev/null 2>&1; then
            echo "Keycloak is ready (http://localhost:8080)"
            return
        fi
        sleep 2
    done
    echo "ERROR: Keycloak did not start within 60 seconds"
    exit 1
}

stop() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Stopping Keycloak..."
        docker stop "$CONTAINER_NAME" && docker rm "$CONTAINER_NAME"
        echo "Keycloak stopped and removed"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Removing stopped Keycloak container..."
        docker rm "$CONTAINER_NAME"
        echo "Keycloak removed"
    else
        echo "Keycloak is not running"
    fi
}

status() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Keycloak is running"
        docker ps --filter "name=${CONTAINER_NAME}" --format "  Container: {{.Names}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
    else
        echo "Keycloak is not running"
    fi
}

case "${1:-}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
