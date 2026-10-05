#!/usr/bin/env bash
# scripts/status.sh - Report this server's health: service, version, cluster, shards, firewall, memory, clock.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

FAILED=0

# Print one status line; count failures
check() {
    local label=$1 detail=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf 'ok    %-12s %s\n' "$label" "$detail"
    else
        printf 'FAIL  %-12s %s\n' "$label" "$detail"
        FAILED=$((FAILED + 1))
    fi
}

main() {
    init TEMPORAL_VERSION CLUSTER_IPS NUM_HISTORY_SHARDS
    local pid running members shards memory high synced
    pid=$(systemctl show -p MainPID --value temporal)
    running=$(readlink "/proc/$pid/exe" 2>/dev/null || echo none)
    members=$(tdbg --address 127.0.0.1:7233 membership list-gossip 2>/dev/null | grep -c '"identity": ".*:7234"' || true)
    shards=$(curl -s 127.0.0.1:9091/metrics | awk '/^numshards_gauge/ {sum += $2} END {print sum + 0}')
    memory=$(systemctl show -p MemoryCurrent --value temporal)
    high=$(systemctl show -p MemoryHigh --value temporal)
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)

    check service "temporal active, pid $pid" systemctl is-active --quiet temporal
    check version "running $running" test "$running" = "$TEMPORAL_HOME/releases/$TEMPORAL_VERSION/temporal-server"
    check frontend "SERVING on 127.0.0.1:7233" temporal operator cluster health --address 127.0.0.1:7233
    check cluster "history ring $members of $(wc -w <<<"$CLUSTER_IPS") hosts" test "$members" -eq "$(wc -w <<<"$CLUSTER_IPS")"
    check shards "this host owns $shards of $NUM_HISTORY_SHARDS" test "$shards" -gt 0
    check firewall "INPUT jumps to TEMPORAL_INPUT" iptables -C INPUT -j TEMPORAL_INPUT
    check memory "$((memory / 1048576))MiB of MemoryHigh $((high / 1048576))MiB" test "$memory" -lt $((high * 9 / 10))
    check clock "NTP synchronized: $synced" test "$synced" = yes
    exit "$FAILED"
}

main "$@"
