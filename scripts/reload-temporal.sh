#!/usr/bin/env bash
# scripts/reload-temporal.sh - Validate and apply TEMPORAL_VERSION, config/, the server profile and .env; restart only on change.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SERVER_VARS=(NUM_HISTORY_SHARDS LOG_LEVEL HOST_IP DB_HOST DB_PORT DB_USER DB_PASSWORD DB_TLS
    GOMAXPROCS GOMEMLIMIT DB_MAX_CONNS DB_VISIBILITY_MAX_CONNS)

# Load the host limits from config/profiles/<SERVER_PROFILE>.yaml
load_profile() {
    PROFILE_FILE=$ROOT_DIR/config/profiles/$SERVER_PROFILE.yaml
    [[ -f $PROFILE_FILE ]] || die "unknown SERVER_PROFILE $SERVER_PROFILE (see config/profiles)"
    PROFILE_CORES=$(profile_value cores)
    PROFILE_MEMORY_GB=$(profile_value memoryGB)
    MAX_SHARDS_PER_HOST=$(profile_value maxShardsPerHost)
    MEMORY_HIGH=$(profile_value memoryHigh)
    MEMORY_MAX=$(profile_value memoryMax)
    GOMAXPROCS=$(profile_value goMaxProcs)
    GOMEMLIMIT=$(profile_value goMemLimit)
    DB_MAX_CONNS=$(profile_value dbMaxConns)
    DB_VISIBILITY_MAX_CONNS=$(profile_value dbVisibilityMaxConns)
    export GOMAXPROCS GOMEMLIMIT DB_MAX_CONNS DB_VISIBILITY_MAX_CONNS
}

# Print one top-level value from the profile
profile_value() {
    awk -F': *' -v key="$1" '$1 == key {print $2; exit}' "$PROFILE_FILE"
}

# Print the profile's dynamicConfig block (indented two spaces, ends at the next top-level key)
profile_dynamic_config() {
    awk '/^[^ #]/ {found = ($0 ~ /^dynamicConfig:/); next} found {print substr($0, 3)}' "$PROFILE_FILE"
}

# Refuse a profile bigger than the host; warn when the host could take a bigger one
check_host() {
    local cores mem_mib
    cores=$(nproc)
    mem_mib=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
    if ((cores < PROFILE_CORES || mem_mib < PROFILE_MEMORY_GB * 1024 * 85 / 100)); then
        die "host has ${cores} cores / ${mem_mib}MiB; profile $SERVER_PROFILE needs ${PROFILE_CORES} / ${PROFILE_MEMORY_GB}GB"
    fi
    if ((cores > PROFILE_CORES || mem_mib > PROFILE_MEMORY_GB * 1024 * 125 / 100)); then
        log "WARNING: host has ${cores} cores / ${mem_mib}MiB, larger than profile $SERVER_PROFILE"
    fi
}

# Warn when a host would own more shards than its profile allows after one host fails
check_shards() {
    local hosts survivors per_host
    hosts=$(wc -w <<<"$CLUSTER_IPS")
    survivors=$((hosts > 1 ? hosts - 1 : 1))
    per_host=$(((NUM_HISTORY_SHARDS + survivors - 1) / survivors))
    log "$NUM_HISTORY_SHARDS shards on $hosts hosts: ~$((NUM_HISTORY_SHARDS / hosts)) each, $per_host with one host down (limit $MAX_SHARDS_PER_HOST)"
    ((per_host <= MAX_SHARDS_PER_HOST)) || log "WARNING: one host failing would overload the rest; add hosts or use a bigger profile"
}

# Render everything into TMP_DIR and validate it with the target binary before touching /etc
render_and_validate() {
    local name output server_env
    for name in "${SERVER_VARS[@]}"; do printf '%s=%s\n' "$name" "${!name}"; done >"$TMP_DIR/temporal.env"
    printf '[Service]\nMemoryHigh=%s\nMemoryMax=%s\n' "$MEMORY_HIGH" "$MEMORY_MAX" >"$TMP_DIR/profile.conf"
    { cat "$ROOT_DIR/config/dynamicconfig.yaml"; profile_dynamic_config; } >"$TMP_DIR/dynamicconfig.yaml"
    mkdir "$TMP_DIR/render"
    cp "$ROOT_DIR/config/temporal.yaml" "$TMP_DIR/render/production.yaml"

    output=$(grep -oE '^[^ #][^:]*' "$TMP_DIR/dynamicconfig.yaml" | sort | uniq -d)
    [[ -z $output ]] || die "dynamic config key set twice (shared file and profile?): $output"
    output=$("$RELEASE/temporal-server" validate-dynamic-config "$TMP_DIR/dynamicconfig.yaml" 2>&1)
    ! grep -q "warning:" <<<"$output" || die "dynamic config rejected: $output"
    mapfile -t server_env <"$TMP_DIR/temporal.env"
    output=$(env -i PATH="$PATH" "${server_env[@]}" \
        "$RELEASE/temporal-server" -r / -c "$TMP_DIR/render" -e production render-config 2>&1)
    ! grep -q "Unable to load configuration" <<<"$output" || die "temporal.yaml rejected: $output"
    log "config validated with $TEMPORAL_VERSION"
}

# Install rendered files; return whether a restart is needed via RESTART
apply() {
    CHANGED=false
    install_file "$TMP_DIR/temporal.env" /etc/temporal/temporal.env 0600
    install_file "$ROOT_DIR/config/temporal.yaml" /etc/temporal/temporal.yaml 0640 root:temporal
    install_file "$PROFILE_FILE" /etc/temporal/profile.yaml 0640 root:temporal
    RESTART=$CHANGED

    CHANGED=false
    install_file "$ROOT_DIR/config/temporal.service" /etc/systemd/system/temporal.service 0644
    install_file "$TMP_DIR/profile.conf" /etc/systemd/system/temporal.service.d/profile.conf 0644
    if $CHANGED; then
        systemctl daemon-reload
        RESTART=true
    fi

    CHANGED=false
    install_file "$TMP_DIR/dynamicconfig.yaml" /etc/temporal/dynamicconfig.yaml 0640 root:temporal
    if $CHANGED; then log "dynamic config is hot-reloaded within 10s"; fi

    if [[ $(readlink "$TEMPORAL_HOME/current") != "releases/$TEMPORAL_VERSION" ]]; then
        ln -sfn "releases/$TEMPORAL_VERSION" "$TEMPORAL_HOME/current.new"
        mv -T "$TEMPORAL_HOME/current.new" "$TEMPORAL_HOME/current"
        log "current -> releases/$TEMPORAL_VERSION"
        RESTART=true
    fi
}

# Print this host's history shard count from its metrics
local_shards() {
    curl -s "127.0.0.1:9091/metrics" | awk '/^numshards_gauge/ {sum += $2} END {print sum + 0}'
}

# Wait for SERVING, check the shard count against .env, then wait for shard movement to settle
verify() {
    local attempt shards previous=-1 stable=0 members
    for attempt in $(seq 1 30); do
        temporal operator cluster health --address 127.0.0.1:7233 >/dev/null 2>&1 && break
        ((attempt < 30)) || die "frontend not healthy after 60s: journalctl -u temporal -n 50"
        sleep 2
    done
    shards=$(temporal operator cluster describe --address 127.0.0.1:7233 -o json 2>/dev/null |
        grep -oE '"historyShardCount": *[0-9]+' | grep -oE '[0-9]+$') || die "cluster describe failed"
    [[ $shards == "$NUM_HISTORY_SHARDS" ]] ||
        die "cluster was created with $shards shards (fixed forever); .env says $NUM_HISTORY_SHARDS"
    for attempt in $(seq 1 24); do
        shards=$(local_shards)
        if [[ $shards == "$previous" ]]; then stable=$((stable + 1)); else stable=0; fi
        ((stable >= 2)) && break
        previous=$shards
        sleep 5
    done
    members=$(tdbg --address 127.0.0.1:7233 membership list-gossip 2>/dev/null | grep -c '"identity": ".*:7234"' || true)
    log "SERVING; this host owns $shards shards; history ring has $members of $(wc -w <<<"$CLUSTER_IPS") hosts"
}

main() {
    init TEMPORAL_VERSION SERVER_PROFILE CLUSTER_IPS
    load_profile
    require "${SERVER_VARS[@]}" PROFILE_CORES PROFILE_MEMORY_GB MAX_SHARDS_PER_HOST MEMORY_HIGH MEMORY_MAX
    RELEASE=$TEMPORAL_HOME/releases/$TEMPORAL_VERSION
    [[ -x $RELEASE/temporal-server ]] || die "$TEMPORAL_VERSION not staged: run install-temporal.sh first"
    check_host
    check_shards
    make_tmp_dir
    render_and_validate
    apply
    systemctl enable --quiet temporal
    if $RESTART || ! systemctl is-active --quiet temporal; then
        systemctl restart temporal
        log "temporal $TEMPORAL_VERSION restarted (profile $SERVER_PROFILE)"
    else
        log "no restart needed"
    fi
    verify
}

main "$@"
