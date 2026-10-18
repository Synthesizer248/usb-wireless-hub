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

## Verification and current limit

- The patched module is loaded on the Pi, and the USB/IP daemon is active.
- A Windows USB/IP attach enumerated the GEMBIRD UVC camera as `USB2.0 PC CAMERA` at 480 Mbps; Windows reported PnP status `OK`.
- Windows Camera failed with `0xA00F4271<MediaCaptureFailedEvent> (0xC00D36D5)` in both `low-latency` and `zero-copy` client receive modes.
- After returning the camera to the Pi, its native `uvcvideo` driver was restored. A local 320×240 YUYV capture completed at about 8.3 fps with 15 fps requested.
- The original `actual length of urb 0 does not match iso packet sizes 6144` message did not recur during the final remote attempt. The Pi later logged `recv a header, 0` and reset the camera as the USB/IP connection ended.

This verifies the Pi camera, server-side patch build/load, USB/IP attachment, and Windows device enumeration. It does not verify live video over USB/IP. The failure cause remains unresolved. The installed Windows USBip client is 0.9.8.1; its upstream project documents Linux server compatibility through kernel 6.14, while this Pi runs 6.18.54. That compatibility range has not been verified for this newer kernel. The next useful evidence is a Windows USBip UDE/filter WPP trace while opening the camera; the trace instructions are in the [client project](https://github.com/soitun/usbip-win2#obtaining-usbip-logs-on-windows).

The Pi source-side details are documented by Raspberry Pi's [DWC2 host completion](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/usb/dwc2/hcd.c), [isochronous packet accounting](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/usb/dwc2/hcd_intr.c), and Linux USB/IP [transmit path](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/usb/usbip/stub_tx.c).
