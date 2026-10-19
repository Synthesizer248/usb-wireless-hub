# USBHub USB/IP operator workflow

## Set up another Windows PC

Extract or clone this repository on the PC and run the installer bootstrap from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
    $PiHost = Read-Host 'Enter the hostname shown by hostnamectl --static on the Pi'
    .\windows\UsbIp\Install-UsbHubClient.ps1 -PiAddress "$PiHost.local"
```

The script installs the verified x64 or ARM64 USBip client after normal UAC approval. Save work first because setup can restart USB hubs. On the Pi, run `hostnamectl --static` and use the returned name with `.local`; the project image assigns a unique hostname if the default `raspberrypi`, `usbwirelesshub`, or `usbhub` name is used. The Pi address and SSH identity are stored in %LOCALAPPDATA%\UsbHub\client.json. The installer installs a dedicated SSH key, the Pi storage guard and its scoped bind permission, and creates a hidden Startup shortcut for the SSH tunnel. The tunnel starts now and at Windows sign-in; devices stay on the Pi until a PC requests them. Desktop shortcuts for USBHub Device Center, Claim USBHub Device (command-line selection), and Stop USBHub Tunnel are also added. The tunnel retries after a connection loss, so a stable mDNS name lets it reconnect when DHCP changes the Pi's address. This depends on the LAN forwarding mDNS multicast between the Windows PC and Pi; some guest Wi-Fi or router isolation settings block it. On the development Windows PC, a direct unicast query to Avahi returned the current Pi address, but Windows name resolution and multicast discovery did not resolve the `.local` name; the LAN's mDNS forwarding/client-isolation behavior still needs correction or validation there.

To install the Device Center or remove the older background auto-claim startup shortcut on an already configured PC, rerun Install-UsbHubClient.ps1 with -SkipPiSetup and the saved hub address. This refreshes the Windows client without reinstalling the Pi safety helper.

For an already configured PC, enter the hostname shown by `hostnamectl --static` on the Pi, then run this from the repository folder:

    $PiHost = Read-Host 'Enter the hostname shown on the Pi'
    .\windows\UsbIp\Install-UsbHubClient.ps1 -PiAddress "$PiHost.local" -SkipPiSetup


The client uses zero-copy receive mode by default. Low-latency mode is available for troubleshooting; select it for one manual claim with -ReceiveMode low-latency, or save it for future attachments by rerunning the installer with -SkipPiSetup -ReceiveMode low-latency. Safely eject and disconnect an existing device before reconnecting it. This mode is a diagnostic fallback, not a guaranteed fix for USB transfer stalls.

The bootstrap installs the Pi-side storage guard and its scoped bind permission used by Device Center. If setting up only the client scripts manually, install them with:

```powershell
.\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action SetupPi
```

This copies the helper and asks the Pi to install it with `sudo`. The Pi must already have its USB/IP server configured and SSH reachable.

This is the first device-class-agnostic connection workflow for the Raspberry Pi USBHub. USB/IP gives Windows the real USB device, so its normal Windows driver handles it; no per-device HID programming is needed. Compatibility still depends on the device, driver, USB transfer types, and Wi-Fi quality.

## How this compares with VirtualHere

VirtualHere documents the same user-facing model: a server shares a physical USB device, the client lists it, and the user chooses **Use**; the device then behaves like a locally connected USB device. USBHub implements that model with the open USB/IP protocol instead of VirtualHere's own server protocol. The Pi exports the physical device through `usbip-host`; its USB/IP daemon is restricted to loopback and the Windows client reaches it through the SSH tunnel. Device Center is the client-side list and **Use on this PC** action. After attachment, Windows enumerates the USB descriptors and loads its normal HID, camera, storage, or other class driver. The server and client are not wire-compatible with VirtualHere.

VirtualHere also documents Bonjour auto-discovery and a client service/API. USBHub uses the Pi's mDNS hostname for discovery and runs a per-user Windows SSH tunnel at sign-in; the operator chooses which device to use. Both systems keep a device exclusive to one client at a time.

References: [VirtualHere client workflow](https://www.virtualhere.com/usb_client_software), [VirtualHere server and Bonjour details](https://www.virtualhere.com/usb_server_software), [VirtualHere client API](https://www.virtualhere.com/client_api), [Linux USB/IP bind handling](https://github.com/torvalds/linux/blob/master/tools/usb/usbip/src/usbip_bind.c), and [Linux USB/IP isochronous transmit path](https://github.com/torvalds/linux/blob/master/drivers/usb/usbip/stub_tx.c). VirtualHere specifically documents that high-bandwidth isochronous webcams do not work in its Raspberry Pi USB-C device-client mode; that is evidence for that mode only, not a blanket statement about its normal network server/client mode.

## One-time Pi setup

From Windows PowerShell, in the repository directory:

    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action SetupPi

This copies pi/usbip/manage-usbhub-usbip.sh to /usr/local/sbin/manage-usbhub-usbip on the Pi. The helper refuses to export storage that Linux currently reports as mounted. SSH and sudo may each ask for the Pi account password.

## Use after setup

After signing in to Windows, the SSH tunnel runs in the background. Open USBHub Device Center from the desktop to see devices connected to the configured Pi. Select one and choose Use on this PC to transfer ownership to this PC; the Pi exports it through USB/IP and Windows loads its normal class driver. A device is exclusive to one PC until returned. The first PC whose attach succeeds owns the device; other requests fail without unbinding the active export. Newly attached devices are not claimed in the background, so PCs do not claim devices without an operator request.

Device Center identifies HID input devices and warns that using one through USB/IP transfers it away from the Pi HID/VHF bridge. A device marked **On hub** is present but not yet exported; **Available** means it is exported and ready for a client request. If a different PC already owns an export, attach fails without unbinding that existing export. The Pi helper refuses a storage device Linux currently has mounted. USB/IP compatibility varies by device class and transfer type.

Webcams are passed as USB devices, not as compressed video streams. Device Center uses the configured receive mode, defaulting to `zero-copy`; `low-latency` remains available for a manual diagnostic retry. The development Pi originally logged `actual length of urb 0 does not match iso packet sizes 6144` during UVC streaming. Patches 0002–0004 now build against and run on the Pi's exact kernel, `6.18.54-v8-usbiscsi+`; details and the installed module hash are in the [Pi USB/IP patch notes](../../pi/usbip/README.md).

The camera was attached to Windows at 480 Mbps and enumerated as `USB2.0 PC CAMERA` with PnP status `OK`. The Windows Camera app requested raw YUY2 640×480 at 30 fps (about 147.5 Mbit/s before transport overhead). A Windows UDE/filter trace recorded 1,441 128-packet isochronous completions; 782 had nonzero payload, totaling 122,969,472 bytes over roughly 94 seconds (about 10.5 Mbit/s). This confirms isochronous URBs and payload moved, but at far below the mode requested by the app. The Windows Camera app then failed with `0xA00F4271<MediaCaptureFailedEvent> (0xC00D36D5)` in both `low-latency` and `zero-copy` receive modes. During the same capture, NetworkManager disconnected the Pi's WLAN, changed its address from `192.168.4.116` to `192.168.0.103`, and later changed it back; Windows UDE recorded `STATUS_CONNECTION_RESET` followed by refused reconnects. The Pi's Avahi service also showed its former generic name colliding and advertising `usbwirelesshub-28.local`. These are two independent problems: a fragile TCP session during Wi-Fi reassociation and a raw video mode far above measured throughput. USB/IP does not compress camera video. The Pi's direct 320×240 YUYV capture also measured about 8.3 fps with 15 fps requested. Therefore USB/IP attach, Windows enumeration, kernel isochronous transfers, and some camera payload are verified; a usable live picture is not. The server-side aggregate-length error did not recur in the final trace. Further kernel changes are not justified without new evidence.

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
- Webcam live streaming is currently failing even though Windows enumerates the camera and receives isochronous payload. The Windows Camera app selected a raw format whose requested bandwidth exceeded the measured Wi-Fi USB/IP throughput by more than an order of magnitude, and the Pi's WLAN reassociated during the trace. The installed USBip client is version 0.9.8.1; its upstream project documents Linux server compatibility through kernel 6.14, while this Pi runs 6.18.54. This version gap is an additional compatibility risk, not proof of the cause. See the [USBip client project](https://github.com/soitun/usbip-win2) and the camera evidence above.
- Device Center uses the configured mDNS hostname or IP for one USBHub; it does not yet browse DNS-SD advertisements to find multiple hubs automatically.
- The tunnel shortcut is registered for the current Windows user. Windows kernel client installation still requires one-time administrator approval; the installer may request a restart.
