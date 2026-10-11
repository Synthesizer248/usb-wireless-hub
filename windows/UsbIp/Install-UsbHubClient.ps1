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
$requiredVersion = [version]$version
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

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

$config = [ordered]@{
    PiAddress = $PiAddress
    PiUser    = $PiUser
}
$tempConfig = "$configPath.tmp"
$config | ConvertTo-Json | Set-Content -LiteralPath $tempConfig -Encoding UTF8
Move-Item -LiteralPath $tempConfig -Destination $configPath -Force

Write-Host "USBip client is ready at: $usbipExe"
Write-Host "Saved this hub as $PiUser@$PiAddress for the current Windows account."

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
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
$keySuffix = ($PiAddress -replace '[^A-Za-z0-9.-]', '_')
$keyPath = Join-Path $sshDir "usbhub_${keySuffix}_ed25519"
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
$keyLine = (Get-Content -LiteralPath $publicKeyPath -Raw).Trim()
$remoteKeyInstall = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$keyLine' ~/.ssh/authorized_keys || printf '%s\n' '$keyLine' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
$sshClient = Get-Command ssh.exe -ErrorAction Stop
$savedErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $sshClient.Source -o BatchMode=yes -o "IdentityFile=$keyPath" "$PiUser@$PiAddress" 'exit 0' 2>$null
    $keyAuthExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $savedErrorPreference
}
if ($keyAuthExitCode -ne 0) {
    Write-Host 'Authorize this PC’s public SSH key on the Pi. Enter the Pi account password when prompted.'
    & $sshClient.Source -o PreferredAuthentications=password -o PubkeyAuthentication=no "$PiUser@$PiAddress" $remoteKeyInstall
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the SSH public key on the Pi; the automatic tunnel was not configured.' }
}

$tunnelScript = Join-Path $installedUsbIpDir 'Start-UsbHubTunnel.ps1'
$tunnelSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PiAddress,
    [Parameter(Mandatory = $true)][string] $PiUser,
    [Parameter(Mandatory = $true)][string] $IdentityFile
)
$ErrorActionPreference = 'Continue'
$ssh = Get-Command ssh.exe -ErrorAction Stop
while ($true) {
    & $ssh.Source -N -T -i $IdentityFile -o BatchMode=yes -o ExitOnForwardFailure=yes `
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 `
        -L '3240:127.0.0.1:3240' "$PiUser@$PiAddress"
    Start-Sleep -Seconds 5
}
'@
Set-Content -LiteralPath $tunnelScript -Value $tunnelSource -Encoding UTF8

$taskName = 'USBHub SSH Tunnel'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskAction = New-ScheduledTaskAction -Execute $powershellExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tunnelScript`" -PiAddress `"$PiAddress`" -PiUser `"$PiUser`" -IdentityFile `"$keyPath`""
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Description 'Maintains the SSH-only USB/IP tunnel to the configured USBHub Pi.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$claimScript = Join-Path $installedUsbIpDir 'Invoke-UsbHubUsbIp.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Claim USBHub Device.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$claimScript`" -Action Claim -Confirm:`$false"
$shortcut.WorkingDirectory = $installedUsbIpDir
$shortcut.Description = 'Choose a USB device on the USBHub and claim it for this PC.'
$shortcut.Save()

Write-Host "Automatic SSH tunnel is registered as '$taskName' and starts at Windows sign-in."
Write-Host "Use the desktop shortcut '$shortcutPath' to request a device claim."
Write-Host 'A PC still has to request ownership; USB devices are exclusive and are not automatically assigned to every connected PC.'
