# USBHub USB/IP operator workflow

## Set up another Windows PC

Extract or clone this repository on the PC and run the installer bootstrap from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\UsbIp\Install-UsbHubClient.ps1 -PiAddress usbwirelesshub.local
```

The script installs the verified x64 or ARM64 USBip client after normal UAC approval. Save work first because setup can restart USB hubs. Configure a stable Raspberry Pi hostname and use its .local mDNS name; for this hub, use usbwirelesshub.local. The Pi address and SSH identity are stored in %LOCALAPPDATA%\UsbHub\client.json. The installer installs a dedicated SSH key, the Pi storage guard and its scoped bind permission, and creates a hidden Startup shortcut for the SSH tunnel. The tunnel starts now and at Windows sign-in; devices stay on the Pi until a PC requests them. Desktop shortcuts for USBHub Device Center, Claim USBHub Device (command-line selection), and Stop USBHub Tunnel are also added.

To install the Device Center or remove the older background auto-claim startup shortcut on an already configured PC, rerun Install-UsbHubClient.ps1 with -SkipPiSetup and the saved hub address. This refreshes the Windows client without reinstalling the Pi safety helper.

For the current hub, from the repository folder run:

    .\windows\UsbIp\Install-UsbHubClient.ps1 -PiAddress usbwirelesshub.local -SkipPiSetup


The client uses zero-copy receive mode by default. Low-latency mode is available for troubleshooting; select it for one manual claim with -ReceiveMode low-latency, or save it for future attachments by rerunning the installer with -SkipPiSetup -ReceiveMode low-latency. Safely eject and disconnect an existing device before reconnecting it. This mode is a diagnostic fallback, not a guaranteed fix for USB transfer stalls.

The bootstrap installs the Pi-side storage guard and its scoped bind permission used by Device Center. If setting up only the client scripts manually, install them with:

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

After signing in to Windows, the SSH tunnel runs in the background. Open USBHub Device Center from the desktop to see devices connected to the configured Pi. Select one and choose Use on this PC to transfer ownership to this PC; the Pi binds it through USB/IP and Windows loads its normal class driver. A device is exclusive to one PC until returned. The first PC whose operator requests it and wins the Pi bind gets it. Newly attached devices are not claimed in the background, so multiple PCs do not race each other.

Device Center identifies HID input devices and warns that using one through USB/IP transfers it away from the Pi HID/VHF bridge. A device marked Unavailable / in use is not being offered by USB/IP; it may be in use by the Pi or another PC. The Pi helper refuses a storage device Linux currently has mounted. USB/IP compatibility varies by device class and transfer type.

The shortcuts use the installed copy of the client scripts, so the repository folder can be moved or removed after setup. Stop USBHub Tunnel stops the background tunnel for the current session; it starts again at the next Windows sign-in.

For command-line inventory and ownership as an alternative to Device Center, run the installed client script:

    & "$env:LOCALAPPDATA\UsbHub\client\windows\UsbIp\Invoke-UsbHubUsbIp.ps1" -Action Inventory
    & "$env:LOCALAPPDATA\UsbHub\client\windows\UsbIp\Invoke-UsbHubUsbIp.ps1" -Action Claim

`Claim` binds the selected device on the Pi and attaches it to this PC. The Pi USB/IP host allows only one client to bind a physical device at a time; another PC can claim it after this PC disconnects. For a scripted selection, use the explicit current bus ID:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Connect -BusId 1-1.4

To make current imports persistent after reconnecting this PC, run:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Persist

This saves every currently imported device and lets the upstream USBip client retry attachments after driver load or connection loss. Keep the SSH tunnel available, and do not persist a device intended for another PC. See the upstream [persistent device and automatic reattachment notes](https://github.com/vadimgrn/usbip-win2/wiki/How-automatic-reattachment-works).

Connect exports the selected device through the Pi safety helper, then attaches it through the SSH tunnel. Windows should enumerate it with its normal device-class driver. Bus IDs can change after unplugging or rebooting, so get a fresh inventory before connecting.

Inspect active connections:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Ports

For storage, close open files and use Windows Safely Remove Hardware first. Then disconnect the imported port shown by Ports:

    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Disconnect -Port 1

The command asks for confirmation, detaches from Windows, then unbinds the device on the Pi. Action Release with BusId returns an already-disconnected export to the Pi. Action Attach is available only for a device that was exported separately. Action Persist saves the current imports for reattachment by that Windows PC.

## Ownership and current limits

- A physical USB device has one owner at a time. Device Center Use on this PC is an operator-requested exclusive claim. HID devices normally use the separate Pi HID/VHF report bridge; claiming one through USB/IP transfers the physical device and interrupts that bridge while it is owned here. Do not claim a drive currently used by iSCSI.
- The Pi USB/IP daemon remains restricted to loopback; keep its SSH tunnel open while using the USB/IP connection. Do not open TCP port 3240 to Wi-Fi.
- Storage needs safe ejection on Windows before disconnecting. The Pi-side helper also refuses to bind mounted filesystems.
- Xbox 360 USB/IP attach and input have passed on the development PC with the rebuilt Pi USB/IP host modules. This confirms the basic attach path; it does not prove every device class.
- A SanDisk Cruzer Blade (0781:5567) was exported and mounted by Windows as a FAT32 volume with drive letter F: on the development PC. A different SanDisk Cruzer Force (0781:557d) was claimed and assigned F:, but Windows reads stalled and the Pi logged repeated USB/IP endpoint 1 stalls. That is a transfer failure after enumeration, not a claim or drive-letter failure. Low-latency receive mode is available as a diagnostic retry but has not yet been verified with this model. Safely eject it before disconnecting; do not initialize or format it if Windows prompts. Other drives and filesystems still need validation.
- Printer and scanner compatibility still needs device-by-device testing.
- Device Center uses the configured mDNS hostname or IP for one USBHub; it does not yet browse DNS-SD advertisements to find multiple hubs automatically.
- The tunnel shortcut is registered for the current Windows user. Windows kernel client installation still requires one-time administrator approval; the installer may request a restart.
