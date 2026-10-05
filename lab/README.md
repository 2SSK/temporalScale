# tscale

Two fresh Ubuntu 24.04 VPSes and a Postgres box on the private network `tscale` (10.78.0.0/24).
From the project root, `make <command>` runs the same commands (`make ssh ARGS='01 id'`).

| Host      | IP         | What it is                                                                            |
| --------- | ---------- | ------------------------------------------------------------------------------------- |
| tscale-01 | 10.78.0.11 | VPS A: systemd, sshd, `deploy` with sudo                                              |
| tscale-02 | 10.78.0.12 | VPS B: same                                                                           |
| tscale-pg | 10.78.0.20 | postgres:17.11, user `temporal` / `tscaletemporal` (superuser in the lab only), empty |

No ports are published. Your workstation reaches 10.78.0.x directly.

```sh
./lab.sh up          # build, start, check
./lab.sh ssh 01      # deploy@tscale-01
./lab.sh psql
./lab.sh push 01     # copy the project and temporal.env (as .env) to ~/temporalScale
./lab.sh ui-up       # ../compose.yaml inside tscale-01's network; open http://10.78.0.11:8080
./lab.sh             # all commands
```

`stop`/`start` is a reboot: everything is kept, and a running UI comes back with tscale-01. `down` is
a reprovision: only `/opt`, `/etc/temporal`, `/var/lib/temporal`, `/home/deploy` and the ssh host
key survive. apt packages, systemd units and nginx config are gone, so script your install; the UI
is removed too. `reset` wipes everything, Postgres included.

Unlike a real VPS: one shared kernel and clock (no clock skew), privileged containers,
iptables rules apply only inside each host's network namespace.
