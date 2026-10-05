#!/bin/sh
# lab/lab.sh - Start, stop, check and ssh into the tscale lab.
set -eu

LAB_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
KEY=$LAB_DIR/keys/lab_key
KNOWN_HOSTS=$LAB_DIR/keys/known_hosts

# Run docker compose against the lab
lab_compose() { docker compose -f "$LAB_DIR/compose.yaml" "$@"; }

# Run docker compose against the project's Web UI, inside tscale-01's network, with the lab's env
ui_compose() {
    UI_NETWORK_MODE=container:tscale-01 \
        docker compose -f "$LAB_DIR/../compose.yaml" --env-file "$LAB_DIR/temporal.env" "$@"
}

# The UI joins tscale-01's network namespace, which is replaced whenever tscale-01 starts,
# so a UI that exists is recreated after tscale-01 comes up and removed with tscale-01
ui_exists() { [ -n "$(ui_compose ps -aq)" ]; }
ui_follow() { if ui_exists; then ui_compose up -d --force-recreate; fi; }
ui_remove() { if ui_exists; then ui_compose down; fi; }

# Create the deploy login keypair once
ensure_key() {
    [ -f "$KEY" ] && return 0
    mkdir -p "$LAB_DIR/keys"
    ssh-keygen -q -t ed25519 -N '' -C tscale -f "$KEY"
}

# Map a host name to its lab IP
host_ip() {
    case $1 in
        01 | tscale-01) echo 10.78.0.11 ;;
        02 | tscale-02) echo 10.78.0.12 ;;
        *) echo "unknown host '$1' (use 01 or 02)" >&2; exit 1 ;;
    esac
}

# Run ssh as deploy against a lab IP
lab_ssh() {
    ip=$1
    shift
    ssh -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=3 \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        "deploy@$ip" "$@"
}

# Copy the project (as rsync would on a server) plus temporal.env as .env
push_files() {
    ip=$1
    lab_ssh "$ip" 'rm -rf temporalScale && mkdir temporalScale'
    tar -C "$LAB_DIR/.." -cf - scripts config compose.yaml .env.example | lab_ssh "$ip" 'tar -C temporalScale -xf -'
    lab_ssh "$ip" 'umask 077 && cat > temporalScale/.env' <"$LAB_DIR/temporal.env"
    # the tar list above is an allowlist, so lab/ cannot ship; assert it anyway
    lab_ssh "$ip" 'test ! -e temporalScale/lab || { echo "lab/ leaked into temporalScale" >&2; exit 1; }'
    echo "pushed temporalScale to deploy@$ip"
}

# Runs on each host: identity, systemd state, reachability of every peer
# shellcheck disable=SC2016 # expanded on the remote host
PROBE='echo "$(hostname) $(systemctl is-system-running)"
for t in 10.78.0.11:22 10.78.0.12:22 10.78.0.20:5432; do
    nc -z -w 2 "${t%:*}" "${t#*:}" || echo "cannot reach $t"
done'

# Check both hosts over ssh, then Postgres
check_lab() {
    rc=0
    n=0
    until lab_compose exec -T tscale-pg pg_isready -q -h 127.0.0.1 -U temporal; do
        n=$((n + 1))
        [ "$n" -ge 30 ] && break
        sleep 1
    done
    for host in tscale-01 tscale-02; do
        ip=$(host_ip "$host")
        n=0
        until out=$(lab_ssh "$ip" "$PROBE" 2>/dev/null); do
            n=$((n + 1))
            [ "$n" -ge 20 ] && { echo "FAIL  $host: ssh to $ip"; rc=1; continue 2; }
            sleep 1
        done
        echo "ok    $host ($ip): $out"
        case $out in *cannot* | *degraded* | *starting*) rc=1 ;; esac
    done
    if lab_compose exec -T tscale-pg pg_isready -q -h 127.0.0.1 -U temporal; then
        echo "ok    tscale-pg (10.78.0.20): accepting connections"
    else
        echo "FAIL  tscale-pg (10.78.0.20)"
        rc=1
    fi
    return "$rc"
}

# Print usage
usage() {
    cat <<'USAGE'
./lab.sh up              build and start the lab, then check it
./lab.sh check           ssh, systemd, reachability and Postgres
./lab.sh ssh 01|02 [cmd] ssh to a host as deploy
./lab.sh push 01|02      copy the project and temporal.env to ~/temporalScale
./lab.sh psql            psql as temporal inside tscale-pg
./lab.sh stop | start    power off / on (everything is kept)
./lab.sh down            remove containers, keep volumes (a fresh root disk)
./lab.sh reset           remove containers and volumes (new host keys, empty Postgres)
./lab.sh ui-up | ui-down the Web UI on tscale-01:8080, inside its network (like host network on a server)
USAGE
}

cmd=${1:-help}
[ "$#" -gt 0 ] && shift

case "$cmd" in
    up) ensure_key; rm -f "$KNOWN_HOSTS"; lab_compose up -d --build; ui_follow; check_lab ;;
    check) check_lab ;;
    ssh) ip=$(host_ip "${1:?host: 01 or 02}"); shift; ensure_key; lab_ssh "$ip" "$@" ;;
    push) ip=$(host_ip "${1:?host: 01 or 02}"); ensure_key; push_files "$ip" ;;
    psql) lab_compose exec tscale-pg psql -U temporal -d postgres ;;
    stop) ui_compose stop; lab_compose stop ;;
    start) lab_compose start; ui_follow ;;
    down) ui_remove; lab_compose down ;;
    reset) ui_remove; lab_compose down -v; rm -f "$KNOWN_HOSTS" ;;
    ui-up) ui_compose up -d ;;
    ui-down) ui_compose down ;;
    *) usage ;;
esac
