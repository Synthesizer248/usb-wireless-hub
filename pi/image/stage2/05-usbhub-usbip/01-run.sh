#!/bin/bash -e

install -D -m 0755 "${BASE_DIR}/../pi/usbip/manage-usbhub-usbip.sh" \
	"${ROOTFS_DIR}/usr/local/sbin/manage-usbhub-usbip"
install -D -m 0644 "${BASE_DIR}/../pi/usbip/usbhub-usbipd.service" \
	"${ROOTFS_DIR}/etc/systemd/system/usbhub-usbipd.service"
install -D -m 0755 "${BASE_DIR}/../pi/admin/usbhub-first-login-password.sh" \
	"${ROOTFS_DIR}/usr/local/sbin/usbhub-first-login-password"
install -D -m 0644 "${BASE_DIR}/../pi/admin/usbhub-first-login-password.service" \
	"${ROOTFS_DIR}/etc/systemd/system/usbhub-first-login-password.service"
install -D -m 0755 "${BASE_DIR}/../pi/admin/usbhub-ensure-hostname.sh" \
	"${ROOTFS_DIR}/usr/local/sbin/usbhub-ensure-hostname"
install -D -m 0644 "${BASE_DIR}/../pi/admin/usbhub-ensure-hostname.service" \
	"${ROOTFS_DIR}/etc/systemd/system/usbhub-ensure-hostname.service"
install -D -m 0644 "${BASE_DIR}/../pi/admin/cockpit.socket.d/usbwirelesshub-first-login-password.conf" \
	"${ROOTFS_DIR}/etc/systemd/system/cockpit.socket.d/usbwirelesshub-first-login-password.conf"
install -D -m 0755 "${BASE_DIR}/../pi/oled/show-ssh-address.py" \
	"${ROOTFS_DIR}/usr/local/sbin/usbhub-oled-ssh-address"
install -D -m 0644 "${BASE_DIR}/../pi/oled/usbhub-oled.service" \
	"${ROOTFS_DIR}/etc/systemd/system/usbhub-oled.service"
install -D -m 0644 "${BASE_DIR}/../pi/oled/usbhub-oled.env" \
	"${ROOTFS_DIR}/etc/default/usbhub-oled"
install -D -m 0644 "${BASE_DIR}/../pi/oled/usbhub-i2c.conf" \
	"${ROOTFS_DIR}/etc/modules-load.d/usbhub-i2c.conf"

boot_config="${ROOTFS_DIR}/boot/firmware/config.txt"
if [[ ! -f "${boot_config}" ]]; then
	boot_config="${ROOTFS_DIR}/boot/config.txt"
fi
if [[ ! -f "${boot_config}" ]]; then
	echo "Could not find the Raspberry Pi boot config to enable I2C." >&2
	exit 1
fi
if ! grep -Eq '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "${boot_config}"; then
	printf '\n[all]\ndtparam=i2c_arm=on\n' >> "${boot_config}"
fi

for module in usbip-host usbip-core; do
	if ! find "${ROOTFS_DIR}/lib/modules" -type f -path "*/kernel/drivers/usb/usbip/${module}.ko*" -print -quit | grep -q .; then
		echo "Required Raspberry Pi USB/IP kernel module is missing: ${module}" >&2
		exit 1
	fi
done

on_chroot <<- EOF
	systemctl enable usbhub-usbipd.service
	systemctl enable usbhub-first-login-password.service
	systemctl enable usbhub-ensure-hostname.service
	systemctl enable avahi-daemon.service
	systemctl enable cockpit.socket
	systemctl enable usbhub-oled.service
EOF
