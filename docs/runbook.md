# Temporal v6 runbook

All scripts are idempotent, validate before they change anything, log to stderr and
`/var/log/temporal-v6.log`, and run as root from the project directory on the server
(`sudo ~/temporal-v6/scripts/<script>.sh`). Copy the project with
`rsync -a --exclude lab --exclude .git temporal-v6/ <server>:temporal-v6/` and keep `.env` 0600.

| Script | Does |
|---|---|
| `deploy.sh` | Everything below except databases and UI; brings a server into the cluster |
| `install-temporal.sh` | Host prep (user, dirs, node_exporter, journald), stages `TEMPORAL_VERSION` |
| `setup-databases.sh` | Uses or creates both databases, migrates to the staged version's schema |
| `reload-temporal.sh` | Validates and applies version, config, profile; restarts only on change |
| `reload-firewall.sh` | Applies the `*_IPS` lists |
| `setup-nginx.sh` | `/health` and the UI allow list on :80 |
| `setup-ui.sh` | Web UI container (server-01) |
| `ensure-namespaces.sh` | Creates namespaces, sets retention |
| `status.sh` | One-screen health check; exit code = number of failures |

## New cluster

1. Prepare PostgreSQL (see `setup.md`, Database) and take note of `max_connections`.
2. Write `.env` from `.env.example`.
3. On server-01:
   ```sh
   sudo scripts/install-temporal.sh
   sudo scripts/setup-databases.sh
   sudo scripts/deploy.sh
   sudo scripts/setup-ui.sh
   ```
4. On every other server: `sudo scripts/deploy.sh`.
5. Add the servers to the Cloudflare pool (monitor: HTTP `/health` on :80).
6. Add the cluster to Prometheus: copy `observability/prometheus/targets/temporal-v6.yml.example`.
7. `sudo scripts/status.sh` on each server.

## Add a server

1. Add its private IP to `CLUSTER_IPS`; rsync `.env` to every server.
2. On the existing servers: `sudo scripts/reload-firewall.sh` (no restart).
3. On the new server: `sudo scripts/deploy.sh`. It joins through the database and takes its share of shards.
4. Add it to the Cloudflare pool and to the Prometheus targets.

## Remove a server

1. Remove it from the Cloudflare pool; wait for its connections to move (a few minutes).
2. On it: `sudo systemctl disable --now temporal`. The frontend drains, its shards move within seconds.
3. Remove its IP from `CLUSTER_IPS`, rsync, run `sudo scripts/reload-firewall.sh` on the rest.
4. Remove it from the Prometheus targets.

## Change access lists

Edit `CLIENT_IPS`, `MONITOR_IPS`, `ADMIN_IPS` or `HEALTHCHECK_IPS`, rsync, then on every server:
`sudo scripts/reload-firewall.sh` (plus `setup-nginx.sh` for admin and health-check lists).
Temporal keeps running.

## Change configuration

| Change | Run | Restart |
|---|---|---|
| `config/dynamicconfig.yaml` | `reload-temporal.sh` | No, applied within 10 s |
| `config/temporal.yaml`, profile, `SERVER_PROFILE`, `DB_*` | `reload-temporal.sh` | Yes |
| `NAMESPACES`, `NAMESPACE_RETENTION` | `ensure-namespaces.sh` (any one server) | No |
| `config/nginx.conf` | `setup-nginx.sh` | nginx reload |

Restarting changes: run on one server, wait for its `SERVING ... history ring has N of N hosts` line, then
the next. A dynamic-config key must not appear both in the shared file and in a profile.

## Upgrade Temporal

One minor version at a time (1.31.x → 1.32.x). Schema first, then binaries.

1. Back up both databases (snapshot or PITR mark).
2. Set `TEMPORAL_VERSION` in `.env` and rsync to every server.
3. On every server: `sudo scripts/install-temporal.sh` (stages; nothing restarts).
4. On one server: `sudo scripts/setup-databases.sh` (migrates the schema; old binaries keep working).
5. On each server, one at a time: `sudo scripts/reload-temporal.sh` (validates with the new binary,
   switches `current`, restarts, waits for shards to settle).

Roll back by setting the previous `TEMPORAL_VERSION` and repeating step 5. Only the binary rolls back; the
schema stays, and the previous minor supports it. Once the new version has run under load, rolling back
is not guaranteed safe: prefer fixing forward.

## Incidents

| Symptom | Check | Action |
|---|---|---|
| A script fails | Its `ERROR:` line | Nothing was applied past the failing step; fix and re-run |
| Frontend not healthy after restart | `journalctl -u temporal -n 100` | DB reachability and credentials first |
| `history ring has 1 of N` | `status.sh` on each server, `iptables -S TEMPORAL_INPUT` | Same `CLUSTER_IPS` everywhere; 6933-6939 open between servers |
| `TemporalV6ShardsUnowned` | `status.sh` everywhere | A server is up but not owning shards; restart it |
| `TemporalV6MembershipChurn` | `journalctl -u temporal` | Crash loop or flapping network between servers |
| PostgreSQL down | `pg_isready -h $DB_HOST` | Whole cluster stops; fail over the database, Temporal reconnects |
| Server down | `numshards_gauge` on the others | Survivors take its shards; fix or replace it with `deploy.sh` |
| Memory near MemoryHigh | `status.sh` | Bigger profile or another server |
| Locked out | Cloud console | Port 22 is always open in `TEMPORAL_INPUT`; check the cloud firewall |

Bursts of `shard status unknown` errors in the first seconds after a restart are shard loading and normal.

## Backups

Use the database's point-in-time recovery (pgBackRest/WAL-G or the managed service's) and rehearse a
restore. Separate `pg_dump` runs of the two databases are not consistent with each other. A restore
rewinds every workflow to that moment; activities after it run again.
