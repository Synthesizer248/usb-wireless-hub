<#
.SYNOPSIS
    Installs the signed USB/IP client on a Windows PC and saves its USBHub target.
.DESCRIPTION
    Downloads the pinned upstream USBip installer for the current architecture,
    checks its SHA-256 digest, verifies its Authenticode signature, and launches
    the normal interactive installer through UAC. The installer can restart USB
    hubs, so save work and disconnect critical USB activity first.
#>
[CmdletBinding()]
param(
    [string] $PiAddress,
    [string] $PiUser = 'admin'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PiAddress)) {
    $PiAddress = Read-Host 'Enter the USBHub Raspberry Pi IP address or host name'
}
if ([string]::IsNullOrWhiteSpace($PiAddress) -or $PiAddress -match '[\s/@]') {
    throw 'Enter a valid Pi IP address or host name.'
}
if ([string]::IsNullOrWhiteSpace($PiUser) -or $PiUser -match '[\s/@]') {
    throw 'Enter a valid SSH user name.'
}

$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$version = '0.9.8.1'
$releaseBase = "https://github.com/vadimgrn/usbip-win2/releases/download/v.$version"
switch ($architecture) {
    'X64' {
        $asset = "USBip-$version-x64.exe"
        $expectedSha256 = '38CAD6D4432B52D5BB9409D9AD03B72FDFFC4ADA4CD3A48FBECA1A2752A8518A'
    }
    'Arm64' {
        $asset = "USBip-$version-arm64.exe"
        $expectedSha256 = 'CAB7FF97F79275EEB5C5B8BB2EB3111FF6B6C4EEAD07D9BEC9BE5BD1E3A35800'
    }
    default {
        throw "USBip for Windows does not provide a supported installer for $architecture. Supported architectures are x64 and ARM64."
    }
}

$configDir = Join-Path $env:LOCALAPPDATA 'UsbHub'
$downloadDir = Join-Path $configDir 'downloads'
$configPath = Join-Path $configDir 'client.json'
$installerPath = Join-Path $downloadDir $asset
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

$usbipExe = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
if (-not (Test-Path -LiteralPath $usbipExe -PathType Leaf)) {
    Write-Warning 'The USBip installer may briefly restart USB hubs. Save open files and pause active USB transfers before continuing.'
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ne $expectedSha256) {
        Invoke-WebRequest -Uri "$releaseBase/$asset" -OutFile $installerPath
    }

    $actualSha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    if ($actualSha256 -ne $expectedSha256) {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        throw "USBip installer checksum mismatch. Expected $expectedSha256; got $actualSha256."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    if ($signature.Status -ne 'Valid') {
        throw "USBip installer signature check failed: $($signature.Status). The installer was downloaded but will not be started."
    }

    Write-Host "Verified USBip $version ($architecture). The official setup wizard will ask for administrator approval."
    $installer = Start-Process -FilePath $installerPath -Verb RunAs -Wait -PassThru
    if ($installer.ExitCode -ne 0) {
        throw "USBip setup exited with code $($installer.ExitCode). Re-run this script after resolving the installer issue."
    }
}

if (-not (Test-Path -LiteralPath $usbipExe -PathType Leaf)) {
    $usbipExe = Join-Path ${env:ProgramFiles(x86)} 'USBip\usbip.exe'
}
if (-not (Test-Path -LiteralPath $usbipExe -PathType Leaf)) {
    throw 'The USBip installer completed, but usbip.exe was not found under Program Files.'
}

$config = [ordered]@{
    PiAddress = $PiAddress
    PiUser    = $PiUser
}
$tempConfig = "$configPath.tmp"
$config | ConvertTo-Json | Set-Content -LiteralPath $tempConfig -Encoding UTF8
Move-Item -LiteralPath $tempConfig -Destination $configPath -Force

Write-Host "USBip client is ready at: $usbipExe"
Write-Host "Saved this hub as $PiUser@$PiAddress for the current Windows account."
Write-Host 'Next: open a PowerShell window in this project folder and run:'
Write-Host '  .\windows\UsbIp\Invoke-UsbHubUsbIp.ps1 -Action Tunnel'
Write-Host 'Then in another window run Inventory and Connect for the device you want to claim.'
