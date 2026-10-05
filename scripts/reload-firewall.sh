#!/usr/bin/env bash
# scripts/reload-firewall.sh - Build the TEMPORAL_INPUT iptables/ip6tables chains from the *_IPS lists in .env and apply it, also at boot.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

RULES=/etc/temporal/firewall.rules
RULES6=/etc/temporal/firewall6.rules

# Print one ACCEPT rule per address in a space-separated list for the given ports
allow() {
    local ports=$1 ip
    for ip in $2; do
        echo "-A TEMPORAL_INPUT -s $ip -p tcp -m multiport --dports $ports -j ACCEPT"
    done
}

# Print the TEMPORAL_INPUT chain in iptables-restore format
build_rules() {
    echo "*filter"
    echo ":TEMPORAL_INPUT - [0:0]"
    echo "-F TEMPORAL_INPUT"
    echo "-A TEMPORAL_INPUT -i lo -j ACCEPT"
    echo "-A TEMPORAL_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    echo "-A TEMPORAL_INPUT -p icmp -j ACCEPT"
    echo "-A TEMPORAL_INPUT -p tcp --dport 22 -j ACCEPT"
    allow 6933:6939,7233:7243 "$CLUSTER_IPS"
    allow 7233 "$CLIENT_IPS"
    allow 9091,9100 "${MONITOR_IPS:-}"
    allow 80 "${ADMIN_IPS:-} ${HEALTHCHECK_IPS:-}"
    echo "-A TEMPORAL_INPUT -j DROP"
    echo "COMMIT"
}

# IPv6 carries nothing for Temporal: allow only loopback, replies, ICMPv6 and ssh
build_rules6() {
    echo "*filter"
    echo ":TEMPORAL_INPUT - [0:0]"
    echo "-F TEMPORAL_INPUT"
    echo "-A TEMPORAL_INPUT -i lo -j ACCEPT"
    echo "-A TEMPORAL_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    echo "-A TEMPORAL_INPUT -p ipv6-icmp -j ACCEPT"
    echo "-A TEMPORAL_INPUT -p tcp --dport 22 -j ACCEPT"
    echo "-A TEMPORAL_INPUT -j DROP"
    echo "COMMIT"
}

main() {
    init CLUSTER_IPS CLIENT_IPS
    make_tmp_dir
    build_rules >"$TMP_DIR/rules"
    build_rules6 >"$TMP_DIR/rules6"
    iptables-restore --test --noflush "$TMP_DIR/rules" || die "IPv4 rules rejected by iptables-restore --test"
    ip6tables-restore --test --noflush "$TMP_DIR/rules6" || die "IPv6 rules rejected by ip6tables-restore --test"
    install_file "$TMP_DIR/rules" "$RULES" 0644
    install_file "$TMP_DIR/rules6" "$RULES6" 0644
    CHANGED=false
    install_file "$ROOT_DIR/config/temporal-firewall.service" /etc/systemd/system/temporal-firewall.service 0644
    if $CHANGED; then systemctl daemon-reload; fi
    systemctl enable --quiet temporal-firewall
    systemctl restart temporal-firewall
    log "firewall applied: $(grep -c ACCEPT "$RULES") accept rules (clients $(wc -w <<<"$CLIENT_IPS"), peers $(wc -w <<<"$CLUSTER_IPS"), monitors $(wc -w <<<"${MONITOR_IPS:-}"), admins $(wc -w <<<"${ADMIN_IPS:-}"))"
}

main "$@"
