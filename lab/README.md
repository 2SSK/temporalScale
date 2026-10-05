# tlab

Two fresh Ubuntu 24.04 VPSes and a Postgres box on the private network `tlab` (10.77.0.0/24).
Git-ignored. The course is in `../docs/ops-curriculum.md`.

| Host | IP | What it is |
|---|---|---|
| tlab-01 | 10.77.0.11 | VPS A: systemd, sshd, `deploy` with sudo |
| tlab-02 | 10.77.0.12 | VPS B: same |
| tlab-pg | 10.77.0.20 | postgres:17.11, user `temporal` / `tlabtemporal` (superuser in the lab only), empty |

No ports are published. Your workstation reaches 10.77.0.x directly.

```sh
./lab.sh up          # build, start, check
./lab.sh ssh 01      # deploy@tlab-01
./lab.sh psql
./lab.sh push 01     # copy the project to ~/temporal-v6 with HOST_IP set
./lab.sh ui-up       # ../compose.yaml inside tlab-01's network; open http://10.77.0.11
./lab.sh             # all commands
```

`stop`/`start` is a reboot: everything is kept. `down` is a reprovision: only `/opt`,
`/etc/temporal`, `/var/lib/temporal`, `/home/deploy` and the ssh host key survive. apt
packages, systemd units and nginx config are gone, so script your install. `reset`
wipes everything, Postgres included.

Unlike a real VPS: one shared kernel and clock (no clock skew), privileged containers,
iptables rules apply only inside each host's network namespace.
