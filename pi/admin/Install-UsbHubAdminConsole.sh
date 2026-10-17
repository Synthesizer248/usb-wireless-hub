#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this installer as root: sudo $0 [hostname]" >&2
	exit 1
fi

if [[ $# -gt 1 ]]; then
	echo "Usage: $0 [hostname]" >&2
	exit 2
fi

if [[ $# -eq 1 ]]; then
	if [[ ! $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
		echo "Hostname must be a single DNS label containing letters, numbers, or internal hyphens." >&2
		exit 2
	fi
	hostnamectl set-hostname "$1"
	if grep -qE '^127[.]0[.]1[.]1[[:space:]]' /etc/hosts; then
		sed -i -E "s|^127[.]0[.]1[.]1[[:space:]].*|127.0.1.1 $1|" /etc/hosts
	else
		printf '127.0.1.1 %s\n' "$1" >> /etc/hosts
	fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	avahi-daemon avahi-utils libnss-mdns \
	cockpit cockpit-system cockpit-networkmanager

systemctl enable --now avahi-daemon.service cockpit.socket
systemctl restart avahi-daemon.service

printf '\nUSBHub admin console: https://%s.local:9090\n' "$(hostnamectl --static)"
printf 'Sign in with a Linux account that has sudo access.\n'
