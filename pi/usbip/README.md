# Pi USB/IP kernel patch set

## Patch order

Apply these patches in order to a matching Raspberry Pi Linux source tree:

1. `patches/0002-usbip-stub-derive-isoc-submit-length.patch` fixes a DWC2 isochronous completion where packet descriptors reported bytes but the aggregate URB length was zero. It rejects inconsistent nonzero totals and totals larger than the transfer buffer.
2. `patches/0003-usbip-stub-coherent-isoc.patch` allocates large isochronous transfer buffers through the USB DMA API instead of relying on high-order `kmalloc` allocations, and fixes allocation cleanup.
3. `patches/0004-usbip-stub-free-dma-outside-lock.patch` defers coherent-buffer cleanup until the USB/IP transmit thread is outside IRQ-disabled spinlocks.

`patches/0001-usbip-stub-keep-urb-array-state-consistent.patch` is a separate candidate allocation-error fix. It is not part of the tested stack described below.

## Build and deployment on the development Pi

The tested machine is a Raspberry Pi Zero 2 W running `6.18.54-v8-usbiscsi+`. Patches 0002–0004 were applied to its matching source tree and the USB/IP modules were rebuilt with the kernel's existing output/configuration tree:

```sh
k="/lib/modules/$(uname -r)/build"
src="$k/source"

make -j1 -C "$src" O="$k" HOSTCC=gcc HOSTCXX=g++ LOCALVERSION=+ prepare
make -j1 -C "$src" O="$k" HOSTCC=gcc HOSTCXX=g++ LOCALVERSION=+ \
  M="$src/drivers/usb/usbip" modules
modinfo -F vermagic "$src/drivers/usb/usbip/usbip-host.ko"
```

The built host module reported the exact running release and AArch64 vermagic. It was installed with a backup and activated by reboot. The currently installed, decompressed `usbip-host.ko` SHA-256 is:

```text
61437971874b959c0b9dbb845d1e10beb577b540ab80d30ed90463a01fb2b1f8
```

Do not apply the patches a second time to this already-patched development source tree. For another Pi, start with the exact source/configuration for its running kernel, apply 0002–0004 in order, rebuild, confirm `vermagic`, back up existing modules, and activate the replacement during a planned reboot. The patch stack has not been included in the downloadable flash image.

## Camera trace evidence and current limit

The USB/IP host patch is loaded, the daemon is active, and the GEMBIRD UVC camera (1908:2311) attached to Windows at 480 Mbps as `USB2.0 PC CAMERA` with PnP status `OK`. This establishes USB/IP enumeration, not successful live capture.

During a Windows Camera attempt, FrameServer requested raw YUY2 640×480 at 30 fps (147.5 Mbit/s of image data before transport overhead). A decoded Windows UDE/filter WPP capture contained 2,181 filter events, 6,425 UDE events, no lost/format errors, and 1,989 filter-layer isochronous transfers. It recorded 1,441 128-packet isochronous completions; 782 returned nonzero payload, totaling 122,969,472 bytes between approximately 05:22:06 and 05:23:41 (about 10.5 Mbit/s). Payload moved, but far below the rate required by the format requested by Windows. USB/IP forwards raw USB transfers and does not compress or resize video.

The same capture shows a second cause for interruption: NetworkManager disconnected/reassociated the Pi WLAN around 05:23:38, moved the Pi from `192.168.4.116` to `192.168.0.103`, and later restored `192.168.4.116`. Windows recorded `STATUS_CONNECTION_RESET` followed by refused reconnects. Avahi had also renamed the old generic host to `usbwirelesshub-28.local` after a hostname collision. The development Pi now has a unique mDNS hostname, and image installs now derive one from the onboard interface MAC when a default hostname is used. An active USB/IP TCP session still ends when Wi-Fi reassociates; the tunnel may retry, but a live capture is not transparently resumed by this trace.

A repeat attempt on 2026-10-19 confirmed the interruption independently: USB/IP stub start and UVC isochronous alternate setting 1 were logged at 06:13:30–06:13:37; NetworkManager restarted DHCP at 06:14:59 and leased `192.168.0.102` at 06:15:02 on the same `TP-Link_6986` Wi-Fi profile; the kernel reset the USB/IP camera at 06:15:01. The Pi later returned to `192.168.4.116`. At the time, the Windows PC was `192.168.4.111`. Windows mDNS lookup and multicast discovery did not resolve the current `.local` name, although a direct unicast DNS query to Avahi at the known Pi address returned the correct A record. This shows Avahi is advertising the name, but this LAN's Wi-Fi/DHCP transition and multicast path still prevent transparent reachability. The cause of the DHCP subnet change and the router/AP configuration are not established from these logs; no undervoltage message appeared in this repeat window.

Windows Camera failed with `0xA00F4271<MediaCaptureFailedEvent> (0xC00D36D5)` in both `low-latency` and `zero-copy` receive modes. The Pi's native 320×240 YUYV test measured about 8.3 fps with 15 fps requested. The old `actual length of urb 0 does not match iso packet sizes 6144` kernel message did not recur in this final remote attempt. After release, `uvcvideo` was successfully restored on the camera. This proves the patched host path and some camera payload transport, but not a usable remote picture. The remaining limiter is not yet completely isolated; the Windows USBip client is 0.9.8.1 and its upstream compatibility notes document Linux server kernels through 6.14, while this Pi runs 6.18.54. See the [USBip client project trace instructions](https://github.com/soitun/usbip-win2#obtaining-usbip-logs-on-windows).

The Pi source-side details are documented by Raspberry Pi's [DWC2 host completion](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/usb/dwc2/hcd.c), [isochronous packet accounting](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/usb/dwc2/hcd_intr.c), and Linux USB/IP [transmit path](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/usb/usbip/stub_tx.c).
