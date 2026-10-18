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
    [string] $PiUser = 'admin',
    [ValidateSet('zero-copy', 'low-latency')]
    [string] $ReceiveMode,
    [switch] $SkipPiSetup
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
$requiredVersion = [version]$version
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

$previousConfig = [pscustomobject]@{}
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $loadedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($null -ne $loadedConfig) {
            if ($loadedConfig -isnot [pscustomobject]) {
                throw 'The settings file must contain a JSON object.'
            }
            $previousConfig = $loadedConfig
        }
    }
    catch { throw "Could not read existing USBHub client settings at $configPath - $($_.Exception.Message)" }
}
if ([string]::IsNullOrWhiteSpace($ReceiveMode)) { $ReceiveMode = [string]$previousConfig.ReceiveMode }
if ([string]::IsNullOrWhiteSpace($ReceiveMode)) { $ReceiveMode = 'zero-copy' }

$usbipExe = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
$x86UsbipExe = Join-Path ${env:ProgramFiles(x86)} 'USBip\usbip.exe'
if (-not (Test-Path -LiteralPath $usbipExe -PathType Leaf)) { $usbipExe = $x86UsbipExe }
$installedVersion = $null
if (Test-Path -LiteralPath $usbipExe -PathType Leaf) {
    try { $installedVersion = [version](Get-Item -LiteralPath $usbipExe).VersionInfo.ProductVersion } catch { $installedVersion = $null }
}

if (-not $installedVersion -or $installedVersion -lt $requiredVersion) {
    Write-Warning 'The USBip installer may briefly restart USB hubs. Save open files and pause active USB transfers before continuing.'
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ne $expectedSha256) {
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/$asset" -OutFile $installerPath
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
    if (Test-Path -LiteralPath $x86UsbipExe -PathType Leaf) { $usbipExe = $x86UsbipExe }
}
if (-not (Test-Path -LiteralPath $usbipExe -PathType Leaf)) {
    throw 'The USBip installer completed, but usbip.exe was not found under Program Files.'
}

Write-Host "USBip client is ready at: $usbipExe"

# Keep the client scripts in the per-user app-data folder so shortcuts and the
# logon task continue working if the source checkout is moved or removed.
$clientRoot = Join-Path $configDir 'client'
$installedUsbIpDir = Join-Path $clientRoot 'windows\UsbIp'
$installedPiUsbIpDir = Join-Path $clientRoot 'pi\usbip'
New-Item -ItemType Directory -Path $installedUsbIpDir, $installedPiUsbIpDir -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $installedUsbIpDir -Force
Copy-Item -Path (Join-Path $PSScriptRoot '..\..\pi\usbip\*') -Destination $installedPiUsbIpDir -Force

# Establish key-based SSH once so the hidden logon tunnel does not wait for an
# invisible password prompt. Only the public key is installed on the Pi.
$sshClient = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $sshClient) { throw 'OpenSSH Client (ssh.exe) was not found. Install the Windows OpenSSH Client feature.' }
$sshPath = [string]$sshClient.Source
if ([string]::IsNullOrWhiteSpace($sshPath)) { $sshPath = [string]$sshClient.Path }
if ([string]::IsNullOrWhiteSpace($sshPath)) { throw 'OpenSSH Client was found, but its executable path could not be resolved.' }
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
$keySuffix = ($PiAddress -replace '[^A-Za-z0-9.-]', '_')
$keyPath = Join-Path $sshDir ('usbhub_' + $keySuffix + '_ed25519')
$previousAddress = [string]$previousConfig.PiAddress
$previousUser = [string]$previousConfig.PiUser
$previousIdentityFile = [string]$previousConfig.IdentityFile
if ([string]::IsNullOrWhiteSpace($previousIdentityFile) -and -not [string]::IsNullOrWhiteSpace($previousAddress)) {
    $previousKeySuffix = $previousAddress -replace '[^A-Za-z0-9.-]', '_'
    $previousIdentityFile = Join-Path $sshDir ('usbhub_' + $previousKeySuffix + '_ed25519')
}
if (($previousUser -eq $PiUser) -and (Test-Path -LiteralPath $previousIdentityFile -PathType Leaf)) {
    $keyPath = $previousIdentityFile
}
$publicKeyPath = "$keyPath.pub"
if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
    $keygenPath = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
    $keygenArguments = '-t ed25519 -N "" -C "usbhub-{0}" -f "{1}"' -f $PiAddress, $keyPath
    $keygen = Start-Process -FilePath $keygenPath -ArgumentList $keygenArguments -NoNewWindow -Wait -PassThru
    if ($keygen.ExitCode -ne 0) { throw 'Could not create the SSH key for the USBHub tunnel.' }
}
elseif (-not (Test-Path -LiteralPath $publicKeyPath -PathType Leaf)) {
    & ssh-keygen.exe -y -f $keyPath | Set-Content -LiteralPath $publicKeyPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) { throw 'Could not derive the public SSH key for the USBHub tunnel.' }
}
$publicKeyContent = Get-Content -LiteralPath $publicKeyPath -Raw
if ($null -eq $publicKeyContent) { throw "The SSH public key file is empty: $publicKeyPath" }
$keyLine = $publicKeyContent.Trim()
if ([string]::IsNullOrWhiteSpace($keyLine)) { throw "The SSH public key file is empty: $publicKeyPath" }
$remoteKeyInstall = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$keyLine' ~/.ssh/authorized_keys || printf '%s\n' '$keyLine' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
$hostKeyAlias = [string]$previousConfig.HostKeyAlias
if ([string]::IsNullOrWhiteSpace($hostKeyAlias)) {
    if (-not [string]::IsNullOrWhiteSpace($previousAddress)) { $hostKeyAlias = $previousAddress }
    else { $hostKeyAlias = $PiAddress }
}
$config = [ordered]@{
    PiAddress    = $PiAddress
    PiUser       = $PiUser
    IdentityFile = $keyPath
    HostKeyAlias = $hostKeyAlias
    ReceiveMode  = $ReceiveMode
}
$tempConfig = "$configPath.tmp"
$config | ConvertTo-Json | Set-Content -LiteralPath $tempConfig -Encoding UTF8
Move-Item -LiteralPath $tempConfig -Destination $configPath -Force

$sshClient = Get-Command ssh.exe -ErrorAction Stop
$savedErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $sshPath -o BatchMode=yes -o "IdentityFile=$keyPath" -o "HostKeyAlias=$hostKeyAlias" "$PiUser@$PiAddress" 'exit 0' 2>$null
    $keyAuthExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $savedErrorPreference
}
if ($keyAuthExitCode -ne 0) {
    Write-Host "Authorize this PC's public SSH key on the Pi. Enter the Pi account password when prompted."
    & $sshPath -o PreferredAuthentications=password -o PubkeyAuthentication=no -o "HostKeyAlias=$hostKeyAlias" "$PiUser@$PiAddress" $remoteKeyInstall
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the SSH public key on the Pi; the automatic tunnel was not configured.' }
}
Write-Host "Saved this hub as $PiUser@$PiAddress for the current Windows account."
Write-Host "Saved USB/IP receive mode: $ReceiveMode. Change it with -ReceiveMode zero-copy or -ReceiveMode low-latency."

$tunnelScript = Join-Path $installedUsbIpDir 'Start-UsbHubTunnel.ps1'
$tunnelSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PiAddress,
    [Parameter(Mandatory = $true)][string] $PiUser,
    [Parameter(Mandatory = $true)][string] $IdentityFile,
    [Parameter(Mandatory = $true)][string] $HostKeyAlias
)
$ErrorActionPreference = 'Continue'
$logFile = Join-Path $env:LOCALAPPDATA 'UsbHub\tunnel.log'
$sshPath = '__USBHUB_SSH_EXE__'
while ($true) {
    "$(Get-Date -Format o) Starting SSH tunnel to $PiAddress" | Add-Content -LiteralPath $logFile
    $sshArgs = @('-N', '-T', '-i', $IdentityFile, '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3', '-o', "HostKeyAlias=$HostKeyAlias",
        '-L', '3240:127.0.0.1:3240', "$PiUser@$PiAddress")
    & $sshPath @sshArgs 2>> $logFile
    "$(Get-Date -Format o) SSH exited with code $LASTEXITCODE; retrying shortly" | Add-Content -LiteralPath $logFile
    Start-Sleep -Seconds 5
}
'@
$tunnelSource = $tunnelSource.Replace('__USBHUB_SSH_EXE__', $sshPath.Replace("'", "''"))
Set-Content -LiteralPath $tunnelScript -Value $tunnelSource -Encoding UTF8

$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
if ($null -eq $shell) { throw 'Windows Script Host did not provide the shortcut service (WScript.Shell).' }
foreach ($taskName in @('USBHub SSH Tunnel', 'USBHub Auto Connect')) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

$startupDir = [Environment]::GetFolderPath('Startup')
$legacyAutoShortcut = Join-Path $startupDir 'USBHub Auto Connect.lnk'
Remove-Item -LiteralPath $legacyAutoShortcut -Force -ErrorAction SilentlyContinue
$startupShortcutPath = Join-Path $startupDir 'USBHub SSH Tunnel.lnk'
$startupShortcut = $shell.CreateShortcut($startupShortcutPath)
if ($null -eq $startupShortcut) { throw "Windows could not create the startup shortcut at $startupShortcutPath." }
$startupShortcut.TargetPath = $powershellExe
$startupShortcut.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tunnelScript`" -PiAddress `"$PiAddress`" -PiUser `"$PiUser`" -IdentityFile `"$keyPath`" -HostKeyAlias `"$hostKeyAlias`""
$startupShortcut.WorkingDirectory = $installedUsbIpDir
$startupShortcut.Description = 'Starts and maintains the USBHub SSH tunnel at Windows sign-in.'
$startupShortcut.WindowStyle = 7
$startupShortcut.Save()

$stopScript = Join-Path $installedUsbIpDir 'Stop-UsbHubTunnel.ps1'
$stopSource = @'
param(
    [Parameter(Mandatory = $true)][string] $TunnelScript,
    [Parameter(Mandatory = $true)][string] $AutoScript,
    [Parameter(Mandatory = $true)][string] $IdentityFile
)
$ErrorActionPreference = 'SilentlyContinue'
Stop-ScheduledTask -TaskName 'USBHub Auto Connect'
Stop-ScheduledTask -TaskName 'USBHub SSH Tunnel'
$runners = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($TunnelScript) -or ($_.CommandLine.Contains($AutoScript) -and $_.CommandLine.Contains('-Action Auto'))) })
$runners | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 1
$sshProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($IdentityFile) })
$sshProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Write-Host 'USBHub SSH tunnel stopped for this Windows session.'
'@
Set-Content -LiteralPath $stopScript -Value $stopSource -Encoding UTF8

$claimScript = Join-Path $installedUsbIpDir 'Invoke-UsbHubUsbIp.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Claim USBHub Device.lnk'
$shortcut = $shell.CreateShortcut($shortcutPath)
if ($null -eq $shortcut) { throw "Windows could not create the desktop shortcut at $shortcutPath." }
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$claimScript`" -Action Claim -Confirm:`$false"
$shortcut.WorkingDirectory = $installedUsbIpDir
$shortcut.Description = 'Choose a USB device on the USBHub and claim it for this PC.'
$shortcut.Save()
$deviceCenterScript = Join-Path $installedUsbIpDir 'Show-UsbHubDeviceCenter.ps1'
$deviceCenterPath = Join-Path $desktop 'USBHub Device Center.lnk'
$deviceCenter = $shell.CreateShortcut($deviceCenterPath)
if ($null -eq $deviceCenter) { throw "Windows could not create the device center shortcut at $deviceCenterPath." }
$deviceCenter.TargetPath = $powershellExe
$deviceCenter.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$deviceCenterScript`""
$deviceCenter.WorkingDirectory = $installedUsbIpDir
$deviceCenter.Description = 'Browse USB devices on the USBHub and use or return one on this PC.'
$deviceCenter.Save()
$stopShortcutPath = Join-Path $desktop 'Stop USBHub Tunnel.lnk'
$stopShortcut = $shell.CreateShortcut($stopShortcutPath)
if ($null -eq $stopShortcut) { throw "Windows could not create the desktop shortcut at $stopShortcutPath." }
$stopShortcut.TargetPath = $powershellExe
$stopShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$stopScript`" -TunnelScript `"$tunnelScript`" -AutoScript `"$claimScript`" -IdentityFile `"$keyPath`""
$stopShortcut.WorkingDirectory = $installedUsbIpDir
$stopShortcut.Description = 'Stops the USBHub SSH tunnel until the next Windows sign-in.'
$stopShortcut.Save()

if (-not $SkipPiSetup) {
    Write-Host 'Configuring the Pi safety helper and unattended USB/IP permission (enter the Pi sudo password if requested)...'
    & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $claimScript -Action SetupPi -PiAddress $PiAddress -PiUser $PiUser
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the Pi USB/IP safety helper; automatic claiming was not started.' }
}
else {
    Write-Host 'Skipping Pi-side setup; using the existing USB/IP safety helper and permission.'
}

& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $stopScript -TunnelScript $tunnelScript -AutoScript $claimScript -IdentityFile $keyPath
Start-Process -FilePath $powershellExe -ArgumentList $startupShortcut.Arguments -WindowStyle Hidden

Write-Host 'The hidden SSH tunnel starts now and at Windows sign-in. Devices remain on the Pi until a PC requests them.'
Write-Host "Open '$deviceCenterPath' to browse devices, choose Use on this PC, or return a device to the hub."
Write-Host "The command-line shortcut '$shortcutPath' remains available for manual device selection."
Write-Host "Use '$stopShortcutPath' to stop the tunnel for the current session."
