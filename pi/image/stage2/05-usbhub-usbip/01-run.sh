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
EOF
