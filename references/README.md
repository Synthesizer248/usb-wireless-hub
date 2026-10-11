# Imported upstream projects

## USB/IP client for Windows

- Upstream source and releases: [vadimgrn/usbip-win2](https://github.com/vadimgrn/usbip-win2)
- Imported upstream commit: `07146875dd21fd3c2f1f185bb753f63974f1df71` (`master`)
- License: BSD 2-Clause; keep `usbip-win2/LICENSE.txt` and upstream copyright notices when redistributing source or derived binaries.
- Purpose: reuse the Windows USB/IP client, virtual host controller, and CLI so the project can import ordinary USB devices without implementing the USB protocol or a separate Windows driver for each device class.

The Raspberry Pi uses Linux's USB/IP host implementation. Devices are selected by the Pi's current USB bus ID. Do not hard-code a drive serial number or `/dev/sdX` path; either can differ after swapping drives or rebooting.

Project-owned integration lives in `windows/UsbIp/Invoke-UsbHubUsbIp.ps1` and `USBIP-ROADMAP.md`. Do not patch upstream files in place; keep project-specific work in this repository and preserve the upstream license.

The development machine used the upstream Windows installer. The upstream source checkout and build products are intentionally excluded from this project repository; use the signed upstream installer for client setup. A USB/IP command-line executable alone is not sufficient for device import; the client driver must also be installed.
