# temporalScale

A Temporal 1.31.3 cluster on plain servers: N servers running every role under systemd, one shared
PostgreSQL, a firewall built from `.env`, nginx for `/health` and the Web UI, and a local lab to try
it all.

| Path              | What it is                                       |
| ----------------- | ------------------------------------------------ |
| `.env.example`    | Cluster settings; copy to `.env` on every server |
| `config/`         | Server config, profiles, systemd units, nginx    |
| `scripts/`        | Everything you run on a server                   |
| `compose.yaml`    | Web UI container (server-01)                     |
| `docs/setup.md`   | How the cluster is built and why                 |
| `docs/runbook.md` | New cluster, add or remove a server, incidents   |
| `lab/`            | Two Ubuntu VPSes and PostgreSQL in docker        |

## Servers

```sh
cp .env.example .env                      # fill in, keep it 0600
rsync -a --exclude lab --exclude .git ./ <server>:temporalScale/
sudo ~/temporalScale/scripts/deploy.sh    # see docs/runbook.md for the full order
```

## Lab

```sh
make up                  # build, start, check
make ssh ARGS='01'       # deploy@tscale-01
make push ARGS='01'      # copy the project with lab/temporal.env as .env
make                     # all commands
```

Details in `lab/README.md`.
