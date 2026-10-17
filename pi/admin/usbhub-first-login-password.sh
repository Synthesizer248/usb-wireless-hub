#!/usr/bin/env bash
set -euo pipefail

state_dir=/var/lib/usbhub
marker="$state_dir/first-login-password-armed"

if [[ -s $marker ]]; then
	exit 0
fi

install -d -m 0755 "$state_dir"

# Raspberry Pi Imager creates the first account during first boot. Select the
# lowest-UID interactive sudo user with an existing password, which is the
# Imager-created administrator on a standard USBHub image.
while IFS=: read -r username _ uid _ _ _ shell; do
	[[ $uid =~ ^[0-9]+$ ]] || continue
	(( uid >= 1000 && uid < 60000 )) || continue
	[[ $shell != */nologin && $shell != */false ]] || continue
	id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -qx sudo || continue

	password_state=$(passwd -S "$username" 2>/dev/null | awk '{print $2}') || continue
	[[ $password_state == P ]] || continue

	chage --lastday 0 "$username"
	printf '%s\n' "$username" > "$marker.tmp"
	chmod 0600 "$marker.tmp"
	mv -f "$marker.tmp" "$marker"
	logger -t usbhub-first-login-password \
		"Required password change for first administrator '$username'."
	exit 0
done < <(getent passwd | sort -t: -k3,3n)

logger -t usbhub-first-login-password \
	"No interactive sudo account with a set password was found; password setup was not armed."
echo "No interactive sudo account with a set password was found; configure a first user in Raspberry Pi Imager." >&2
exit 1
