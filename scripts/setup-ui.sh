#!/usr/bin/env bash
# scripts/setup-ui.sh - Run the Web UI container on this server (node 01); nginx from setup-nginx.sh fronts it.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

main() {
    init TEMPORAL_UI_VERSION
    command -v docker >/dev/null || die "docker is not installed"
    docker compose -f "$ROOT_DIR/compose.yaml" --env-file "$ROOT_DIR/.env" up -d
    log "ui $TEMPORAL_UI_VERSION on 127.0.0.1:${UI_PORT:-8080}, reachable on :80 from ADMIN_IPS"
}

main "$@"
