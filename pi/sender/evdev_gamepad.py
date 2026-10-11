#!/usr/bin/env python3
"""Translate Linux evdev gamepad events into a standard HID gamepad input report."""

import fcntl
import hashlib
import os
import struct

MAX_DEVICES = 32
MAX_REPORT_LENGTH = 4096
MESSAGE_CREATE = 1
MESSAGE_REPORT = 2
MESSAGE_REMOVE = 3

# Linux input event constants used by common USB gamepads, including xpad.
EV_SYN = 0x00
EV_KEY = 0x01
EV_ABS = 0x03
SYN_REPORT = 0
SYN_DROPPED = 3
BTN_GAMEPAD = 0x130
BTN_SOUTH = 0x130
BTN_EAST = 0x131
BTN_NORTH = 0x133
BTN_WEST = 0x134
BTN_TL = 0x136
BTN_TR = 0x137
BTN_TL2 = 0x138
BTN_TR2 = 0x139
BTN_SELECT = 0x13A
BTN_START = 0x13B
BTN_MODE = 0x13C
BTN_THUMBL = 0x13D
BTN_THUMBR = 0x13E
BTN_DPAD_UP = 0x220
BTN_DPAD_DOWN = 0x221
BTN_DPAD_LEFT = 0x222
BTN_DPAD_RIGHT = 0x223
ABS_X = 0x00
ABS_Y = 0x01
ABS_Z = 0x02
ABS_RX = 0x03
ABS_RY = 0x04
ABS_RZ = 0x05
ABS_HAT0X = 0x10
ABS_HAT0Y = 0x11

BUTTON_USAGE = {
    BTN_SOUTH: 0, BTN_EAST: 1, BTN_NORTH: 2, BTN_WEST: 3,
    BTN_TL: 4, BTN_TR: 5, BTN_TL2: 6, BTN_TR2: 7,
    BTN_SELECT: 8, BTN_START: 9, BTN_THUMBL: 10, BTN_THUMBR: 11,
    BTN_MODE: 12,
}
DPAD_BUTTONS = {BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT}
AXIS_CODES = (ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ, ABS_HAT0X, ABS_HAT0Y)
STICK_CODES = (ABS_X, ABS_Y, ABS_RX, ABS_RY)
TRIGGER_CODES = (ABS_Z, ABS_RZ)
EVENT_STRUCT = struct.Struct('@llHHi')
ABS_INFO_STRUCT = struct.Struct('@iiiiii')

# Generic Desktop / Game Pad collection, 16 buttons, hat switch, four signed
# stick axes and two unsigned trigger axes. Input report size is 13 bytes.
GAMEPAD_REPORT_DESCRIPTOR = bytes((
    0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x10, 0x81, 0x02,
    0x05, 0x01, 0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00,
    0x46, 0x3B, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34,
    0x16, 0x00, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02,
    0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xFF, 0x00,
    0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
    0xC0,
))


def _ioc(direction, kind, number, size):
    return (direction << 30) | (size << 16) | (kind << 8) | number


def _read_bits(fd, event_type, maximum_code):
    length = (maximum_code + 8) // 8
    bits = bytearray(length)
    request = _ioc(2, ord('E'), 0x20 + event_type, length)
    fcntl.ioctl(fd, request, bits, True)
    return {code for code in range(maximum_code + 1)
            if bits[code // 8] & (1 << (code % 8))}


def _usb_identity(device_path):
    path = os.path.realpath(device_path)
    for _ in range(16):
        vendor_path = os.path.join(path, 'idVendor')
        product_path = os.path.join(path, 'idProduct')
        if os.path.isfile(vendor_path) and os.path.isfile(product_path):
            try:
                with open(vendor_path, 'r', encoding='ascii') as stream:
                    vendor = int(stream.read().strip(), 16)
                with open(product_path, 'r', encoding='ascii') as stream:
                    product = int(stream.read().strip(), 16)
                version_path = os.path.join(path, 'bcdDevice')
                version = 1
                if os.path.isfile(version_path):
                    with open(version_path, 'r', encoding='ascii') as stream:
                        version = int(stream.read().strip(), 16)
                return vendor, product, version
            except (OSError, ValueError):
                return None
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return None


def _get_abs_info(fd, code):
    request = _ioc(2, ord('E'), 0x40 + code, ABS_INFO_STRUCT.size)
    data = bytearray(ABS_INFO_STRUCT.size)
    fcntl.ioctl(fd, request, data, True)
    value, minimum, maximum, _fuzz, _flat, _resolution = ABS_INFO_STRUCT.unpack(data)
    return value, minimum, maximum


def _bit_is_set(bits, code):
    return code in bits


def _input_id(sysfs_path):
    return hashlib.sha256(sysfs_path.encode('utf-8', errors='surrogateescape')).digest()[:16]


def _frame(body):
    return struct.pack('!I', len(body)) + body


class EvdevGamepad:
    is_evdev = True

    def __init__(self, devnode, sysfs_path, name, vendor, product, version, abs_codes):
        self.devnode = devnode
        self.sysfs_path = sysfs_path
        self.name = name
        self.vendor_id = vendor
        self.product_id = product
        self.version = version
        self.descriptor = GAMEPAD_REPORT_DESCRIPTOR
        self.device_id = _input_id(sysfs_path)
        self.report_lengths = {0: 13}
        self.has_report_ids = False
        self.max_report_length = 13
        self.abs_codes = abs_codes
        self.abs_info = {}
        self.abs_values = {}
        self.keys = set()
        self.pending = bytearray()

    def create_message(self):
        body = (bytes((MESSAGE_CREATE,)) + self.device_id +
                struct.pack('!HHHH', len(self.descriptor), self.vendor_id,
                            self.product_id, self.version) + self.descriptor)
        return _frame(body)

    def remove_message(self):
        return _frame(bytes((MESSAGE_REMOVE,)) + self.device_id)

    def report_message(self, report_id, report):
        body = (bytes((MESSAGE_REPORT,)) + self.device_id + bytes((report_id,)) +
                struct.pack('!H', len(report)) + report)
        return _frame(body)

    def zero_report_messages(self):
        return [self.report_message(0, bytes(13))]

    def initialize(self, fd):
        for code in AXIS_CODES:
            if code in self.abs_codes:
                try:
                    value, minimum, maximum = _get_abs_info(fd, code)
                    if maximum > minimum:
                        self.abs_info[code] = (minimum, maximum)
                        self.abs_values[code] = value
                except OSError:
                    pass
        key_bytes = bytearray((0x2FF + 8) // 8)
        try:
            fcntl.ioctl(fd, _ioc(2, ord('E'), 0x18, len(key_bytes)), key_bytes, True)
            self.keys = {code for code in range(0x2FF + 1)
                         if key_bytes[code // 8] & (1 << (code % 8))}
        except OSError:
            pass

    def _normalize_stick(self, code):
        value = self.abs_values.get(code, 0)
        minimum, maximum = self.abs_info.get(code, (-32768, 32767))
        if maximum <= minimum:
            return 0
        scaled = round((value - minimum) * 65535 / (maximum - minimum)) - 32768
        return max(-32768, min(32767, scaled))

    def _normalize_trigger(self, code):
        value = self.abs_values.get(code, 0)
        minimum, maximum = self.abs_info.get(code, (0, 255))
        if maximum <= minimum:
            return 0
        scaled = round((value - minimum) * 255 / (maximum - minimum))
        return max(0, min(255, scaled))

    def _hat(self):
        x = self.abs_values.get(ABS_HAT0X, 0)
        y = self.abs_values.get(ABS_HAT0Y, 0)
        if not x and not y:
            x = int(BTN_DPAD_RIGHT in self.keys) - int(BTN_DPAD_LEFT in self.keys)
            y = int(BTN_DPAD_DOWN in self.keys) - int(BTN_DPAD_UP in self.keys)
        directions = {(0, -1): 0, (1, -1): 1, (1, 0): 2, (1, 1): 3,
                      (0, 1): 4, (-1, 1): 5, (-1, 0): 6, (-1, -1): 7}
        return directions.get((max(-1, min(1, x)), max(-1, min(1, y))), 8)

    def make_report(self):
        buttons = 0
        for code, usage_index in BUTTON_USAGE.items():
            if code in self.keys:
                buttons |= 1 << usage_index
        report = bytearray(13)
        report[0:2] = buttons.to_bytes(2, 'little')
        report[2] = self._hat() & 0x0F
        for index, code in enumerate(STICK_CODES):
            value = self._normalize_stick(code)
            report[3 + index * 2:5 + index * 2] = struct.pack('<h', value)
        report[11] = self._normalize_trigger(ABS_Z)
        report[12] = self._normalize_trigger(ABS_RZ)
        return bytes(report)

    def read_reports(self, fd):
        try:
            data = os.read(fd, EVENT_STRUCT.size * 64)
        except BlockingIOError:
            return []
        if not data:
            return None
        self.pending.extend(data)
        reports = []
        while len(self.pending) >= EVENT_STRUCT.size:
            raw = bytes(self.pending[:EVENT_STRUCT.size])
            del self.pending[:EVENT_STRUCT.size]
            _seconds, _microseconds, event_type, code, value = EVENT_STRUCT.unpack(raw)
            if event_type == EV_KEY:
                if value:
                    self.keys.add(code)
                else:
                    self.keys.discard(code)
            elif event_type == EV_ABS:
                self.abs_values[code] = value
            elif event_type == EV_SYN:
                if code == SYN_DROPPED:
                    self.initialize(fd)
                elif code == SYN_REPORT:
                    reports.append((0, self.make_report()))
        return reports


def find_gamepads(limit=MAX_DEVICES):
    """Find USB evdev nodes with gamepad buttons and X/Y axes."""
    if limit <= 0:
        return []
    base = '/sys/class/input'
    devices = []
    if not os.path.isdir(base):
        return devices

    for entry in sorted(os.listdir(base)):
        if not entry.startswith('event'):
            continue
        devnode = os.path.join('/dev/input', entry)
        sysfs_link = os.path.join(base, entry, 'device')
        if not os.path.exists(sysfs_link) or not os.path.exists(devnode):
            continue
        identity = _usb_identity(sysfs_link)
        if identity is None:
            continue
        fd = None
        try:
            fd = os.open(devnode, os.O_RDONLY | os.O_NONBLOCK)
            event_types = _read_bits(fd, EV_SYN, 0x1F)
            if EV_KEY not in event_types or EV_ABS not in event_types:
                continue
            key_codes = _read_bits(fd, EV_KEY, 0x2FF)
            abs_codes = _read_bits(fd, EV_ABS, 0x3F)
            if BTN_GAMEPAD not in key_codes or ABS_X not in abs_codes or ABS_Y not in abs_codes:
                continue
            sysfs_path = os.path.realpath(sysfs_link)
            name_path = os.path.join(sysfs_path, 'name')
            try:
                with open(name_path, 'r', encoding='utf-8', errors='replace') as stream:
                    name = stream.read().strip()
            except OSError:
                name = entry
            vendor, product, version = identity
            devices.append(EvdevGamepad(devnode, sysfs_path, name, vendor, product,
                                        version, abs_codes))
            if len(devices) >= limit:
                break
        except OSError:
            continue
        finally:
            if fd is not None:
                os.close(fd)
    return devices