#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# The resolver has disappeared from this PC between launches. Keep a compressed,
# verified copy in this launcher so the shortcut can restore it on every start.
$compressedResolver =     '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'
$expectedResolverHash = '443B795DD65977814B276DDE1A3F369909BA16B9472D529563FE046F02CAB4FC'
$bytes = [Convert]::FromBase64String($compressedResolver)
$inputStream = [IO.MemoryStream]::new($bytes)
$gzipStream = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
$reader = [IO.StreamReader]::new($gzipStream, [Text.Encoding]::UTF8)
$resolverSource = $reader.ReadToEnd()
$reader.Dispose()
$inputStream.Dispose()
$resolverBytes = [Text.Encoding]::UTF8.GetBytes($resolverSource)
$sha = [Security.Cryptography.SHA256]::Create()
try { $actualResolverHash = [BitConverter]::ToString($sha.ComputeHash($resolverBytes)).Replace('-', '') } finally { $sha.Dispose() }
if ($actualResolverHash -ne $expectedResolverHash) {
    throw 'The built-in USBHub address resolver failed its integrity check.'
}

$clientRoot = Join-Path $env:LOCALAPPDATA 'UsbHub\client'
$usbIpDirectory = Join-Path $clientRoot 'windows\UsbIp'
$resolverPath = Join-Path $usbIpDirectory 'Resolve-UsbHubPiAddress.ps1'
$showPath = Join-Path $usbIpDirectory 'Show-UsbHubDeviceCenter.ps1'
New-Item -ItemType Directory -Path $usbIpDirectory -Force | Out-Null
$mustRestore = -not [IO.File]::Exists($resolverPath)
if (-not $mustRestore) {
    try { $mustRestore = (Get-FileHash -LiteralPath $resolverPath -Algorithm SHA256).Hash -ne $expectedResolverHash }
    catch { $mustRestore = $true }
}
if ($mustRestore) {
    $stagedPath = Join-Path $usbIpDirectory ('Resolve-UsbHubPiAddress.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllBytes($stagedPath, $resolverBytes)
    Move-Item -LiteralPath $stagedPath -Destination $resolverPath -Force
}
if (-not [IO.File]::Exists($resolverPath)) {
    throw "Could not restore the USBHub address resolver at $resolverPath"
}
if (-not [IO.File]::Exists($showPath)) {
    [void][Windows.Forms.MessageBox]::Show(
        "USBHub Device Center is missing:`r`n$showPath`r`nRun Install-UsbHubClient.ps1 to repair the client.",
        'USBHub setup needed', 'OK', 'Warning')
    exit 1
}
& $showPath
