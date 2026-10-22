#!/usr/bin/env python3
"""Show the Pi's current Wi-Fi SSH address on a small I2C OLED."""

import ipaddress
import os
import pwd
import subprocess
import time

from PIL import Image, ImageDraw, ImageFont
from luma.core.interface.serial import i2c
from luma.oled.device import sh1106, ssd1306


WIDTH = int(os.environ.get("USBHUB_OLED_WIDTH", "128"))
HEIGHT = int(os.environ.get("USBHUB_OLED_HEIGHT", "32"))
ADDRESS = int(os.environ.get("USBHUB_OLED_ADDRESS", "0x3C"), 0)
ROTATE = int(os.environ.get("USBHUB_OLED_ROTATE", "0"))
DRIVER = os.environ.get("USBHUB_OLED_DRIVER", "ssd1306").lower()
INTERVAL = max(1, int(os.environ.get("USBHUB_OLED_INTERVAL", "10")))


def find_ipv4(interface):
    result = subprocess.run(
        ["ip", "-4", "-o", "addr", "show", "dev", interface, "scope", "global"],
        capture_output=True,
        text=True,
        check=False,
    )
    fields = result.stdout.split()
    try:
        address = fields[fields.index("inet") + 1].split("/", 1)[0]
        return str(ipaddress.IPv4Address(address))
    except (ValueError, IndexError):
        return None


def current_ip():
    address = find_ipv4("wlan0")
    if address:
        return address

    result = subprocess.run(
        ["hostname", "-I"], capture_output=True, text=True, check=False
    )
    for candidate in result.stdout.split():
        try:
            parsed = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if parsed.version == 4 and not parsed.is_loopback:
            return str(parsed)
    return "Waiting for Wi-Fi"


def login_user():
    for account in sorted(pwd.getpwall(), key=lambda item: item.pw_uid):
        if 1000 <= account.pw_uid < 60000 and account.pw_dir.startswith("/home/"):
            return account.pw_name
    return "unknown"


def make_device(serial):
    device_type = {"ssd1306": ssd1306, "sh1106": sh1106}.get(DRIVER)
    if device_type is None:
        raise ValueError("USBHUB_OLED_DRIVER must be ssd1306 or sh1106")
    return device_type(
        serial,
        width=WIDTH,
        height=HEIGHT,
        rotate=ROTATE,
    )


def main():
    serial = i2c(port=1, address=ADDRESS)
    device = make_device(serial)
    font = ImageFont.load_default()
    user = login_user()

    while True:
        image = Image.new("1", (WIDTH, HEIGHT))
        draw = ImageDraw.Draw(image)
        draw.text((0, 0), "USBHub SSH address", font=font, fill=255)
        draw.text((0, 10), current_ip(), font=font, fill=255)
        draw.text((0, 20), f"User: {user}  Port: 22", font=font, fill=255)
        device.display(image)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
