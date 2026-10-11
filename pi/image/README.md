# USBHub flash image

This folder defines a Raspberry Pi OS Lite 64-bit image for USBHub. The image is built from the official Raspberry Pi `pi-gen` ARM64 branch and adds the USB/IP userspace tools, the Pi-side guarded bind/unbind helper, and a systemd USB/IP server restricted to loopback. The kernel and USB/IP host modules come from Raspberry Pi OS packages.

The image contains no Wi-Fi credentials, account password, SSH host keys, TLS private keys, or machine-specific IP address. On first flash, use Raspberry Pi Imager's OS customization to set the hostname, account, Wi-Fi, and SSH access. Do not reuse an image after booting it on more than one Pi without regenerating its SSH host keys.

## Build

Create a `pi-image-v*` tag to start the GitHub Actions build. The workflow builds the image and publishes the compressed `.img.xz` plus a SHA-256 checksum as a GitHub Release asset. It pins the Raspberry Pi `pi-gen` source revision used for the build.

The image build targets 64-bit Raspberry Pi OS Lite and is intended first for Raspberry Pi Zero 2 W. Other 64-bit Raspberry Pi boards may work, but have not been validated by this project.

## Flash and first boot

1. Download `USBHub-rpios-lite-arm64.img.xz` and its `.sha256` file from the GitHub Release.
2. Verify the file with `sha256sum -c USBHub-rpios-lite-arm64.img.xz.sha256` on Linux/macOS, or `Get-FileHash -Algorithm SHA256` on Windows and compare the digest.
3. In Raspberry Pi Imager, choose **Use custom** and select the `.img.xz` file. Choose the destination SD card, then configure a unique hostname, username/password, Wi-Fi country/network, and SSH access.
4. Boot the Pi and connect to it over SSH. USB/IP server startup is automatic. TCP port 3240 is accepted only on loopback, so Windows clients must tunnel it over SSH.
5. On each Windows PC, install the USB/IP client once with the project bootstrap, keep the SSH tunnel open, then use `Invoke-UsbHubUsbIp.ps1 -Action Claim` to request a device.

The bundled image includes the device-class-agnostic USB/IP transport. Windows still needs its upstream USB/IP kernel client installed once per PC with administrator approval. The Windows class driver handles an attached USB device. Device compatibility depends on the device's transfer types and the Wi-Fi/network; webcam isochronous streaming is not a supported validation target.

## Scope and safety

- The Pi refuses to export mounted storage.
- The USB/IP daemon is loopback-only behind SSH; do not expose TCP 3240 to the LAN.
- A device can be claimed by only one PC at a time. Disconnect it from Windows before another PC claims it.
- No custom USB/IP kernel patch is included. The image uses the kernel modules shipped for its Raspberry Pi OS kernel. The candidate patch under `pi/usbip/patches/` is diagnostic/source material and is not applied to this image.
- USB/IP host compatibility and device-class behavior must be validated on the target Pi and devices before production use.
