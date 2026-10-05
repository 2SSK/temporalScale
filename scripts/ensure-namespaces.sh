#!/usr/bin/env bash
# scripts/ensure-namespaces.sh - Create every namespace in NAMESPACES and keep its retention at NAMESPACE_RETENTION.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ADDRESS=127.0.0.1:7233

main() {
    init NAMESPACES NAMESPACE_RETENTION
    local namespace
    for namespace in $NAMESPACES; do
        if temporal operator namespace describe -n "$namespace" --address "$ADDRESS" >/dev/null 2>&1; then
            temporal operator namespace update -n "$namespace" --retention "$NAMESPACE_RETENTION" --address "$ADDRESS" >/dev/null
            log "$namespace: exists, retention $NAMESPACE_RETENTION"
        else
            temporal operator namespace create -n "$namespace" --retention "$NAMESPACE_RETENTION" --address "$ADDRESS" >/dev/null
            log "$namespace: created, retention $NAMESPACE_RETENTION"
        fi
    done
}

main "$@"
