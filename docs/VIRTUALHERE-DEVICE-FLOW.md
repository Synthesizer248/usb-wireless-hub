# VirtualHere model and USBHub implementation

## What VirtualHere documents

VirtualHere describes a USB server running on the computer or hub that physically owns the USB ports. Its client discovers servers on the LAN, displays exported devices in a tree, and lets the user choose **Use**; the selected device then appears to the client computer as a directly connected USB device. The client can also stop using a device and return it to the server. VirtualHere documents Bonjour discovery and a single server TCP port, and its client API exposes LIST, USE, and STOP USING operations.

Sources:

- [VirtualHere USB Client](https://www.virtualhere.com/usb_client_software) — client discovery, device tree, Use action, and Linux USB/IP client-driver note.
- [VirtualHere USB Server for Linux](https://www.virtualhere.com/usb_server_software) — user-space server, Raspberry Pi support, Bonjour support, and server port.
- [VirtualHere Server Configuration FAQ](https://www.virtualhere.com/configuration_faq) — Avahi advertisement and service configuration.
- [VirtualHere Client API](https://www.virtualhere.com/client_api) — LIST, USE, and STOP USING commands.
- [VirtualHere Client Configuration FAQ](https://www.virtualhere.com/client_configuration_faq) — the same physical device cannot be used simultaneously by two clients, and client-driver installation requires administrator access.

That documents the user-visible behavior and the exclusive ownership model. It does not mean VirtualHere's server protocol is USB/IP; VirtualHere documents its Linux server as a user-space server and its Linux client as using a USB/IP client driver. USBHub uses its own open USB/IP host/client path and does not copy VirtualHere software or protocol.

## How USBHub handles HID

USBHub has two separate ways to use USB devices:

| Path | What travels over Wi-Fi | What Windows sees | Intended use |
| --- | --- | --- | --- |
| HID/VHF report bridge | HID input reports read from Linux hidraw, plus translated gamepad input from evdev, sent over mutually authenticated TLS | A virtual HID device created through Microsoft's VHF driver | Keyboard, mouse, and supported gamepad input shared by the configured receiver |
| USB/IP device transfer | USB/IP control and endpoint transfers for a physical USB device, carried through the SSH tunnel | The physical USB device enumerated by its normal Windows class driver | An operator-selected device such as a flash drive, printer, or scanner |

The HID/VHF path mirrors input descriptors and reports; it is not a full USB-device tunnel. The current sender does not forward HID output or feature reports or arbitrary device-specific control transfers. USB/IP transfers the physical device and is exclusive: while the Windows PC owns it, the Pi-side driver and HID report bridge cannot use that device.

## VirtualHere-like feature in this project

The Windows installer now creates a **USBHub Device Center** desktop shortcut. The window lists the devices attached to the configured Pi, their USB IDs and device class, and whether each is available, connected to this PC, or unavailable. **Use on this PC** requests an exclusive bind and attaches the device with the installed USB/IP client. **Return to Hub** detaches it from Windows and releases the Pi-side bind. The Pi helper refuses to transfer storage while Linux reports it mounted.

The window warns before taking an HID input device away from the Pi HID/VHF bridge and before disconnecting storage. Newly plugged devices remain on the Pi until someone requests them. That gives multiple PCs a deliberate first-request ownership model instead of having their background scanners race for the same device.

## Differences and limits

- The Device Center uses the Pi hostname or IP already saved in the Windows client settings. The supported hostname usbwirelesshub.local is resolved through mDNS, but the client does not yet browse DNS-SD advertisements to discover multiple hubs like VirtualHere does.
- Each Windows PC still needs the USB/IP client driver installed once. Its upstream installer requests normal Windows administrator approval; Windows does not permit a non-admin app to silently install a kernel driver.
- A device has one owner at a time. If another PC or the Pi is using it, the Device Center reports it as unavailable rather than moving it without a request.
- USB/IP device compatibility varies with the device and transfer type. The development notes record a SanDisk Cruzer Blade enumerating as a FAT32 drive on Windows and an Xbox 360 controller enumerating through USB/IP. They also record read stalls with another flash-drive model. These examples demonstrate the attach path, not universal compatibility.

This is a conceptual implementation of the VirtualHere workflow—browse, request use, and return—using USBHub's existing HID/VHF and USB/IP transports.
