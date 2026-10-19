# Shared resolver for the Windows client. Windows OpenSSH does not consistently
# resolve .local names through the system resolver, so query mDNS directly.
if ($null -eq ('UsbHubMdns' -as [type])) {
    $source = @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

public static class UsbHubMdns
{
    private static readonly IPAddress MulticastAddress = IPAddress.Parse("224.0.0.251");

    public static string ResolveA(string hostName, int timeoutMilliseconds)
    {
        string canonicalName = hostName.TrimEnd('.');
        byte[] query = BuildQuery(canonicalName);
        foreach (NetworkInterface network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up || network.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                continue;

            foreach (UnicastIPAddressInformation unicast in network.GetIPProperties().UnicastAddresses)
            {
                IPAddress localAddress = unicast.Address;
                if (localAddress.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(localAddress) || localAddress.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                    continue;

                try
                {
                    using (UdpClient client = new UdpClient(AddressFamily.InterNetwork))
                    {
                        client.Client.Bind(new IPEndPoint(localAddress, 0));
                        client.Ttl = 255;
                        client.Client.ReceiveTimeout = Math.Max(200, timeoutMilliseconds);
                        client.Send(query, query.Length, new IPEndPoint(MulticastAddress, 5353));

                        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);
                        while (DateTime.UtcNow < deadline)
                        {
                            IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                            byte[] response = client.Receive(ref remote);
                            IPAddress resolved = ReadAResponse(response, canonicalName);
                            if (resolved != null)
                                return resolved.ToString();
                        }
                    }
                }
                catch (SocketException)
                {
                    // Try the next active interface. A quiet mDNS interface is
                    // normal on laptops with Ethernet, Wi-Fi, VPN, and Hyper-V.
                }
                catch (ObjectDisposedException)
                {
                    // The socket is scoped to this interface attempt.
                }
            }
        }
        return null;
    }

    private static byte[] BuildQuery(string hostName)
    {
        List<byte> bytes = new List<byte>(64);
        bytes.AddRange(new byte[] { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
        foreach (string label in hostName.Split('.'))
        {
            byte[] encoded = Encoding.ASCII.GetBytes(label);
            if (encoded.Length == 0 || encoded.Length > 63)
                throw new ArgumentException("Invalid mDNS hostname label.", "hostName");
            bytes.Add((byte)encoded.Length);
            bytes.AddRange(encoded);
        }
        bytes.Add(0);
        bytes.AddRange(new byte[] { 0, 1, 128, 1 }); // A, class IN, unicast response requested
        return bytes.ToArray();
    }

    private static ushort ReadUInt16(byte[] data, int offset)
    {
        return (ushort)((data[offset] << 8) | data[offset + 1]);
    }

    private static string ReadName(byte[] data, ref int offset)
    {
        List<string> labels = new List<string>();
        int position = offset;
        int continuation = -1;
        int jumps = 0;
        while (position < data.Length)
        {
            byte length = data[position++];
            if (length == 0)
            {
                offset = continuation >= 0 ? continuation : position;
                return String.Join(".", labels.ToArray());
            }
            if ((length & 0xC0) == 0xC0)
            {
                if (position >= data.Length || ++jumps > 32)
                    return null;
                int pointer = ((length & 0x3F) << 8) | data[position++];
                if (continuation < 0)
                    continuation = position;
                position = pointer;
                continue;
            }
            if ((length & 0xC0) != 0 || position + length > data.Length)
                return null;
            labels.Add(Encoding.ASCII.GetString(data, position, length));
            position += length;
        }
        return null;
    }

    private static IPAddress ReadAResponse(byte[] data, string requestedName)
    {
        if (data == null || data.Length < 12 || (ReadUInt16(data, 2) & 0x8000) == 0)
            return null;

        int questions = ReadUInt16(data, 4);
        int answerCount = ReadUInt16(data, 6);
        int authorityCount = ReadUInt16(data, 8);
        int additionalCount = ReadUInt16(data, 10);
        int offset = 12;
        try
        {
            for (int i = 0; i < questions; i++)
            {
                if (ReadName(data, ref offset) == null || offset + 4 > data.Length)
                    return null;
                offset += 4;
            }

            HashSet<string> acceptedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            acceptedNames.Add(requestedName);
            List<KeyValuePair<string, IPAddress>> addresses = new List<KeyValuePair<string, IPAddress>>();
            int records = answerCount + authorityCount + additionalCount;
            for (int i = 0; i < records; i++)
            {
                string owner = ReadName(data, ref offset);
                if (owner == null || offset + 10 > data.Length)
                    return null;
                ushort type = ReadUInt16(data, offset);
                ushort recordClass = (ushort)(ReadUInt16(data, offset + 2) & 0x7FFF);
                int length = ReadUInt16(data, offset + 8);
                offset += 10;
                if (offset + length > data.Length)
                    return null;

                if (recordClass == 1 && type == 1 && length == 4)
                    addresses.Add(new KeyValuePair<string, IPAddress>(owner, new IPAddress(new byte[] { data[offset], data[offset + 1], data[offset + 2], data[offset + 3] })));
                else if (recordClass == 1 && type == 5)
                {
                    int nameOffset = offset;
                    string alias = ReadName(data, ref nameOffset);
                    if (String.Equals(owner, requestedName, StringComparison.OrdinalIgnoreCase) && alias != null)
                        acceptedNames.Add(alias);
                }
                offset += length;
            }

            foreach (KeyValuePair<string, IPAddress> address in addresses)
                if (acceptedNames.Contains(address.Key))
                    return address.Value;
        }
        catch (ArgumentOutOfRangeException) { }
        catch (IndexOutOfRangeException) { }
        return null;
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
}

function Resolve-UsbHubPiAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Address,
        [ValidateRange(200, 5000)][int] $TimeoutMilliseconds = 900
    )

    $hostName = $Address.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($hostName)) { throw 'USBHub Pi address is empty.' }
    $parsedAddress = $null
    if ([Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)) { return $parsedAddress.ToString() }

    if ($hostName.EndsWith('.local', [StringComparison]::OrdinalIgnoreCase)) {
        $resolvedAddress = [UsbHubMdns]::ResolveA($hostName, $TimeoutMilliseconds)
        if (-not [string]::IsNullOrWhiteSpace($resolvedAddress)) { return $resolvedAddress }
        throw "Could not resolve $hostName over mDNS. Put this PC and the Pi on the same LAN and allow mDNS multicast (UDP 5353)."
    }

    try {
        $resolved = [Net.Dns]::GetHostAddresses($hostName) | Where-Object AddressFamily -eq InterNetwork | Select-Object -First 1
        if ($resolved) { return $resolved.IPAddressToString }
    }
    catch { }
    throw "Could not resolve USBHub Pi address $hostName."
}
