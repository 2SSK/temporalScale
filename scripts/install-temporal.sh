#!/usr/bin/env bash
# scripts/install-temporal.sh - Prepare the host and stage TEMPORAL_VERSION under /opt/temporal (reload-temporal.sh activates it).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ARCH=$(dpkg --print-architecture)

# Create the service user and directories, install node_exporter, cap journald, keep Temporal out of syslog
prepare_host() {
    id -u temporal >/dev/null 2>&1 || {
        useradd --system --user-group --no-create-home --home-dir /var/lib/temporal --shell /usr/sbin/nologin temporal
        log "created system user temporal"
    }
    install -d -m 0755 "$TEMPORAL_HOME/releases" "$TEMPORAL_HOME/cli"
    install -d -m 0750 -g temporal /etc/temporal
    install -d -m 0750 -o temporal -g temporal /var/lib/temporal
    command -v prometheus-node-exporter >/dev/null || {
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends prometheus-node-exporter >/dev/null
        log "installed prometheus-node-exporter on :9100"
    }
    systemctl enable --now --quiet prometheus-node-exporter
    CHANGED=false
    install_file "$ROOT_DIR/config/journald.conf" /etc/systemd/journald.conf.d/temporal-v6.conf 0644
    if $CHANGED; then systemctl restart systemd-journald; fi
    [[ -d /etc/rsyslog.d ]] || return 0
    CHANGED=false
    install_file "$ROOT_DIR/config/rsyslog-temporal.conf" /etc/rsyslog.d/30-temporal.conf 0644
    if $CHANGED; then systemctl restart rsyslog; fi
}

# Download a GitHub release asset into TMP_DIR and verify it against the release checksums.txt
fetch_verified() {
    local base=$1 file=$2
    curl -fsSL --retry 3 -o "$TMP_DIR/checksums.txt" "$base/checksums.txt"
    curl -fsSL --retry 3 -o "$TMP_DIR/$file" "$base/$file"
    (cd "$TMP_DIR" && grep " $file\$" checksums.txt | sha256sum -c --quiet -) || die "checksum mismatch: $file"
    log "verified $file"
}

# Move the root-owned TMP_DIR/release into place
publish() {
    chown -R root:root "$TMP_DIR/release"
    chmod -R u=rwX,go=rX "$TMP_DIR/release"
    mv -T "$TMP_DIR/release" "$1"
    rm -rf "$TMP_DIR"
}

# Stage a server release with its Postgres schema in releases/<version>
install_server() {
    local dest=$TEMPORAL_HOME/releases/$TEMPORAL_VERSION file
    [[ -x $dest/temporal-server ]] && { log "server $TEMPORAL_VERSION already staged"; return; }
    make_tmp_dir "$TEMPORAL_HOME/releases"
    file=temporal_${TEMPORAL_VERSION}_linux_${ARCH}.tar.gz
    fetch_verified "https://github.com/temporalio/temporal/releases/download/v$TEMPORAL_VERSION" "$file"
    mkdir "$TMP_DIR/release"
    tar --no-same-owner -xzf "$TMP_DIR/$file" -C "$TMP_DIR/release" temporal-server temporal-sql-tool tdbg
    curl -fsSL --retry 3 -o "$TMP_DIR/source.tar.gz" \
        "https://github.com/temporalio/temporal/archive/refs/tags/v$TEMPORAL_VERSION.tar.gz"
    tar --no-same-owner -xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR/release" --strip-components=1 \
        "temporal-$TEMPORAL_VERSION/schema/postgresql/v12"
    publish "$dest"
    log "staged server $TEMPORAL_VERSION"
}

# Install the temporal CLI in cli/<version> and link it on PATH
install_cli() {
    local dest=$TEMPORAL_HOME/cli/$TEMPORAL_CLI_VERSION file
    if [[ ! -x $dest/temporal ]]; then
        make_tmp_dir "$TEMPORAL_HOME/cli"
        file=temporal_cli_${TEMPORAL_CLI_VERSION}_linux_${ARCH}.tar.gz
        fetch_verified "https://github.com/temporalio/cli/releases/download/v$TEMPORAL_CLI_VERSION" "$file"
        mkdir "$TMP_DIR/release"
        tar --no-same-owner -xzf "$TMP_DIR/$file" -C "$TMP_DIR/release" temporal
        publish "$dest"
        log "installed cli $TEMPORAL_CLI_VERSION"
    fi
    ln -sfn "$dest/temporal" /usr/local/bin/temporal
}

# On a fresh host point current at the staged release; upgrades are switched by reload-temporal.sh
first_activation() {
    local tool
    [[ -e $TEMPORAL_HOME/current ]] || {
        ln -sfn "releases/$TEMPORAL_VERSION" "$TEMPORAL_HOME/current"
        log "current -> releases/$TEMPORAL_VERSION"
    }
    for tool in temporal-sql-tool tdbg; do ln -sfn "$TEMPORAL_HOME/current/$tool" "/usr/local/bin/$tool"; done
}

# Remove leftovers of interrupted installs and keep every release root-owned and read-only for others
clean_staging() {
    find "$TEMPORAL_HOME/releases" "$TEMPORAL_HOME/cli" -maxdepth 1 -name '.temporal-v6.*' -mmin +60 -exec rm -rf {} +
    chown -R root:root "$TEMPORAL_HOME/releases" "$TEMPORAL_HOME/cli"
    chmod -R u=rwX,go=rX "$TEMPORAL_HOME/releases" "$TEMPORAL_HOME/cli"
}

main() {
    init TEMPORAL_VERSION TEMPORAL_CLI_VERSION
    prepare_host
    clean_staging
    install_server
    install_cli
    first_activation
    log "staged $TEMPORAL_VERSION; current is $(readlink "$TEMPORAL_HOME/current")"
}

main "$@"
