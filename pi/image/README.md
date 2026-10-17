# USBHub flash image

This folder defines a Raspberry Pi OS Lite 64-bit image for USBHub. The image is built from the official Raspberry Pi `pi-gen` ARM64 branch and adds the USB/IP userspace tools, the Pi-side guarded bind/unbind helper, a systemd USB/IP server restricted to loopback, and a Cockpit web admin console with Wi-Fi controls. Avahi advertises the configured Pi hostname over mDNS. The kernel and USB/IP host modules come from Raspberry Pi OS packages.

The image contains no Wi-Fi credentials, account password, SSH host keys, TLS private keys, or machine-specific IP address. On first flash, use Raspberry Pi Imager's OS customization to set the hostname, account, Wi-Fi, and SSH access. Do not reuse an image after booting it on more than one Pi without regenerating its SSH host keys.

## Build

Create a `pi-image-v*` tag to start the GitHub Actions build. The workflow builds the image and publishes the compressed `.img.xz` plus a SHA-256 checksum as a GitHub Release asset. It pins the Raspberry Pi `pi-gen` source revision used for the build.

The image build targets 64-bit Raspberry Pi OS Lite and is intended first for Raspberry Pi Zero 2 W. Other 64-bit Raspberry Pi boards may work, but have not been validated by this project.

## Flash and first boot

1. Download the `.img.xz` image and its matching `.img.xz.sha256` checksum file from the [latest GitHub Release](https://github.com/Synthesizer248/usb-wireless-hub/releases/latest). The filename includes the Raspberry Pi OS build date.
2. Verify the image against the checksum before flashing. On Linux/macOS, run `sha256sum -c <image-filename>.sha256` in the download folder. On Windows, run `Get-FileHash -Algorithm SHA256 .\<image-filename>` and compare its hash with the digest in the downloaded `.sha256` file.
3. In Raspberry Pi Imager, choose **Use custom** and select the `.img.xz` file. Choose the destination SD card, then configure a unique hostname, username/password, Wi-Fi country/network, and SSH access.
4. Boot the Pi and connect to it over SSH. USB/IP server startup is automatic. TCP port 3240 is accepted only on loopback, so Windows clients must tunnel it over SSH.
5. Open `https://<hostname>.local:9090` from a phone or laptop on the same LAN. Sign in with the Pi account created in Raspberry Pi Imager. Cockpit includes a browser terminal; the Network page manages Wi-Fi through NetworkManager. The initial HTTPS certificate is self-signed, so the browser will show a certificate warning until you trust it. Changing the active Wi-Fi network can interrupt the page until the Pi reconnects.
6. On each Windows PC, run the project bootstrap once. It installs the Windows USB/IP driver with administrator approval, then configures the SSH key, Pi-side storage guard, and automatic client. Eligible devices are claimed by the first configured PC that binds them; see [the Windows USB/IP workflow](../../windows/UsbIp/README.md).

The bundled image includes the device-class-agnostic USB/IP transport. Windows still needs its upstream USB/IP kernel client installed once per PC with administrator approval. The Windows class driver handles an attached USB device. Device compatibility depends on the device's transfer types and the Wi-Fi/network; webcam isochronous streaming is not a supported validation target.

## Scope and safety

- The Pi refuses to export mounted storage.
- The USB/IP daemon is loopback-only behind SSH; do not expose TCP 3240 to the LAN.
- Cockpit uses the Pi's Linux account authentication and HTTPS on TCP 9090. Keep the web console on a trusted LAN and use a strong Pi account password.
- A device can be claimed by only one PC at a time. Disconnect it from Windows before another PC claims it.
- No custom USB/IP kernel patch is included. The image uses the kernel modules shipped for its Raspberry Pi OS kernel. The candidate patch under `pi/usbip/patches/` is diagnostic/source material and is not applied to this image.
- USB/IP host compatibility and device-class behavior must be validated on the target Pi and devices before production use.
