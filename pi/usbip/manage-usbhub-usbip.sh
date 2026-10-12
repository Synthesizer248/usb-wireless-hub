#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 list | inventory | bind BUS_ID | unbind BUS_ID" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
action=$1

case "$action" in
    list)
        [[ $# -eq 1 ]] || usage
        exec usbip list --local
        ;;
    inventory)
        [[ $# -eq 1 ]] || usage
        for device in /sys/bus/usb/devices/*; do
            bus_id="${device##*/}"
            [[ "$bus_id" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] || continue
            [[ -r "$device/idVendor" && -r "$device/idProduct" ]] || continue
            vendor="$(<"$device/idVendor")"
            product="$(<"$device/idProduct")"
            classes=()
            drivers=()
            if [[ -r "$device/bDeviceClass" ]]; then
                classes+=("$(<"$device/bDeviceClass")")
            fi
            if [[ -L "$device/driver" ]]; then
                drivers+=("$(basename "$(readlink -f "$device/driver")")")
            fi
            for interface in "$device":*; do
                [[ -r "$interface/bInterfaceClass" ]] || continue
                classes+=("$(<"$interface/bInterfaceClass")")
                if [[ -L "$interface/driver" ]]; then
                    drivers+=("$(basename "$(readlink -f "$interface/driver")")")
                fi
            done
            class_list="$(printf '%s\n' "${classes[@]}" | sort -u | paste -sd, -)"
            driver_list="$(printf '%s\n' "${drivers[@]}" | sort -u | paste -sd, -)"
            printf '%s\t%s:%s\t%s\t%s\n' "$bus_id" "$vendor" "$product" "$class_list" "$driver_list"
        done
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
