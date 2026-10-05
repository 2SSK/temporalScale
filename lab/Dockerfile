# lab/Dockerfile - A fresh Ubuntu 24.04 VPS: systemd as PID 1, sshd, a deploy user with sudo.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server sudo ca-certificates curl \
      iproute2 iputils-ping iptables netcat-openbsd less vim-tiny tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN rm -f /etc/ssh/ssh_host_*_key* \
    && useradd --create-home --shell /bin/bash --groups sudo,adm,systemd-journal deploy \
    && echo 'deploy ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/deploy \
    && chmod 0440 /etc/sudoers.d/deploy

COPY sshd-lab.conf /etc/ssh/sshd_config.d/lab.conf
COPY --chmod=0755 entrypoint.sh /usr/local/bin/lab-entrypoint

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/bin/lab-entrypoint"]
CMD ["/sbin/init"]
