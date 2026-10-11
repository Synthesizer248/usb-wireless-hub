using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Authentication;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace UsbVhfReceiver
{
    internal static class NativeMethods
    {
        private const uint FileDeviceUnknown = 0x22;
        private const uint MethodBuffered = 0;
        private const uint FileWriteData = 0x2;

        private static uint CtlCode(uint function) =>
            (FileDeviceUnknown << 16) | (FileWriteData << 14) | (function << 2) | MethodBuffered;

        public static readonly uint IoctlCreateHidDevice = CtlCode(0x801);
        public static readonly uint IoctlRemoveHidDevice = CtlCode(0x802);
        public static readonly uint IoctlSubmitHidReport = CtlCode(0x803);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool DeviceIoControl(
            SafeFileHandle hDevice, uint dwIoControlCode,
            byte[] lpInBuffer, int nInBufferSize,
            IntPtr lpOutBuffer, int nOutBufferSize,
            out int lpBytesReturned, IntPtr lpOverlapped);

        public const uint GenericWrite = 0x40000000;
        public const uint FileShareRead = 0x00000001;
        public const uint FileShareWrite = 0x00000002;
        public const uint OpenExisting = 3;
    }

    internal sealed class HidProfile
    {
        public required byte[] Descriptor { get; init; }
        public required Dictionary<byte, int> InputReportLengths { get; init; }
        public bool HasReportIds { get; init; }
    }

    internal sealed class ActiveDevice
    {
        public required byte[] Id { get; init; }
        public required HidProfile Profile { get; init; }
    }

    internal static class Program
    {
        // This development branch uses a private interface GUID so it cannot
        // accidentally open or replace the working keyboard prototype.
        private static readonly Guid InterfaceGuid = new("8eb5148c-0bdb-4fad-befa-b5d251d0922a");
        private const int MaxDescriptorLength = 4096;
        private const int MaxReportLength = 4096;
        private const int MaxFrameLength = 8192;
        private const int MaxDevices = 32;
        private const byte MessageCreate = 1;
        private const byte MessageReport = 2;
        private const byte MessageRemove = 3;
        private const int CreateHeaderLength = 25; // type + id + descriptor length + VID/PID/version
        private const int ReportHeaderLength = 20; // type + id + report id + report length

        private static int Main(string[] args)
        {
            if (args.Length < 3 || args.Length > 4)
            {
                Console.Error.WriteLine("Usage: UsbVhfReceiver <server.pfx> <pfxPassword|--password-from-environment> <clientCertificateSha256> [port=5000]");
                return 2;
            }

            string certPassword = args[1] == "--password-from-environment"
                ? Environment.GetEnvironmentVariable("USBHUB_RECEIVER_PFX_PASSWORD") ?? string.Empty
                : args[1];
            if (certPassword.Length == 0)
            {
                Console.Error.WriteLine("The receiver PFX password is empty or unavailable.");
                return 2;
            }
            if (!TryParseSha256Fingerprint(args[2], out byte[] clientPin))
            {
                Console.Error.WriteLine("The client certificate fingerprint must be exactly 64 hexadecimal characters (colons are allowed).");
                return 2;
            }
            if (!int.TryParse(args.Length == 4 ? args[3] : "5000", out int port) || port is < 1 or > 65535)
            {
                Console.Error.WriteLine("Port must be between 1 and 65535.");
                return 2;
            }
            if (!File.Exists(args[0]))
            {
                Console.Error.WriteLine($"Certificate file not found: {args[0]}");
                return 2;
            }

            using X509Certificate2 cert = X509CertificateLoader.LoadPkcs12FromFile(args[0], certPassword);
            using SafeFileHandle? deviceHandle = OpenDeviceInterface(InterfaceGuid);
            if (deviceHandle is null || deviceHandle.IsInvalid)
            {
                Console.Error.WriteLine("Failed to open USBHub VHF bridge interface. Ensure the driver is installed and running elevated.");
                return 1;
            }

            var listener = new TcpListener(IPAddress.Any, port);
            listener.Start();
            Console.WriteLine($"Listening for authenticated HID senders on port {port}...");

            while (true)
            {
                try
                {
                    using TcpClient client = listener.AcceptTcpClient();
                    try { ConfigureTcpKeepAlive(client); }
                    catch (Exception ex) { Console.WriteLine($"WARNING: TCP keepalive setup failed: {ex.Message}"); }
                    Console.WriteLine("Incoming connection");
                    using var ssl = new SslStream(client.GetStream(), false, (_, certificate, _, _) =>
                    {
                        if (certificate is null) return false;
                        byte[] actualPin = SHA256.HashData(certificate.GetRawCertData());
                        return CryptographicOperations.FixedTimeEquals(actualPin, clientPin);
                    });

                    try
                    {
                        ssl.AuthenticateAsServer(cert, clientCertificateRequired: true,
                            enabledSslProtocols: SslProtocols.Tls12 | SslProtocols.Tls13,
                            checkCertificateRevocation: false);
                        Console.WriteLine("Mutual TLS established");
                        HandleSession(ssl, deviceHandle);
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"Session ended: {ex.Message}");
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Listener error: {ex.Message}");
                }
            }
        }

        private static void HandleSession(Stream stream, SafeFileHandle driver)
        {
            var active = new Dictionary<string, ActiveDevice>(StringComparer.Ordinal);
            try
            {
                while (true)
                {
                    byte[]? frame = ReadFrame(stream);
                    if (frame is null) break;
                    if (frame.Length == 0) throw new InvalidDataException("Empty protocol frame.");
                    switch (frame[0])
                    {
                        case MessageCreate:
                            AddDevice(frame, driver, active);
                            break;
                        case MessageReport:
                            SubmitInputReport(frame, driver, active);
                            break;
                        case MessageRemove:
                            RemoveDevice(frame, driver, active);
                            break;
                        default:
                            throw new InvalidDataException($"Unknown message type {frame[0]}.");
                    }
                }
            }
            finally
            {
                foreach (ActiveDevice device in active.Values.ToArray())
                    RemoveVirtualDevice(driver, device);
                active.Clear();
            }
        }

        private static void AddDevice(byte[] frame, SafeFileHandle driver, Dictionary<string, ActiveDevice> active)
        {
            if (frame.Length < CreateHeaderLength || active.Count >= MaxDevices)
                throw new InvalidDataException("Invalid create message or device limit exceeded.");
            byte[] id = frame.AsSpan(1, 16).ToArray();
            string key = Convert.ToHexString(id);
            int descriptorLength = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(17, 2));
            ushort vendorId = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(19, 2));
            ushort productId = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(21, 2));
            ushort version = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(23, 2));
            if (descriptorLength is < 1 or > MaxDescriptorLength || frame.Length != CreateHeaderLength + descriptorLength)
                throw new InvalidDataException("Invalid HID descriptor length.");
            if (active.ContainsKey(key)) throw new InvalidDataException("Duplicate HID device identifier.");

            byte[] descriptor = frame.AsSpan(CreateHeaderLength, descriptorLength).ToArray();
            HidProfile profile = ParseReportDescriptor(descriptor);
            var device = new ActiveDevice { Id = id, Profile = profile };

            byte[] ioctl = new byte[24 + descriptor.Length];
            id.CopyTo(ioctl, 0);
            BinaryPrimitives.WriteUInt16LittleEndian(ioctl.AsSpan(16, 2), (ushort)descriptor.Length);
            BinaryPrimitives.WriteUInt16LittleEndian(ioctl.AsSpan(18, 2), vendorId);
            BinaryPrimitives.WriteUInt16LittleEndian(ioctl.AsSpan(20, 2), productId);
            BinaryPrimitives.WriteUInt16LittleEndian(ioctl.AsSpan(22, 2), version);
            descriptor.CopyTo(ioctl, 24);
            if (!CallDriver(driver, NativeMethods.IoctlCreateHidDevice, ioctl))
                throw new IOException($"Driver rejected HID descriptor (Win32 {Marshal.GetLastWin32Error()}).");
            active.Add(key, device);
            Console.WriteLine($"Created virtual HID device {key[..8]} ({vendorId:X4}:{productId:X4}), descriptor {descriptor.Length} bytes");
        }

        private static void SubmitInputReport(byte[] frame, SafeFileHandle driver, Dictionary<string, ActiveDevice> active)
        {
            if (frame.Length < ReportHeaderLength) throw new InvalidDataException("Short report message.");
            byte[] id = frame.AsSpan(1, 16).ToArray();
            string key = Convert.ToHexString(id);
            byte reportId = frame[17];
            int reportLength = BinaryPrimitives.ReadUInt16BigEndian(frame.AsSpan(18, 2));
            if (reportLength is < 1 or > MaxReportLength || frame.Length != ReportHeaderLength + reportLength)
                throw new InvalidDataException("Invalid HID input report length.");
            if (!active.TryGetValue(key, out ActiveDevice? device))
                throw new InvalidDataException("Report received for an unknown HID device.");
            if (!device.Profile.InputReportLengths.TryGetValue(reportId, out int expectedLength) || expectedLength != reportLength)
                throw new InvalidDataException("Report ID or length does not match the device descriptor.");

            byte[] report = frame.AsSpan(ReportHeaderLength, reportLength).ToArray();
            if (reportId != 0 && report[0] != reportId)
                throw new InvalidDataException("HID report ID prefix does not match the frame header.");
            byte[] ioctl = new byte[20 + report.Length];
            id.CopyTo(ioctl, 0);
            BinaryPrimitives.WriteUInt16LittleEndian(ioctl.AsSpan(16, 2), (ushort)report.Length);
            ioctl[18] = reportId;
            ioctl[19] = 0;
            report.CopyTo(ioctl, 20);
            if (!CallDriver(driver, NativeMethods.IoctlSubmitHidReport, ioctl))
                Console.WriteLine($"VHF rejected a report for {key[..8]} (Win32 {Marshal.GetLastWin32Error()})");
        }

        private static void RemoveDevice(byte[] frame, SafeFileHandle driver, Dictionary<string, ActiveDevice> active)
        {
            if (frame.Length != 17) throw new InvalidDataException("Invalid remove message length.");
            string key = Convert.ToHexString(frame.AsSpan(1, 16));
            if (!active.Remove(key, out ActiveDevice? device)) return;
            RemoveVirtualDevice(driver, device);
            Console.WriteLine($"Removed virtual HID device {key[..8]}");
        }

        private static void RemoveVirtualDevice(SafeFileHandle driver, ActiveDevice device)
        {
            foreach ((byte reportId, int reportLength) in device.Profile.InputReportLengths)
            {
                byte[] zero = new byte[20 + reportLength];
                device.Id.CopyTo(zero, 0);
                BinaryPrimitives.WriteUInt16LittleEndian(zero.AsSpan(16, 2), (ushort)reportLength);
                zero[18] = reportId;
                if (reportId != 0) zero[20] = reportId;
                CallDriver(driver, NativeMethods.IoctlSubmitHidReport, zero);
            }
            byte[] remove = new byte[16];
            device.Id.CopyTo(remove, 0);
            CallDriver(driver, NativeMethods.IoctlRemoveHidDevice, remove);
        }

        private static bool CallDriver(SafeFileHandle driver, uint ioctl, byte[] input)
        {
            return NativeMethods.DeviceIoControl(driver, ioctl, input, input.Length,
                IntPtr.Zero, 0, out _, IntPtr.Zero);
        }

        private static byte[]? ReadFrame(Stream stream)
        {
            byte[] prefix = new byte[4];
            if (!ReadExactly(stream, prefix, allowCleanEof: true)) return null;
            int length = BinaryPrimitives.ReadInt32BigEndian(prefix);
            if (length is < 1 or > MaxFrameLength) throw new InvalidDataException("Frame length is outside the allowed range.");
            byte[] frame = new byte[length];
            ReadExactly(stream, frame, allowCleanEof: false);
            return frame;
        }

        private static bool ReadExactly(Stream stream, byte[] buffer, bool allowCleanEof)
        {
            int offset = 0;
            while (offset < buffer.Length)
            {
                int read = stream.Read(buffer, offset, buffer.Length - offset);
                if (read == 0)
                {
                    if (offset == 0 && allowCleanEof) return false;
                    throw new EndOfStreamException("Peer closed in the middle of a HID protocol message.");
                }
                offset += read;
            }
            return true;
        }

        private static HidProfile ParseReportDescriptor(byte[] descriptor)
        {
            var bitsById = new Dictionary<byte, int>();
            var globalStack = new Stack<(uint ReportSize, uint ReportCount, byte ReportId)>();
            uint reportSize = 0, reportCount = 0;
            byte reportId = 0;
            bool hasReportIds = false;
            int collectionDepth = 0;

            for (int offset = 0; offset < descriptor.Length;)
            {
                byte prefix = descriptor[offset++];
                if (prefix == 0xFE)
                {
                    if (offset + 2 > descriptor.Length) throw new InvalidDataException("Truncated HID long item.");
                    int longLength = descriptor[offset++];
                    offset++;
                    if (offset + longLength > descriptor.Length) throw new InvalidDataException("HID long item exceeds descriptor.");
                    offset += longLength;
                    continue;
                }

                int sizeCode = prefix & 0x03;
                int itemSize = sizeCode == 3 ? 4 : sizeCode;
                if (offset + itemSize > descriptor.Length) throw new InvalidDataException("Truncated HID item.");
                uint value = 0;
                for (int i = 0; i < itemSize; i++) value |= (uint)descriptor[offset + i] << (8 * i);
                offset += itemSize;
                int itemType = (prefix >> 2) & 0x03;
                int tag = (prefix >> 4) & 0x0F;

                if (itemType == 1)
                {
                    switch (tag)
                    {
                        case 7: reportSize = value; break;
                        case 8:
                            if (value is 0 or > 255) throw new InvalidDataException("Invalid HID report ID.");
                            reportId = (byte)value;
                            hasReportIds = true;
                            break;
                        case 9: reportCount = value; break;
                        case 10: globalStack.Push((reportSize, reportCount, reportId)); break;
                        case 11:
                            if (globalStack.Count == 0) throw new InvalidDataException("HID global POP without PUSH.");
                            (reportSize, reportCount, reportId) = globalStack.Pop();
                            break;
                    }
                }
                else if (itemType == 0)
                {
                    if (tag == 10) collectionDepth++;
                    else if (tag == 12 && --collectionDepth < 0) throw new InvalidDataException("HID collection closes without an open collection.");
                    else if (tag == 8)
                    {
                        if (reportSize == 0 || reportCount == 0 || reportSize > MaxReportLength * 8 || reportCount > MaxReportLength * 8)
                            throw new InvalidDataException("HID input report has invalid size/count.");
                        ulong bits = (ulong)reportSize * reportCount;
                        ulong combined = (ulong)bitsById.GetValueOrDefault(reportId) + bits;
                        if (combined > (ulong)MaxReportLength * 8) throw new InvalidDataException("HID input report exceeds the supported size.");
                        bitsById[reportId] = checked((int)combined);
                    }
                }
            }

            if (collectionDepth != 0 || globalStack.Count != 0 || bitsById.Count == 0)
                throw new InvalidDataException("HID descriptor is incomplete or has no input reports.");
            if (hasReportIds && bitsById.ContainsKey(0))
                throw new InvalidDataException("Descriptor mixes numbered and unnumbered input reports.");

            var lengths = new Dictionary<byte, int>();
            foreach ((byte id, int bits) in bitsById)
            {
                int length = (bits + 7) / 8 + (id == 0 ? 0 : 1);
                if (length < 1 || length > MaxReportLength) throw new InvalidDataException("Computed HID report length is invalid.");
                lengths.Add(id, length);
            }
            return new HidProfile { Descriptor = descriptor, InputReportLengths = lengths, HasReportIds = hasReportIds };
        }

        private static void ConfigureTcpKeepAlive(TcpClient client)
        {
            if (!OperatingSystem.IsWindows()) return;
            client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            byte[] values = new byte[12];
            BitConverter.GetBytes((uint)1).CopyTo(values, 0);
            BitConverter.GetBytes((uint)15000).CopyTo(values, 4);
            BitConverter.GetBytes((uint)5000).CopyTo(values, 8);
            client.Client.IOControl(IOControlCode.KeepAliveValues, values, null);
        }

        // Minimal SetupAPI enumeration for the single bridge root-device interface.
        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr HWND, uint Flags);

        [StructLayout(LayoutKind.Sequential)]
        private struct SpDeviceInterfaceData
        {
            public int cbSize;
            public Guid InterfaceClassGuid;
            public int Flags;
            public IntPtr Reserved;
        }

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, uint MemberIndex, ref SpDeviceInterfaceData DeviceInterfaceData);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet, ref SpDeviceInterfaceData DeviceInterfaceData, IntPtr DeviceInterfaceDetailData, int DeviceInterfaceDetailDataSize, out int RequiredSize, IntPtr DeviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

        private static SafeFileHandle? OpenDeviceInterface(Guid guid)
        {
            const uint DigcfPresent = 0x00000002, DigcfDeviceInterface = 0x00000010;
            const int ErrorInsufficientBuffer = 122, ErrorNoMoreItems = 259;
            int detailDataCbSize = IntPtr.Size == 8 ? 8 : 6;
            IntPtr info = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
            if (info == IntPtr.Zero || info == new IntPtr(-1)) return null;
            try
            {
                for (uint index = 0; ; index++)
                {
                    var data = new SpDeviceInterfaceData { cbSize = Marshal.SizeOf<SpDeviceInterfaceData>() };
                    if (!SetupDiEnumDeviceInterfaces(info, IntPtr.Zero, ref guid, index, ref data))
                    {
                        if (Marshal.GetLastWin32Error() != ErrorNoMoreItems)
                            Console.Error.WriteLine($"SetupDiEnumDeviceInterfaces failed: {Marshal.GetLastWin32Error()}");
                        break;
                    }
                    _ = SetupDiGetDeviceInterfaceDetail(info, ref data, IntPtr.Zero, 0, out int required, IntPtr.Zero);
                    if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer || required < detailDataCbSize) continue;
                    IntPtr buffer = Marshal.AllocHGlobal(required);
                    try
                    {
                        Marshal.WriteInt32(buffer, detailDataCbSize);
                        if (!SetupDiGetDeviceInterfaceDetail(info, ref data, buffer, required, out _, IntPtr.Zero)) continue;
                        string? path = Marshal.PtrToStringUni(IntPtr.Add(buffer, 4));
                        if (string.IsNullOrEmpty(path)) continue;
                        SafeFileHandle handle = NativeMethods.CreateFile(path, NativeMethods.GenericWrite,
                            NativeMethods.FileShareRead | NativeMethods.FileShareWrite, IntPtr.Zero,
                            NativeMethods.OpenExisting, 0, IntPtr.Zero);
                        if (!handle.IsInvalid)
                        {
                            Console.WriteLine($"Opened driver interface: {path}");
                            return handle;
                        }
                    }
                    finally { Marshal.FreeHGlobal(buffer); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(info); }
            return null;
        }

        private static bool TryParseSha256Fingerprint(string value, out byte[] fingerprint)
        {
            string normalized = value.Replace(":", string.Empty).Replace(" ", string.Empty);
            try
            {
                if (normalized.Length == 64)
                {
                    fingerprint = Convert.FromHexString(normalized);
                    return true;
                }
            }
            catch (FormatException) { }
            fingerprint = Array.Empty<byte>();
            return false;
        }
    }
}
