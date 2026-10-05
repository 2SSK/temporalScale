#!/usr/bin/env bash
# scripts/setup-databases.sh - Use or create temporal and temporal_visibility, then migrate them to TEMPORAL_VERSION's schema.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Install psql for the existence checks
install_client() {
    command -v psql >/dev/null && return
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends postgresql-client >/dev/null
    log "installed $(psql --version)"
}

# Run one query as DB_USER against a database and print the bare result
query() {
    local sslmode=prefer
    [[ $DB_TLS == true ]] && sslmode=require
    PGPASSWORD=$DB_PASSWORD PGSSLMODE=$sslmode PGCONNECT_TIMEOUT=5 \
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$1" -Atq -v name="${3:-}" <<<"$2"
}

# Run the staged release's temporal-sql-tool; credentials go through env, not argv
sql_tool() {
    SQL_PLUGIN=postgres12 SQL_HOST=$DB_HOST SQL_PORT=$DB_PORT SQL_USER=$DB_USER \
        SQL_PASSWORD=$DB_PASSWORD SQL_TLS=$DB_TLS SQL_DATABASE=$1 "$RELEASE/temporal-sql-tool" "${@:2}"
}

# Reuse the database if it exists, otherwise create it
ensure_database() {
    local output
    if [[ $(query "$DB_ADMIN_DATABASE" "SELECT 1 FROM pg_database WHERE datname = :'name'" "$1") == 1 ]]; then
        log "$1: exists, using it"
        return
    fi
    output=$(sql_tool "$1" create-database 2>&1) || die "$1: create-database failed: $output"
    log "$1: created"
}

# Create versioning tables on a fresh database, then migrate to the staged release's newest schema
migrate() {
    local database=$1 dir=$RELEASE/schema/postgresql/v12/$2/versioned before output
    if [[ $(query "$database" "SELECT to_regclass('public.schema_version') IS NOT NULL") != t ]]; then
        output=$(sql_tool "$database" setup-schema -v 0.0 2>&1) || die "$database: setup-schema failed: $output"
        log "$database: versioning tables created"
    fi
    before=$(query "$database" "SELECT curr_version FROM schema_version")
    output=$(sql_tool "$database" update-schema -d "$dir" 2>&1) || die "$database: update-schema failed: $output"
    log "$database: schema $before -> $(query "$database" "SELECT curr_version FROM schema_version")"
}

main() {
    init TEMPORAL_VERSION DB_HOST DB_PORT DB_USER DB_PASSWORD DB_TLS
    RELEASE=$TEMPORAL_HOME/releases/$TEMPORAL_VERSION
    DB_ADMIN_DATABASE=${DB_ADMIN_DATABASE:-postgres}
    [[ -x $RELEASE/temporal-sql-tool ]] || die "$TEMPORAL_VERSION not staged: run install-temporal.sh first"
    install_client
    query "$DB_ADMIN_DATABASE" "SELECT 1" >/dev/null || die "cannot connect to $DB_HOST:$DB_PORT/$DB_ADMIN_DATABASE as $DB_USER"
    ensure_database temporal
    ensure_database temporal_visibility
    migrate temporal temporal
    migrate temporal_visibility visibility
}

main "$@"
