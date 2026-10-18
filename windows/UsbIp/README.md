# USBHub USB/IP operator workflow

## Set up another Windows PC

Extract or clone this repository on the PC and run the installer bootstrap from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\UsbIp\Install-UsbHubClient.ps1 -PiAddress usbwirelesshub.local
```

The script selects the x64 or ARM64 upstream USBip installer, verifies its SHA-256 digest and Authenticode signature, and starts the official interactive setup with UAC. Save work first: setup can restart USB hubs. Administrator approval and any restart requested by the upstream installer are still required; Windows does not allow a normal user script to silently install kernel drivers. Configure a stable hostname in Raspberry Pi Imager and use its `<hostname>.local` mDNS name here instead of a DHCP address. For the current hub, use `usbwirelesshub.local`. This keeps the client reachable when the router changes the Pi's IP address. The target and SSH identity are stored in `%LOCALAPPDATA%\UsbHub\client.json` for this Windows account. The script installs a dedicated SSH key on the Pi, copies the client scripts into `%LOCALAPPDATA%\UsbHub\client`, installs the Pi safety helper and its narrowly scoped sudo rule, and creates hidden Startup shortcuts for the SSH tunnel and automatic claiming. They start when the current session is configured and at Windows sign-in. The Pi account password is requested while authorizing the key; the Pi sudo password is requested once to install the helper and rule. Desktop shortcuts for **Claim USBHub Device** (manual override) and **Stop USBHub Tunnel** are also added.

When only changing a Windows client's stored Pi hostname or repairing its Startup shortcuts after the Pi safety helper was already installed, add `-SkipPiSetup`. That updates the Windows client without reinstalling the Pi helper.

The client uses USBip's `zero-copy` receive mode by default. `low-latency` is also supported for troubleshooting device-specific transfer problems. Select it for one manual claim with `-ReceiveMode low-latency`, or save it for automatic claims by rerunning the installer with `-SkipPiSetup -ReceiveMode low-latency`. The setting applies to new attachments; safely eject and disconnect an existing device before reconnecting it. This mode is a diagnostic fallback, not a guaranteed fix for device-side endpoint stalls or failing media.

The bootstrap installs the Pi-side storage guard and its scoped automatic bind permission. If setting up only the client scripts manually, install them with:

```powershell
.\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action SetupPi
```

This copies the helper and asks the Pi to install it with `sudo`. The Pi must already have its USB/IP server configured and SSH reachable.

This is the first device-class-agnostic connection workflow for the Raspberry Pi USBHub. USB/IP gives Windows the real USB device, so its normal Windows driver handles it; no per-device HID programming is needed. Compatibility still depends on the device, driver, USB transfer types, and Wi-Fi quality.

## One-time Pi setup

From Windows PowerShell, in the repository directory:

    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action SetupPi

This copies pi/usbip/manage-usbhub-usbip.sh to /usr/local/sbin/manage-usbhub-usbip on the Pi. The helper refuses to export storage that Linux currently reports as mounted. SSH and sudo may each ask for the Pi account password.

## Use after setup

After signing in to Windows, the tunnel and auto-claim monitor run in the background. When a supported device is plugged into the Pi, each configured PC checks for it; the first PC whose Pi-side bind succeeds gets exclusive ownership, and Windows loads its normal class driver. Other PCs skip the already-claimed device. If several PCs start together, whichever wins the USB/IP bind race owns the device. For deterministic ownership, enable automatic claiming on only the intended PC and use manual **Claim USBHub Device** on others.

Automatic claiming excludes HID devices and devices bound to the Pi's HID/gamepad drivers (the Pi's HID/VHF bridge handles those), USB hubs, network adapters, and webcams. It attempts other USB classes, including mass-storage devices; the Pi helper refuses a storage device that is mounted on the Pi. USB/IP compatibility still varies by device class and transfer type. The manual Claim shortcut remains available for devices that need an explicit selection.

The shortcuts use the installed copy of the client scripts, so the repository folder can be moved or removed after setup. **Stop USBHub Tunnel** stops both background processes for the current session; they start again at the next Windows sign-in.

For command-line inventory and ownership, run the installed client script:

    & "$env:LOCALAPPDATA\UsbHub\client\windows\UsbIp\Invoke-UsbHubUsbIp.ps1" -Action Inventory
    & "$env:LOCALAPPDATA\UsbHub\client\windows\UsbIp\Invoke-UsbHubUsbIp.ps1" -Action Claim

`Claim` binds the selected device on the Pi and attaches it to this PC. The Pi USB/IP host allows only one client to bind a physical device at a time; another PC can claim it after this PC disconnects. For a scripted selection, use the explicit current bus ID:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Connect -BusId 1-1.4

After connecting the devices this PC should reconnect, save those imports as persistent:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Persist

This saves every currently imported device and lets the upstream USBip client retry attachments after driver load or connection loss. Keep the SSH tunnel available, and do not persist a device intended for another PC. See the upstream [persistent device and automatic reattachment notes](https://github.com/vadimgrn/usbip-win2/wiki/How-automatic-reattachment-works).

Connect exports the selected device through the Pi safety helper, then attaches it through the SSH tunnel. Windows should enumerate it with its normal device-class driver. Bus IDs can change after unplugging or rebooting, so get a fresh inventory before connecting.

Inspect active connections:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Ports

For storage, close open files and use Windows Safely Remove Hardware first. Then disconnect the imported port shown by Ports:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Disconnect -Port 1

The command asks for confirmation, detaches from Windows, then unbinds the device on the Pi. Action Release with BusId returns an already-disconnected export to the Pi. Action Attach is available only for a device that was exported separately. Action Persist saves the current imports for reattachment by that Windows PC.

## Ownership and current limits

- A physical USB device has one owner at a time. `Claim` is an operator-requested, exclusive claim; it is not an automatic cross-PC lease service. Do not USB/IP-connect a keyboard, mouse, or gamepad that is already being forwarded by the Pi HID/VHF service, or a drive currently used by iSCSI.
- The Pi USB/IP daemon remains restricted to loopback; keep its SSH tunnel open while using the USB/IP connection. Do not open TCP port 3240 to Wi-Fi.
- Storage needs safe ejection on Windows before disconnecting. The Pi-side helper also refuses to bind mounted filesystems.
- Xbox 360 USB/IP attach and input have passed on the development PC with the rebuilt Pi USB/IP host modules. This confirms the basic attach path; it does not prove every device class.
- A SanDisk Cruzer Blade (0781:5567) was exported and mounted by Windows as a FAT32 volume with drive letter F: on the development PC. A different SanDisk Cruzer Force (0781:557d) was auto-claimed and assigned F:, but Windows reads stalled and the Pi logged repeated USB/IP endpoint 1 stalls. That is a transfer failure after enumeration, not a claim or drive-letter failure. The low-latency receive mode is available as a diagnostic retry but has not yet been verified with this model. Safely eject it before disconnecting; do not initialize or format it if Windows prompts. Other drives and filesystems still need validation.
- Printer and scanner compatibility still needs device-by-device testing.
- Auto-claim uses first successful Pi-side bind as its ownership rule. Multiple PCs can race for a newly attached device; only one can win. To avoid accidental assignment, leave auto-claim enabled on the intended PC and use manual Claim on other PCs.
- The tunnel and auto-claim shortcuts are registered for the current Windows user. Windows kernel client installation still requires one-time administrator approval; the installer may request a restart.
