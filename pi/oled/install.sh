#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "Run this installer with sudo: sudo bash pi/oled/install.sh" >&2
	exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

apt-get update
apt-get install -y python3-luma.oled i2c-tools

install -D -m 0755 "${script_dir}/show-ssh-address.py" \
	/usr/local/sbin/usbhub-oled-ssh-address
install -D -m 0644 "${script_dir}/usbhub-oled.service" \
	/etc/systemd/system/usbhub-oled.service
install -D -m 0644 "${script_dir}/usbhub-i2c.conf" \
	/etc/modules-load.d/usbhub-i2c.conf

if [[ ! -e /etc/default/usbhub-oled ]]; then
	install -D -m 0644 "${script_dir}/usbhub-oled.env" /etc/default/usbhub-oled
fi

boot_config=/boot/firmware/config.txt
if [[ ! -f "${boot_config}" ]]; then
	boot_config=/boot/config.txt
fi
if [[ ! -f "${boot_config}" ]]; then
	echo "Could not find /boot/firmware/config.txt or /boot/config.txt." >&2
	exit 1
fi
if ! grep -Eq '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "${boot_config}"; then
	printf '\n[all]\ndtparam=i2c_arm=on\n' >> "${boot_config}"
fi

systemctl daemon-reload
systemctl enable usbhub-oled.service

echo "Installed the USBHub OLED SSH address service. Reboot the Pi to enable I2C and start the display."
