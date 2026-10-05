#!/usr/bin/env bash
# scripts/deploy.sh - Bring a server into the cluster: install, firewall, nginx, config, start, namespaces. Safe to re-run.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

main() {
    init HOST_IP
    [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] ||
        log "WARNING: clock not NTP-synchronized; Temporal timers and membership depend on it"
    "$ROOT_DIR/scripts/install-temporal.sh"
    "$ROOT_DIR/scripts/reload-firewall.sh"
    "$ROOT_DIR/scripts/setup-nginx.sh"
    "$ROOT_DIR/scripts/reload-temporal.sh"
    "$ROOT_DIR/scripts/ensure-namespaces.sh"
    log "$(hostname) deployed as $HOST_IP"
}

main "$@"
