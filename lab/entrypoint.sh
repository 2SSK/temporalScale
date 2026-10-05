#!/bin/sh
# lab/entrypoint.sh - Create a persistent ssh host key on first boot, then start systemd.
set -eu

hostkey=/etc/ssh/hostkeys/ssh_host_ed25519_key
install -d -m 0700 /etc/ssh/hostkeys
[ -s "$hostkey" ] || ssh-keygen -q -t ed25519 -N '' -C tscale -f "$hostkey"

exec /sbin/init
