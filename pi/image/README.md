# USBHub flash image

This folder defines a Raspberry Pi OS Lite 64-bit image for USBHub. The image is built from the official Raspberry Pi `pi-gen` ARM64 branch and adds the USB/IP userspace tools, the Pi-side guarded bind/unbind helper, a systemd USB/IP server restricted to loopback, and a Cockpit web admin console with Wi-Fi controls. Avahi advertises the configured Pi hostname over mDNS. The kernel and USB/IP host modules come from Raspberry Pi OS packages.

The image contains no Wi-Fi credentials, account password, SSH host keys, TLS private keys, or machine-specific IP address. On first flash, use Raspberry Pi Imager's OS customization to set the hostname, account, Wi-Fi, and SSH access. If the default hostname `raspberrypi`, `usbwirelesshub`, or the image's `usbhub` name is left in place, the first boot changes it to `usbwirelesshub-<onboard-interface-MAC>` before Avahi starts, so multiple hubs do not advertise the same `.local` name. A hostname explicitly chosen in Imager is kept. Do not reuse an image after booting it on more than one Pi without regenerating its SSH host keys.

## Build

Create a `pi-image-v*` tag to start the GitHub Actions build. The workflow builds the image and publishes the compressed `.img.xz` plus a SHA-256 checksum as a GitHub Release asset. It pins the Raspberry Pi `pi-gen` source revision used for the build.

The image build targets 64-bit Raspberry Pi OS Lite and is intended first for Raspberry Pi Zero 2 W. Other 64-bit Raspberry Pi boards may work, but have not been validated by this project.

## Flash and first boot

1. Download the `.img.xz` image and its matching `.img.xz.sha256` checksum file from the [latest GitHub Release](https://github.com/Synthesizer248/usb-wireless-hub/releases/latest). The filename includes the Raspberry Pi OS build date.
2. Verify the image against the checksum before flashing. On Linux/macOS, run `sha256sum -c <image-filename>.sha256` in the download folder. On Windows, run `Get-FileHash -Algorithm SHA256 .\<image-filename>` and compare its hash with the digest in the downloaded `.sha256` file.
3. In Raspberry Pi Imager, choose **Use custom** and select the `.img.xz` file. Choose the destination SD card, then configure a username, a temporary password, Wi-Fi country/network, and SSH access. A custom hostname is optional; the image assigns a unique one when a default name is used.
4. Boot the Pi and wait for it to join the configured Wi-Fi. USB/IP server startup is automatic. TCP port 3240 is accepted only on loopback, so Windows clients must tunnel it over SSH.
5. Find the hostname on the Pi console with `hostnamectl --static`, then open `https://<hostname>.local:9090` from a phone or laptop on the same LAN. Sign in with the Pi account and temporary password created in Raspberry Pi Imager. The first password-authenticated login requires you to choose a new password before continuing; if you sign in over SSH first, that prompt appears there instead. Afterward, use Cockpit's **Accounts** page to change the password whenever needed. Cockpit includes a browser terminal; the Network page manages Wi-Fi through NetworkManager. The initial HTTPS certificate is self-signed, so the browser will show a certificate warning until you trust it. Changing the active Wi-Fi network can interrupt the page until the Pi reconnects.
6. On each Windows PC, run the project bootstrap once. It installs the Windows USB/IP driver with administrator approval, then configures the SSH key, Pi-side storage guard, and automatic client. Eligible devices are claimed by the first configured PC that binds them; see [the Windows USB/IP workflow](../../windows/UsbIp/README.md).

The bundled image includes the device-class-agnostic USB/IP transport. Windows still needs its upstream USB/IP kernel client installed once per PC with administrator approval. The Windows class driver handles an attached USB device. Device compatibility depends on the device's transfer types and the Wi-Fi/network; webcam isochronous streaming is not yet validated.

## Scope and safety

- The Pi refuses to export mounted storage.
- The USB/IP daemon is loopback-only behind SSH; do not expose TCP 3240 to the LAN.
- Cockpit uses the Pi's Linux account authentication and HTTPS on TCP 9090. Keep the web console on a trusted LAN and use a strong Pi account password.
- A device can be claimed by only one PC at a time. Disconnect it from Windows before another PC claims it.
- The image uses the kernel modules shipped for its Raspberry Pi OS kernel. The 6.18 USB/IP camera patch stack built for the development Pi is not applied to this generic image; see [Pi USB/IP patch notes](../usbip/README.md). Camera enumeration is supported, but live webcam streaming is unverified and depends on camera mode and network throughput.
- USB/IP host compatibility and device-class behavior must be validated on the target Pi and devices before production use.
