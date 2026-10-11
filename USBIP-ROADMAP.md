# USB/IP roadmap

## Current state

- The Raspberry Pi provides a USB/IP server protected behind an SSH tunnel.
- A Windows client can install the upstream USB/IP client and attach a selected device.
- Keyboard, mouse, and Xbox 360 controller input have been verified through the HID/VHF bridge.
- A flash drive has been exported to Windows and safely returned to the Pi.
- Device compatibility depends on its USB transfer types, the Pi host controller, the Windows client driver, and the Windows device-class driver. The project has not been validated with every printer, scanner, storage device, or other USB device.

## Next milestones

1. Make Windows client installation reproducible on a clean x64 and ARM64 PC, with signed-driver verification and clear UAC/restart handling.
2. Install and configure the Pi USB/IP server with a guided setup that preserves the SSH-only network boundary and protects mounted storage.
3. Add a device inventory and ownership view that can distinguish devices already used by the Pi HID bridge or storage service.
4. Design a Pi-side lease service before adding auto-attach or multi-PC support. A USB device can have only one active owner at a time.
5. Validate attach, detach, reconnect, and safe storage ejection across representative device classes and Windows versions.

## Safety notes

- Do not export a device while the Pi HID/VHF bridge or another Pi service is using it.
- Eject storage in Windows before detaching it, and refuse Pi exports while a filesystem is mounted.
- Keep USB/IP port 3240 bound to loopback and access it through SSH forwarding; do not expose it directly to the LAN.
- Treat kernel USB/IP crashes as blockers. Reproduce and review them before further attach/detach stress testing.
- Automatic device claiming should require an explicit device-selection policy and an ownership lease so multiple PCs cannot race for the same device.
