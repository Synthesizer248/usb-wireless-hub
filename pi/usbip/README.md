# Pi USB/IP kernel patches

`patches/0001-usbip-stub-keep-urb-array-state-consistent.patch` records a
separate candidate fix for an allocation-error cleanup issue.

`patches/0002-usbip-stub-derive-isoc-submit-length.patch` addresses the camera
failure seen on the development Pi. Its kernel log reported
`actual length of urb 0 does not match iso packet sizes 6144`. The patch makes
the USB/IP host derive the response's aggregate byte count from the received
isochronous packet descriptors when a host controller leaves the aggregate
URB length at zero. It rejects nonzero totals that disagree and packet totals
larger than the transfer buffer.

The USB/IP protocol and Windows client remain unchanged. Windows still receives
the physical UVC device through USB/IP and uses its normal camera driver. This
fix only addresses the malformed length metadata that currently tears down the
Pi-side USB/IP connection; it does not compress video or remove Wi-Fi timing
limits.

## Build and deployment status

These are source patches only. The current downloadable Pi image still uses
Raspberry Pi OS's packaged kernel modules and does not include patch 0002. The
patch has not yet been built, installed, or validated with the camera. Do not
assume camera support is working until a patched module is built against the
exact running kernel, loaded, and the UVC stream succeeds on the target Pi and
Windows PC.

Apply patch 0002 to the matching Raspberry Pi Linux source tree and rebuild the
USB/IP modules against the output tree for the Pi's running kernel. The
`usbip-core` and `usbip-host` modules should be rebuilt together so their symbol
versions match. Preserve backups of installed modules before replacing them;
do not install modules built for a different `uname -r` or kernel configuration.
