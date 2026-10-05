#!/usr/bin/env bash
# scripts/setup-nginx.sh - nginx on :80 with /health for the load balancer and the Web UI for ADMIN_IPS.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Install nginx and remove the distro default site, which would shadow server_name _
install_nginx() {
    command -v nginx >/dev/null || {
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null
        log "installed $(nginx -v 2>&1)"
    }
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        rm /etc/nginx/sites-enabled/default
        log "removed default site"
    fi
}

# Print a space-separated address list as nginx allow lines
allow_lines() {
    local ip
    for ip in $1; do echo "allow $ip;"; done
}

main() {
    init
    install_nginx
    make_tmp_dir
    local output file
    allow_lines "${ADMIN_IPS:-}" >"$TMP_DIR/temporal-admin-allow.conf"
    allow_lines "${HEALTHCHECK_IPS:-} ${ADMIN_IPS:-}" >"$TMP_DIR/temporal-healthcheck-allow.conf"
    cp "$ROOT_DIR/config/nginx.conf" "$TMP_DIR/temporal.conf"
    for file in temporal-admin-allow.conf temporal-healthcheck-allow.conf conf.d/temporal.conf; do
        [[ -f /etc/nginx/$file ]] && cp "/etc/nginx/$file" "$TMP_DIR/$(basename "$file").previous"
    done
    CHANGED=false
    install_file "$TMP_DIR/temporal-admin-allow.conf" /etc/nginx/temporal-admin-allow.conf 0644
    install_file "$TMP_DIR/temporal-healthcheck-allow.conf" /etc/nginx/temporal-healthcheck-allow.conf 0644
    install_file "$TMP_DIR/temporal.conf" /etc/nginx/conf.d/temporal.conf 0644
    if ! output=$(nginx -t 2>&1); then
        for file in temporal-admin-allow.conf temporal-healthcheck-allow.conf conf.d/temporal.conf; do
            if [[ -f $TMP_DIR/$(basename "$file").previous ]]; then
                cp "$TMP_DIR/$(basename "$file").previous" "/etc/nginx/$file"
            else
                rm -f "/etc/nginx/$file"
            fi
        done
        die "nginx -t rejected the new config (previous config restored): $output"
    fi
    systemctl enable --quiet nginx
    if $CHANGED || ! systemctl is-active --quiet nginx; then
        systemctl reload-or-restart nginx
        log "nginx applied: /health for $(wc -w <<<"${HEALTHCHECK_IPS:-}") health checkers, UI for $(wc -w <<<"${ADMIN_IPS:-}") admins"
    else
        log "nginx unchanged"
    fi
}

main "$@"
