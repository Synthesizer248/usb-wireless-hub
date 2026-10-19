#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_NAMES=(raspberrypi usbwirelesshub usbhub)
readonly HOSTNAME_PREFIX=usbwirelesshub

current_hostname="$(hostnamectl --static)"
is_default=false
for default_name in "${DEFAULT_NAMES[@]}"; do
	if [[ "$current_hostname" == "$default_name" ]]; then
		is_default=true
		break
	fi
done

# Preserve a hostname explicitly selected by the owner in Raspberry Pi Imager.
if [[ "$is_default" != true ]]; then
	exit 0
fi

mac_address=""
for attempt in $(seq 1 30); do
	for interface in wlan0 eth0; do
		address_file="/sys/class/net/${interface}/address"
		if [[ -r "$address_file" ]]; then
			candidate="$(<"$address_file")"
			if [[ "$candidate" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ && "$candidate" != 00:00:00:00:00:00 ]]; then
				mac_address="${candidate//:/}"
				break 2
			fi
		fi
	done
	sleep 1
done

if [[ -z "$mac_address" ]]; then
	echo "Could not read a stable wlan0 or eth0 MAC address; leaving hostname unchanged." >&2
	exit 1
fi

new_hostname="${HOSTNAME_PREFIX}-${mac_address,,}"
hostnamectl set-hostname "$new_hostname"

if grep -qE '^127[.]0[.]1[.]1[[:space:]]' /etc/hosts; then
	sed -i -E "s|^127[.]0[.]1[.]1[[:space:]].*|127.0.1.1 ${new_hostname}|" /etc/hosts
else
	printf '127.0.1.1 %s\n' "$new_hostname" >> /etc/hosts
fi

logger -t usbhub-ensure-hostname "Set default USBHub hostname to ${new_hostname} from the onboard interface MAC address."
