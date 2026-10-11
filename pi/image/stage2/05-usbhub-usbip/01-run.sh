#!/bin/bash -e

install -D -m 0755 "${BASE_DIR}/../pi/usbip/manage-usbhub-usbip.sh" \
	"${ROOTFS_DIR}/usr/local/sbin/manage-usbhub-usbip"
install -D -m 0644 "${BASE_DIR}/../pi/usbip/usbhub-usbipd.service" \
	"${ROOTFS_DIR}/etc/systemd/system/usbhub-usbipd.service"

for module in usbip-host usbip-core; do
	if ! find "${ROOTFS_DIR}/lib/modules" -type f -path "*/kernel/drivers/usb/usbip/${module}.ko*" -print -quit | grep -q .; then
		echo "Required Raspberry Pi USB/IP kernel module is missing: ${module}" >&2
		exit 1
	fi
done

on_chroot <<- EOF
	systemctl enable usbhub-usbipd.service
EOF
