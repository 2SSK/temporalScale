# temporalScale setup

One Temporal 1.31.3 cluster = N servers + one PostgreSQL. Every server runs the Temporal binary
(all four roles in one process) under systemd and points at the same database; the shared database
makes them one cluster. Servers discover each other through it and split the history shards. Staging
and production are separate clusters with separate PostgreSQL servers.

```
workers ── 7233 ──► Cloudflare LB (DNS-only, /health) ──► any server's frontend
admins  ── :80  ──► server-01 nginx ──► Web UI container
Prometheus ── :9091, :9100 ──► every server

   server-01 ◄── 6933-6939, 7233-7243 ──► server-02 ◄──► server-N
       └──────────────── PostgreSQL ─────────┘   temporal + temporal_visibility
```

## Repository layout

| Path                                                          | Purpose                                                                          |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `.env`                                                        | Cluster settings, identical on every server (copy of `.env.example`, not in git) |
| `config/temporal.yaml`                                        | Server config; values come from `.env` and the profile at start                  |
| `config/dynamicconfig.yaml`                                   | Runtime settings shared by every profile, incl. shutdown drain; hot-reloaded     |
| `config/profiles/<size>.yaml`                                 | Host limits and cache sizes per server size                                      |
| `config/temporal.service`, `config/temporal-firewall.service` | systemd units                                                                    |
| `config/nginx.conf`                                           | `:80` — `/health` for the load balancer, `/` the Web UI                          |
| `config/journald.conf`, `config/rsyslog-temporal.conf`        | Log size cap; Temporal kept out of syslog                                        |
| `compose.yaml`                                                | Web UI container (server-01)                                                     |
| `scripts/`                                                    | Everything you run; see the runbook                                              |
| `lab/`                                                        | Local two-VPS lab                                                                |

## What lands on a server

| Path                                                        | Owner         | Content                                                                                         |
| ----------------------------------------------------------- | ------------- | ----------------------------------------------------------------------------------------------- |
| `/opt/temporal/releases/<version>/`                         | root          | `temporal-server`, `temporal-sql-tool`, `tdbg`, `schema/`                                       |
| `/opt/temporal/current`                                     | root          | Symlink to the running release; switched by `reload-temporal.sh`                                |
| `/opt/temporal/cli/<version>/temporal`                      | root          | Temporal CLI                                                                                    |
| `/etc/temporal/`                                            | root:temporal | `temporal.yaml`, `temporal.env` (0600), `dynamicconfig.yaml`, `profile.yaml`, `firewall*.rules` |
| `/etc/nginx/conf.d/temporal.conf` + `temporal-*-allow.conf` | root          | nginx site and generated allow lists                                                            |
| `/var/log/temporalScale.log`                                | root          | Log of every script run                                                                         |

The server runs as the `temporal` system user, which can read but not change its binary or config.
Logs: `journalctl -u temporal` (capped at 1 GB / 2 weeks).

## `.env`

| Variable                                                                      | Meaning                                                                    |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `TEMPORAL_VERSION`, `TEMPORAL_CLI_VERSION`                                    | Pinned releases                                                            |
| `SERVER_PROFILE`                                                              | `2c4g`, `2c8g`, `4c16g` or `8c32g`                                         |
| `NUM_HISTORY_SHARDS`                                                          | Fixed forever at the cluster's first start (staging 1024, production 4096) |
| `CLUSTER_IPS`                                                                 | Private IP of every server; each server finds its own IP here              |
| `CLIENT_IPS`                                                                  | May call 7233: workers and starters                                        |
| `MONITOR_IPS`                                                                 | May scrape 9091 and 9100: the Prometheus host                              |
| `ADMIN_IPS`                                                                   | May open the Web UI on :80                                                 |
| `HEALTHCHECK_IPS`                                                             | May GET `/health` on :80: Cloudflare health-check ranges                   |
| `NAMESPACES`, `NAMESPACE_RETENTION`                                           | Namespaces kept by `ensure-namespaces.sh`                                  |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_TLS`, `DB_ADMIN_DATABASE` | PostgreSQL; password `[A-Za-z0-9._~-]` only                                |
| `TEMPORAL_UI_*`, `UI_*`                                                       | Web UI container                                                           |

Scripts validate `.env` before acting (password characters, `DB_TLS`, shard count, host IP).

## Server profiles

| Profile | MemoryHigh / Max | GOMEMLIMIT | History cache | Events cache | DB pool per role | Max shards per host |
| ------- | ---------------- | ---------- | ------------- | ------------ | ---------------- | ------------------- |
| 2c4g    | 2700M / 3200M    | 1800MiB    | 256 MiB       | 128 MiB      | 20 + 5           | 1024                |
| 2c8g    | 6000M / 6800M    | 4000MiB    | 768 MiB       | 384 MiB      | 30 + 5           | 2048                |
| 4c16g   | 13000M / 14000M  | 8600MiB    | 2 GiB         | 1 GiB        | 50 + 10          | 4096                |
| 8c32g   | 27000M / 29000M  | 18000MiB   | 4 GiB         | 2 GiB        | 80 + 10          | 8192                |

- `GOMEMLIMIT` is two thirds of `MemoryHigh`; a tighter gap has caused an outage.
- Caches are bounded in bytes per host, so memory does not grow with the shard count (an idle shard is
  about 150 KB, measured).
- `reload-temporal.sh` refuses a profile larger than the host and warns when one server down would push
  the survivors past the profile's shard limit.
- Rate limits are Temporal's defaults. If PostgreSQL saturates, set `*.persistenceMaxQPS` from what it
  sustains rather than lowering request limits.

## Shards

Set `NUM_HISTORY_SHARDS` before the first start; it can never change. Size for one server down:
`shards / (servers - 1) <= max shards per host`. Staging 1024 on 2 × 2c4g and production 4096 on
2 × 4c16g fit; a third server gives headroom.

## Database

- Each role opens its own pool: a server can hold `4 × (main + visibility)` connections (2c4g: 100,
  4c16g: 240). Size `max_connections` for `servers × that` plus headroom; measure with
  `persistence_sql_open_conn`. Never route Temporal through PgBouncer in transaction mode.
- Self-hosted: give `DB_USER` `CREATEDB`; `setup-databases.sh` creates missing databases.
- Managed: pre-create `temporal` and `temporal_visibility` owned by `DB_USER`, set `DB_TLS=true`, allow
  the `btree_gin` extension (Azure: `azure.extensions`), and set `DB_ADMIN_DATABASE` if `postgres` is closed.
- PostgreSQL is the cluster's single point of failure: run it with a replica, failover and point-in-time
  recovery, and rehearse a restore.

## Network and firewall

| Port                                      | Open to                                                 |
| ----------------------------------------- | ------------------------------------------------------- |
| 22                                        | Anyone                                                  |
| 80                                        | `ADMIN_IPS` (UI) and `HEALTHCHECK_IPS` (`/health` only) |
| 7233 frontend gRPC                        | `CLIENT_IPS`, `CLUSTER_IPS`                             |
| 6933-6939, 7234-7243                      | `CLUSTER_IPS` only                                      |
| 9091 Temporal metrics, 9100 node_exporter | `MONITOR_IPS`                                           |
| IPv6                                      | 22 only                                                 |

`reload-firewall.sh` builds `TEMPORAL_INPUT` chains (IPv4 and IPv6) from `.env`; a boot unit restores
them before the network comes up. Docker and other chains are untouched. Never run
`netfilter-persistent save`: it would freeze these chains into a second, stale copy.

**Security model.** 7233 is plain gRPC without authentication: every address in `CLIENT_IPS` has full
admin rights over the cluster. Keep that list to your own servers, prefer private networks between them,
and add mTLS when clients outside your networks need access. Do not put broad shared ranges (e.g. all
Cloudflare egress) in `CLIENT_IPS`; Cloudflare health checks use `/health` on :80 instead.

## Client access and health checks

Cloudflare Load Balancing in **DNS-only** mode, one origin per server, TTL 30-60 s. Monitor: HTTP GET
`http://<server>/health` (returns the frontend's system info, 200 when the frontend is up), with
Cloudflare's health-check ranges in `HEALTHCHECK_IPS`. On stop, a frontend fails its gRPC health check
for 10 s and drains in-flight calls for 30 s (`/health` stays 200 until the process exits), so take a server
out of the pool before planned maintenance. Clients reconnect and re-resolve DNS when a server dies; expect
up to a few minutes of retries for some workers after a hard failure.

## Web UI

Runs on server-01 as the `temporalio/ui` container (host network, auth off) against the local frontend,
behind nginx on :80 restricted to `ADMIN_IPS`. Other servers return 502 on `/`.

## Monitoring

Prometheus scrapes every server directly on 9091 and 9100. No alert rules ship with this project; define
them for: server down, unowned shards, membership churn, persistence errors and latency, server errors,
host memory, CPU headroom for one-server-down, clock sync.

## Lab

`lab/` (driven by `make` from the root) runs two Ubuntu 24.04 systemd containers (10.78.0.11,
10.78.0.12) and PostgreSQL 17.11 (10.78.0.20); the workstation (10.78.0.1) is client, monitor and
admin. `lab/lab.sh push 01` copies the project with `lab/temporal.env` as `.env`; `lab/lab.sh ui-up`
runs the UI in tscale-01's network. Shared kernel and clock: no clock-skew, kernel or cloud-init
testing.