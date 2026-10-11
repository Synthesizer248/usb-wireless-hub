#!/usr/bin/env python3
"""Descriptor-driven USB HID to USBHub VHF bridge sender.

Uses only the Python standard library. The network protocol is documented in
README.md; no third-party HID or USB/IP runtime is required.
"""

import hashlib
import os
import re
import select
import socket
import ssl
import struct
import sys
import time

from evdev_gamepad import find_gamepads

MAX_DESCRIPTOR_LENGTH = 4096
MAX_REPORT_LENGTH = 4096
MAX_FRAME_LENGTH = 8192
MAX_DEVICES = 32

MESSAGE_CREATE = 1
MESSAGE_REPORT = 2
MESSAGE_REMOVE = 3


class HidDevice:
    def __init__(self, devnode, sysfs_path, descriptor, vendor_id, product_id, version, report_lengths, has_report_ids):
        self.devnode = devnode
        self.sysfs_path = sysfs_path
        self.descriptor = descriptor
        self.vendor_id = vendor_id
        self.product_id = product_id
        self.version = version
        self.report_lengths = report_lengths
        self.has_report_ids = has_report_ids
        self.device_id = hashlib.sha256(sysfs_path.encode('utf-8', errors='surrogateescape')).digest()[:16]

    @property
    def max_report_length(self):
        return max(self.report_lengths.values())

    def create_message(self):
        body = (bytes((MESSAGE_CREATE,)) + self.device_id +
                struct.pack('!HHHH', len(self.descriptor), self.vendor_id,
                            self.product_id, self.version) + self.descriptor)
        return encode_frame(body)

    def remove_message(self):
        return encode_frame(bytes((MESSAGE_REMOVE,)) + self.device_id)

    def report_message(self, report_id, report):
        body = (bytes((MESSAGE_REPORT,)) + self.device_id + bytes((report_id,)) +
                struct.pack('!H', len(report)) + report)
        return encode_frame(body)

    def zero_report_messages(self):
        frames = []
        for report_id, length in self.report_lengths.items():
            report = bytearray(length)
            if report_id:
                report[0] = report_id
            frames.append(self.report_message(report_id, report))
        return frames


def encode_frame(body):
    if not body or len(body) > MAX_FRAME_LENGTH:
        raise ValueError('Protocol frame length is outside the supported range')
    return struct.pack('!I', len(body)) + body


def find_report_descriptor(device_path):
    path = os.path.realpath(device_path)
    for _ in range(12):
        descriptor_path = os.path.join(path, 'report_descriptor')
        if os.path.isfile(descriptor_path):
            try:
                with open(descriptor_path, 'rb') as stream:
                    data = stream.read(MAX_DESCRIPTOR_LENGTH + 1)
                return data if 0 < len(data) <= MAX_DESCRIPTOR_LENGTH else None
            except OSError:
                return None
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return None


def find_usb_identity(device_path):
    path = os.path.realpath(device_path)
    for _ in range(12):
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


def parse_report_descriptor(descriptor):
    if not descriptor or len(descriptor) > MAX_DESCRIPTOR_LENGTH:
        raise ValueError('Missing or oversized report descriptor')

    report_size = 0
    report_count = 0
    report_id = 0
    has_report_ids = False
    global_stack = []
    collection_depth = 0
    bits_by_id = {}
    offset = 0

    while offset < len(descriptor):
        prefix = descriptor[offset]
        offset += 1
        if prefix == 0xFE:
            if offset + 2 > len(descriptor):
                raise ValueError('Truncated HID long item')
            long_length = descriptor[offset]
            offset += 2  # length and long-item tag
            if offset + long_length > len(descriptor):
                raise ValueError('HID long item exceeds descriptor')
            offset += long_length
            continue

        size_code = prefix & 0x03
        item_size = 4 if size_code == 3 else size_code
        if offset + item_size > len(descriptor):
            raise ValueError('Truncated HID item')
        value = int.from_bytes(descriptor[offset:offset + item_size], 'little') if item_size else 0
        offset += item_size
        item_type = (prefix >> 2) & 0x03
        tag = (prefix >> 4) & 0x0F

        if item_type == 1:
            if tag == 7:
                report_size = value
            elif tag == 8:
                if value < 1 or value > 255:
                    raise ValueError('Invalid HID report ID')
                report_id = value
                has_report_ids = True
            elif tag == 9:
                report_count = value
            elif tag == 10:
                global_stack.append((report_size, report_count, report_id))
            elif tag == 11:
                if not global_stack:
                    raise ValueError('HID global POP without PUSH')
                report_size, report_count, report_id = global_stack.pop()
        elif item_type == 0:
            if tag == 10:
                collection_depth += 1
            elif tag == 12:
                collection_depth -= 1
                if collection_depth < 0:
                    raise ValueError('HID collection closes without an open collection')
            elif tag == 8:  # Input main item
                if not report_size or not report_count:
                    raise ValueError('HID input report has invalid size/count')
                bits = report_size * report_count
                combined = bits_by_id.get(report_id, 0) + bits
                if combined > MAX_REPORT_LENGTH * 8:
                    raise ValueError('HID input report exceeds supported size')
                bits_by_id[report_id] = combined

    if collection_depth != 0 or global_stack or not bits_by_id:
        raise ValueError('HID descriptor is incomplete or has no input reports')
    if has_report_ids and 0 in bits_by_id:
        raise ValueError('Descriptor mixes numbered and unnumbered input reports')

    lengths = {}
    for current_id, bit_count in bits_by_id.items():
        length = (bit_count + 7) // 8 + (1 if current_id else 0)
        if length < 1 or length > MAX_REPORT_LENGTH:
            raise ValueError('Computed HID report length is invalid')
        lengths[current_id] = length
    return lengths, has_report_ids


def find_hid_devices():
    base = '/sys/class/hidraw'
    devices = []
    if not os.path.isdir(base):
        return devices

    for entry in sorted(os.listdir(base)):
        devnode = os.path.join('/dev', entry)
        sysfs_link = os.path.join(base, entry, 'device')
        if not os.path.exists(sysfs_link) or not os.path.exists(devnode):
            continue
        sysfs_path = os.path.realpath(sysfs_link)
        descriptor = find_report_descriptor(sysfs_link)
        identity = find_usb_identity(sysfs_link)
        if descriptor is None or identity is None:
            continue
        try:
            report_lengths, has_ids = parse_report_descriptor(descriptor)
        except ValueError as exc:
            print(f'Skipping {devnode}: {exc}', flush=True)
            continue
        vendor, product, version = identity
        devices.append(HidDevice(devnode, sysfs_path, descriptor, vendor, product,
                                 version, report_lengths, has_ids))
        if len(devices) >= MAX_DEVICES:
            break
    return devices


def find_all_devices():
    devices = find_hid_devices()
    devices.extend(find_gamepads(limit=max(0, MAX_DEVICES - len(devices))))
    return devices


def device_signature(devices):
    return tuple((device.sysfs_path, device.device_id, device.descriptor,
                  device.vendor_id, device.product_id, device.version)
                 for device in devices)


def normalize_fingerprint(value):
    normalized = value.replace(':', '').strip()
    if len(normalized) != 64 or not re.fullmatch(r'[0-9a-fA-F]{64}', normalized):
        raise ValueError('Server certificate fingerprint must be exactly 64 hexadecimal characters (colons are allowed)')
    return normalized.upper()


def connect_tls(host, port, pinned_fingerprint, client_cert, client_key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.load_cert_chain(certfile=client_cert, keyfile=client_key)
    raw = socket.create_connection((host, port), timeout=10)
    try:
        tls_socket = context.wrap_socket(raw)
    except Exception:
        raw.close()
        raise
    actual = hashlib.sha256(tls_socket.getpeercert(binary_form=True)).hexdigest().upper()
    if actual != pinned_fingerprint:
        tls_socket.close()
        raise ssl.SSLError(f'Server certificate fingerprint mismatch: got {actual}, expected {pinned_fingerprint}')
    return tls_socket


def send_cleanup(tls_socket, devices):
    if tls_socket is None:
        return
    for device in devices:
        for frame in device.zero_report_messages():
            try:
                tls_socket.sendall(frame)
            except OSError:
                return
        try:
            tls_socket.sendall(device.remove_message())
        except OSError:
            return


def read_device_reports(device, fd):
    if getattr(device, 'is_evdev', False):
        return device.read_reports(fd)
    try:
        report = os.read(fd, device.max_report_length)
    except BlockingIOError:
        return []
    if not report:
        return None
    report_id = report[0] if device.has_report_ids else 0
    return [(report_id, report)]


def stream_session(host, port, pinned, client_cert, client_key, devices):
    tls_socket = connect_tls(host, port, pinned, client_cert, client_key)
    descriptors = {}
    poller = select.poll()
    try:
        tls_socket.settimeout(5)
        for device in devices:
            fd = os.open(device.devnode, os.O_RDONLY | os.O_NONBLOCK)
            descriptors[fd] = device
            if getattr(device, 'is_evdev', False):
                device.initialize(fd)
            poller.register(fd, select.POLLIN | select.POLLERR | select.POLLHUP)
        for device in devices:
            tls_socket.sendall(device.create_message())
            if getattr(device, 'is_evdev', False):
                tls_socket.sendall(device.report_message(0, device.make_report()))
                print(f'Forwarding gamepad {device.vendor_id:04x}:{device.product_id:04x} {device.name} from {device.devnode}', flush=True)
            else:
                print(f'Forwarding HID {device.vendor_id:04x}:{device.product_id:04x} from {device.devnode}', flush=True)
        print('Connected and TLS established; forwarding HID reports', flush=True)

        last_scan = time.monotonic()
        current_signature = device_signature(devices)
        while True:
            events = poller.poll(500)
            for fd, event in events:
                device = descriptors.get(fd)
                if device is None:
                    continue
                if event & (select.POLLERR | select.POLLHUP | getattr(select, 'POLLNVAL', 0)):
                    return
                try:
                    reports = read_device_reports(device, fd)
                except OSError as exc:
                    print(f'Read failed for {device.devnode}: {exc}', flush=True)
                    return
                if reports is None:
                    return
                for report_id, report in reports:
                    expected = device.report_lengths.get(report_id)
                    if expected is None or len(report) != expected:
                        print(f'Skipping malformed report from {device.devnode}: ID={report_id}, bytes={len(report)}', flush=True)
                        continue
                    tls_socket.sendall(device.report_message(report_id, report))

            if time.monotonic() - last_scan >= 2:
                last_scan = time.monotonic()
                if device_signature(find_all_devices()) != current_signature:
                    print('HID device list changed; reconnecting to refresh virtual devices', flush=True)
                    return
    finally:
        send_cleanup(tls_socket, devices)
        for fd in descriptors:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            tls_socket.close()
        except OSError:
            pass


def main():
    if len(sys.argv) != 6:
        print('Usage: sender.py <host> <port> <serverCertificateSha256> <clientCertificate.pem> <clientPrivateKey.pem>')
        return 2
    host = sys.argv[1]
    try:
        port = int(sys.argv[2])
        if port < 1 or port > 65535:
            raise ValueError('Port must be 1..65535')
        pinned = normalize_fingerprint(sys.argv[3])
    except ValueError as exc:
        print(exc)
        return 2
    client_cert, client_key = sys.argv[4], sys.argv[5]

    backoff = 1
    while True:
        try:
            devices = find_all_devices()
            if not devices:
                print('No supported USB HID interfaces found; checking again in 2s', flush=True)
                time.sleep(2)
                continue
            print(f'Found {len(devices)} HID interface(s)', flush=True)
            stream_session(host, port, pinned, client_cert, client_key, devices)
            backoff = 1
            time.sleep(1)
        except KeyboardInterrupt:
            print('Exiting', flush=True)
            return 0
        except Exception as exc:
            print(f'Bridge session failed: {exc}; retrying in {backoff}s', flush=True)
            time.sleep(backoff)
            backoff = min(30, backoff * 2)


if __name__ == '__main__':
    sys.exit(main())
