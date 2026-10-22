# USBHub OLED SSH address display

The optional OLED service shows the Pi's current IPv4 address, the first configured login username, and SSH port 22. It refreshes every 10 seconds and displays `Waiting for Wi-Fi` until the Pi receives an address. It supports common 128×32 I²C SSD1306 modules and can also be configured for SH1106.

## Wiring

Power the Pi off before wiring. This table is for a four-pin I²C module labelled `VCC`, `GND`, `SCL`, and `SDA`:

| OLED | Raspberry Pi Zero / Zero 2 W |
| --- | --- |
| VCC | Physical pin 1 (3.3 V) |
| GND | Physical pin 6 (Ground) |
| SCL | Physical pin 5 (GPIO3 / SCL1) |
| SDA | Physical pin 3 (GPIO2 / SDA1) |

Use 3.3 V, not 5 V. The Pi's GPIO signals use 3.3 V logic. Confirm the display's pin labels and controller before connecting; SPI modules with extra `CS`, `DC`, or `RES` pins need different wiring and are not covered by this guide.

## Included in a newly built image

The Pi image build installs the OLED library and I²C tools, enables the I²C overlay, and enables `usbhub-oled.service`. Connect the display before powering on. The default configuration is in `/etc/default/usbhub-oled`:

```ini
USBHUB_OLED_DRIVER=ssd1306
USBHUB_OLED_ADDRESS=0x3C
USBHUB_OLED_WIDTH=128
USBHUB_OLED_HEIGHT=32
USBHUB_OLED_ROTATE=0
USBHUB_OLED_INTERVAL=10
```

Most 0.91-inch modules are 128×32 SSD1306 at address `0x3C`, but module variants differ. If the display is not detected, check its I²C address with `sudo i2cdetect -y 1`; `0x3D` is another common address. For an SH1106 module, set `USBHUB_OLED_DRIVER=sh1106`. Restart after changing the configuration:

```sh
sudo systemctl restart usbhub-oled.service
sudo systemctl status usbhub-oled.service --no-pager
```

## Install on an existing Pi

From a checkout of this repository on the Pi, run:

```sh
sudo bash pi/oled/install.sh
sudo reboot
```

The installer adds the required Debian packages, enables I²C in the boot configuration, and enables the service. The display should start after reboot. The service can be diagnosed with `journalctl -u usbhub-oled.service -b`.
