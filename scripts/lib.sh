#!/usr/bin/env bash
# scripts/lib.sh - Shared helpers: logging, .env loading and validation, temp dirs, change-aware file install.
# shellcheck disable=SC2034 # TEMPORAL_HOME and CHANGED are read by the scripts that source this file
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG_FILE=/var/log/temporalScale.log
TEMPORAL_HOME=/opt/temporal
CHANGED=false

# Print a timestamped line to stderr and the log file
log() {
    local line
    line="$(date -u +%FT%TZ) [$(basename "$0" .sh)] $*"
    echo "$line" >&2
    echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

# Log an error and exit
die() {
    log "ERROR: $*"
    exit 1
}

# Exit unless root, load and validate .env, detect HOST_IP, then require the named variables
init() {
    [[ $EUID -eq 0 ]] || die "run as root: sudo $0"
    [[ -f $ROOT_DIR/.env ]] || die "missing $ROOT_DIR/.env (copy .env.example)"
    set -a
    # shellcheck source=/dev/null
    . "$ROOT_DIR/.env"
    set +a
    validate_env
    if [[ -n ${CLUSTER_IPS:-} ]]; then
        HOST_IP=$(detect_host_ip)
        [[ -n $HOST_IP ]] || die "none of CLUSTER_IPS ($CLUSTER_IPS) is on this host"
    fi
    require "$@"
}

# Exit if any of the named variables is empty
require() {
    local name
    for name in "$@"; do
        [[ -n ${!name:-} ]] || die "$name is not set"
    done
}

# Reject values that would break the YAML config, the systemd env file or the database URL
validate_env() {
    [[ -z ${DB_PASSWORD:-} || $DB_PASSWORD =~ ^[A-Za-z0-9._~-]+$ ]] || die "DB_PASSWORD must match [A-Za-z0-9._~-]"
    [[ -z ${DB_TLS:-} || $DB_TLS =~ ^(true|false)$ ]] || die "DB_TLS must be true or false"
    [[ -z ${NUM_HISTORY_SHARDS:-} || $NUM_HISTORY_SHARDS =~ ^[1-9][0-9]*$ ]] || die "NUM_HISTORY_SHARDS must be a number"
}

# Print the CLUSTER_IPS entry assigned to this host
detect_host_ip() {
    local ip
    for ip in $CLUSTER_IPS; do
        [[ " $(hostname -I) " == *" $ip "* ]] && { echo "$ip"; return 0; }
    done
    return 0
}

# Create TMP_DIR under the given parent and remove it when the script exits
make_tmp_dir() {
    TMP_DIR=$(mktemp -d "${1:-/tmp}/.temporalScale.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT
}

# Install src to dest with mode and owner; set CHANGED=true when the content changed
install_file() {
    local src=$1 dest=$2 mode=$3 owner=${4:-root:root}
    if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
        chmod "$mode" "$dest"
        chown "$owner" "$dest"
        return 0
    fi
    install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dest"
    CHANGED=true
    log "updated $dest"
}

