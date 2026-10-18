# USBHub: wireless HID and USB/IP sharing (development copy)

## Windows USB/IP client setup on a new PC

The project includes a one-command client bootstrap for Windows x64 and ARM64. From an extracted copy of this repository, open PowerShell and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\UsbIp\Install-UsbHubClient.ps1 -PiAddress usbwirelesshub.local
```

The bootstrap downloads the pinned USBip release from its upstream GitHub release, checks its SHA-256 digest and Authenticode signature, then opens the vendor installer with a UAC prompt. The installer may briefly restart USB hubs; save work and pause USB transfers first. Windows administrator approval is required to install its kernel driver. The Pi address is saved per Windows account. The installer also configures the Pi storage guard and creates a USBHub Device Center desktop shortcut.

The installer keeps the SSH tunnel open after Windows sign-in. Devices remain attached to the Pi until a user opens the USBHub Device Center desktop shortcut and chooses Use on this PC. The first PC whose operator requests a device and wins the Pi bind gets exclusive ownership; the device can then be returned from Device Center. The client does not auto-claim devices in the background.

```powershell
.\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Tunnel
```

```powershell
.\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Claim
```

`Claim` lists devices currently attached to the Pi, lets the local operator choose one, and requests an exclusive USB/IP bind-and-attach. The first PC to claim a device gets it; another PC cannot claim it while it is bound or attached. Use `-Action Disconnect -Port <n>` to return it to the Pi, then another PC can claim it. Windows loads its normal class driver after attachment, so printers, storage, cameras, and other classes do not need a USBHub-specific device driver. The USB/IP client driver itself must be installed once per PC by the bootstrap above; Windows administrator approval is required. `-Action Persist` is optional and saves all currently imported devices on that PC for automatic reconnect.

The broad goal is a wireless USB hub for devices such as flash drives, printers, and scanners. The HID/VHF report bridge shares supported keyboard, mouse, and gamepad input over Wi-Fi; USB/IP gives a selected Windows PC ownership of the real USB device for broader class support. See [the VirtualHere comparison and evidence](docs/VIRTUALHERE-DEVICE-FLOW.md) and [USBIP-ROADMAP.md](USBIP-ROADMAP.md). The Windows USB/IP client is maintained upstream; see [references/README.md](references/README.md).

To flash a fresh Raspberry Pi OS Lite image with the USB/IP host service and storage safety helper, see [the Pi image build and flashing guide](pi/image/README.md). The image is built for 64-bit Raspberry Pi OS and is currently targeted at the Zero 2 W; configure Wi-Fi, account, hostname, and SSH in Raspberry Pi Imager on first flash.

## Pi web admin console

The flash image includes Cockpit and Avahi. From a phone or laptop on the same LAN, open `https://<Pi-hostname>.local:9090` (for example, `https://usbwirelesshub.local:9090`). On the first password-authenticated login, enter the temporary password configured in Raspberry Pi Imager; the Pi then requires you to set your own password before continuing. Later, use Cockpit's **Accounts** page to change the password again. Cockpit also provides a browser terminal and, through its NetworkManager component, Wi-Fi SSID/password management. The first visit uses a self-signed HTTPS certificate and may show a browser warning. Changing the active Wi-Fi connection can interrupt the console until the Pi reconnects. For an existing Pi, run `sudo bash pi/admin/Install-UsbHubAdminConsole.sh usbwirelesshub` from the repository to install it and set a unique mDNS hostname; this existing-Pi installer does not force a password change.

This repository does not yet have a project-wide license. The Microsoft VHF reference files include their MIT license, and the upstream USB/IP client is separately licensed by its maintainers. Public visibility does not grant reuse rights for the project-owned code.

This experimental branch is being generalized from one keyboard to multiple USB HID interfaces. The Raspberry Pi reads USB HID interfaces from Linux `hidraw` and can translate standard Linux `evdev` gamepad events into a standard HID Game Pad report; Windows receives descriptors and reports over mutual TLS and asks the KMDF/VHF driver to create matching virtual HID devices. This is HID transport, not a general USB/IP implementation.

- `pi/sender/sender.py` discovers USB `hidraw` interfaces with valid input reports, independent of VID/PID. It also loads `pi/sender/evdev_gamepad.py` to translate standard gamepads exposed by Linux's input subsystem (including Xbox 360 controllers handled by `xpad`). It supports up to 32 interfaces and reconnects when the set of attached interfaces changes. The gamepad path uses Python's standard library and Linux evdev ioctls; it does not need an extra Python package.
- `windows/Receiver` is a .NET 10 console receiver. It validates the HID descriptor and each report's ID/length before calling the generic driver IOCTLs.
- The KMDF/VHF driver copy creates and removes virtual HID devices at runtime from the supplied report descriptors. The existing driver in the original `hid-bridge` folder remains unchanged.
- TLS remains mutual and certificate-pinned. The Pi client certificate is pinned by Windows; the Windows server certificate is pinned by the Pi.
- `references/microsoft-dmf-vhf/` contains a downloaded Microsoft VHF module and its MIT license for source study only; it is not a build dependency.

Expected examples are keyboards, mice, standard HID gamepads, and scanners that expose an HID keyboard or other supported HID input collection. The evdev translation path forwards gamepad buttons and axes as a standard HID Game Pad, but does not forward vibration/force feedback. This does not forward other non-HID USB devices, HID output/feature reports, or device-specific control transfers. A descriptor being mirrored does not guarantee every Windows application understands a vendor-specific gamepad collection.

The generic driver has been installed on the development PC as a separate root device, alongside the original keyboard bridge. Keep the two device identities separate; do not replace the original driver with this experimental package. It is a locally test-signed development driver, not a production-signed release.

## Generic wire protocol

Each TLS message has a 4-byte unsigned big-endian body length followed by a body. Maximum body size is 8192 bytes.

| Type | Body layout |
| --- | --- |
| `1` create | type (1), 16-byte session device ID, descriptor length (u16 BE), VID (u16 BE), PID (u16 BE), version (u16 BE), report descriptor bytes |
| `2` input report | type (1), 16-byte device ID, report ID (u8), report length (u16 BE), input report bytes (from hidraw or translated evdev gamepad events) |
| `3` remove | type (1), 16-byte device ID |

The receiver derives valid input-report lengths from the descriptor. It rejects unknown devices, report IDs, malformed frames, and length mismatches. On disconnect it submits zero reports and removes that session's virtual HID devices.

## Certificates (self-signed, IP connection)

Use OpenSSL on Windows and the Raspberry Pi. Choose the receiver's fixed LAN IP and replace `192.168.1.100` below with that address. Keep private keys private. The receiver private key is included in `receiver.pfx`; the Pi client private key stays on the Pi. Copy only `pi-client.crt` (not its private key) to the Windows receiver. The Pi needs `receiver.crt` only if you want to retain a copy; the sender trusts the configured fingerprint, not a CA file.

### 1. Create the receiver certificate on Windows

From PowerShell in the repository root (with `openssl.exe` on `PATH`):

```powershell
New-Item -ItemType Directory -Force C:\hid-bridge\certs | Out-Null
openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes -keyout C:\hid-bridge\certs\receiver.key -out C:\hid-bridge\certs\receiver.crt -subj "/CN=hid-bridge-receiver" -addext "subjectAltName=IP:192.168.1.100"
openssl pkcs12 -export -out C:\hid-bridge\certs\receiver.pfx -inkey C:\hid-bridge\certs\receiver.key -in C:\hid-bridge\certs\receiver.crt -name hid-bridge-receiver
Remove-Item -LiteralPath C:\hid-bridge\certs\receiver.key
```

OpenSSL prompts for the PFX export password. The IP Subject Alternative Name is included for certificate correctness, but sender trust is based on the explicit SHA-256 pin and does not depend on a hostname match or CA validation.

### 2. Create the Pi client certificate on the Raspberry Pi

```sh
mkdir -p ~/hid-bridge/certs
cd ~/hid-bridge/certs
umask 077
openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes -keyout pi-client.key -out pi-client.crt -subj "/CN=hid-bridge-pi"
chmod 600 pi-client.key
```

Securely copy `pi-client.crt` to `C:\hid-bridge\certs\pi-client.crt` on Windows. Do not copy `pi-client.key` off the Pi.

### 3. Obtain both certificate fingerprints

These commands print SHA-256 fingerprints of the certificates' DER encoding. The output is certificate-specific; generate and use the actual values from your files. The applications accept the colon-separated output value.

On Windows, get the **Pi client certificate fingerprint** for receiver configuration:

```powershell
openssl x509 -in C:\hid-bridge\certs\pi-client.crt -noout -fingerprint -sha256
```

On Windows, get the **receiver server certificate fingerprint** for Pi configuration:

```powershell
openssl x509 -in C:\hid-bridge\certs\receiver.crt -noout -fingerprint -sha256
```

The fingerprint displayed after `=` in the first command is the receiver's client-certificate pin. The fingerprint after `=` in the second command is the Pi's mandatory server-certificate pin. Do not include the `SHA256 Fingerprint=` label when supplying a value.

## Build and run

### Build both components in one command

From an elevated or normal PowerShell window in this project directory, run:

```powershell
.\build-generic.ps1
```

The helper builds the receiver and selects a Visual Studio installation with the WDK targets, using 64-bit MSBuild for the driver package checks.

### Build the Windows receiver

Install the .NET 10 SDK, then run from the repository root in PowerShell:

```powershell
dotnet build .\windows\Receiver\UsbVhfReceiver.csproj --configuration Release
```

### Build the VHF driver

Open `UsbHubVhfKeyboard.slnx` in Visual Studio with the WDK installed, select the `Debug | x64` development configuration, and build. The generic driver creates each virtual HID child at runtime after the receiver gets that device's descriptor. Keep it separate from the original keyboard-only device.

### Run the receiver

Run from an **elevated Administrator PowerShell terminal** on Windows where the existing device interface is already available; the driver interface ACL grants access only to Administrators and LocalSystem. Supply the PFX password and the **Pi client certificate fingerprint**. Use port `5001` here to keep the generic experiment separate from the working bridge on `5000`:

```powershell
$receiverExe = '.\windows\Receiver\bin\Release\net10.0\UsbVhfReceiver.exe'
$clientFingerprint = (openssl x509 -in C:\hid-bridge\certs\pi-client.crt -noout -fingerprint -sha256).Split('=')[1].Trim()
& $receiverExe 'C:\hid-bridge\certs\receiver.pfx' 'YOUR_PFX_PASSWORD' $clientFingerprint 5001
```

The receiver opens the generic bridge driver interface before listening. This command does not install the VHF driver or change Windows settings.

### Run the Pi sender

Copy both `pi/sender/sender.py` and `pi/sender/evdev_gamepad.py` into the same directory on the Pi, then run the sender with the receiver's IP, port, the **receiver server certificate fingerprint**, and the Pi client certificate/key paths. Replace the fingerprint placeholder with the complete output after `=` from the receiver fingerprint command above:

```sh
cd ~/hid-bridge/certs
sudo python3 /path/to/sender.py 192.168.1.100 5001 'AA:BB:CC:REPLACE_WITH_THE_COMPLETE_64_HEX_DIGIT_FINGERPRINT' ./pi-client.crt ./pi-client.key
```

There is no CA-file argument. The sender does not forward reports unless the TLS handshake succeeds with the configured client certificate and the server certificate fingerprint matches exactly. It skips unreadable, malformed, non-USB, or input-report-free descriptors and forwards input reports only.

## Optional automatic startup (development machine)

The Windows generic receiver can be registered as a separate Scheduled Task at the current administrator account's logon. It runs elevated so it can open the VHF driver interface. It publishes under `%ProgramData%\UsbHub\GenericReceiver`. The PFX password is stored using Windows DPAPI for the current account, not in task arguments. Store the Pi client certificate pin in `%LOCALAPPDATA%\UsbHub\certs\pi-client.sha256`; the launcher reads this per-PC value instead of embedding it in source:

```powershell
$pin = (openssl x509 -in C:\hid-bridge\certs\pi-client.crt -noout -fingerprint -sha256).Split('=')[1].Trim()
$certDir = Join-Path $env:LOCALAPPDATA 'UsbHub\certs'
New-Item -ItemType Directory -Path $certDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $certDir 'pi-client.sha256') -Value $pin -NoNewline
```

The task starts only after that account logs on.

From an elevated PowerShell window in `windows\Receiver`, run:

```powershell
.\Register-UsbHubReceiverTask.ps1
```

The script prompts for the PFX password and registers the task but does not start it. Stop any manually running receiver, then start it with:

```powershell
Start-ScheduledTask -TaskName 'USBHub Generic HID Bridge Receiver'
Get-NetTCPConnection -LocalPort 5001 -State Listen
```

The generic receiver uses port 5001, so it can run beside the working receiver on 5000. Add a Windows Firewall inbound TCP rule for 5001 if needed. The Pi sender can run under systemd as root so it can read `/dev/hidraw*`. Copy `pi/sender/usbhub-hid-sender-generic.service` to `/etc/systemd/system/` and `pi/sender/usbhub-hid-sender-generic.env.example` to `/etc/usbhub-hid-sender-generic.env`. Set the receiver IP, certificate pin, and certificate paths in the environment file, then restrict it to root:

```sh
sudo chown root:root /etc/usbhub-hid-sender-generic.env
sudo chmod 600 /etc/usbhub-hid-sender-generic.env
```

Then run:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now usbhub-hid-sender-generic.service
sudo systemctl status usbhub-hid-sender-generic.service --no-pager
```

The generic sender uses the paths configured in its environment file and the TLS client certificate/key. The original Pi sender service remains separate. The sender retries while the receiver is unavailable and refreshes its virtual devices when USB HID interfaces are plugged or unplugged.

## Validation status

### General USB/IP prototype

The separate USB/IP track uses the upstream `usbip-win2` project. The Pi USB/IP daemon is configured for loopback behind SSH forwarding. The Xbox 360 controller attached through USB/IP and passed an input test on a development PC. A flash drive was listed as exportable and mounted on Windows, then safely returned to the Pi. See [windows/UsbIp/README.md](windows/UsbIp/README.md) for the current operator workflow and [USBIP-ROADMAP.md](USBIP-ROADMAP.md) for the broader product plan.

The USB/IP client bootstrap creates a persistent SSH tunnel and starts an automatic claim monitor at Windows sign-in. The monitor claims eligible newly connected devices for the first configured PC that wins the Pi-side bind race. It leaves HID devices on the Pi's VHF bridge and does not automatically move USB hubs, network adapters, or webcams. The PowerShell helper at `windows/UsbIp/Invoke-UsbHubUsbIp.ps1` also supports read-only Inventory/List/Ports, SetupPi, Claim for an interactive manual choice, Connect for a known bus ID, and Disconnect/Release to return devices to the Pi. For storage, eject it in Windows before disconnecting. Do not USB/IP-connect a device simultaneously used by Pi HID/VHF or iSCSI. USB/IP is device-class agnostic, but printer and scanner compatibility still require hardware testing.

- The .NET 10 receiver and KMDF/VHF driver build successfully. WDK Universal API validation and INF signability checks passed, and the development package was test-signed.
- End-to-end keyboard and mouse input over Wi-Fi have been verified on the Raspberry Pi and Windows development PC. The receiver authenticated the Pi with mutual TLS and created runtime VHF devices from the attached keyboard's HID collections; Windows keyboard and mouse input worked.
- The Pi's generic sender and Windows receiver can be configured to start at boot or account logon, listening on TCP port 5001.
- Keyboard, mouse, and Xbox 360 gamepad input over Wi-Fi have been verified on the Raspberry Pi and Windows development PC. The Xbox controller is read through Linux evdev and translated into a standard HID Game Pad; buttons and axes work. Vibration/force feedback is not implemented. Barcode scanners have not been verified. The bridge does not provide general USB/IP, output or feature reports, or device-specific control transfers.
- The generic device is installed on the development PC under its own root device identity, separate from the original keyboard prototype. The package uses local test signing and is intended for development, not production deployment.

