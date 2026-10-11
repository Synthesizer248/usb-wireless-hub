#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 list | bind BUS_ID | unbind BUS_ID" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
action=$1

case "$action" in
    list)
        [[ $# -eq 1 ]] || usage
        exec usbip list --local
        ;;
    bind|unbind)
        [[ $# -eq 2 ]] || usage
        bus_id=$2
        [[ "$bus_id" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] || {
            echo "Invalid USB bus ID: $bus_id" >&2
            exit 2
        }
        [[ $EUID -eq 0 ]] || {
            echo "Run bind/unbind with sudo." >&2
            exit 1
        }
        device="/sys/bus/usb/devices/$bus_id"
        [[ -e "$device" ]] || {
            echo "USB device is no longer present: $bus_id" >&2
            exit 1
        }

        if [[ "$action" == bind ]]; then
            device_real="$(readlink -f "$device")" || {
                echo "Cannot resolve USB device path: $device" >&2
                exit 1
            }
            # Scan the block-device index and compare resolved sysfs parents.
            # A recursive find -L in sysfs can follow driver links into unrelated
            # devices and hang on link cycles.
            for block_path in /sys/class/block/*; do
                [[ -e "$block_path/device" ]] || continue
                block_real="$(readlink -f "$block_path/device")" || continue
                case "$block_real" in
                    "$device_real"/*|"$device_real":*)
                        block_device="/dev/$(basename "$block_path")"
                        if lsblk -nrpo MOUNTPOINT "$block_device" 2>/dev/null | grep -q '[^[:space:]]'; then
                            echo "Refusing to export mounted storage: $block_device" >&2
                            exit 1
                        fi
                        ;;
                esac
            done
            exec usbip bind -b "$bus_id"
        else
            exec usbip unbind -b "$bus_id"
        fi
        ;;
    *)
        usage
        ;;
esac
