<#
.SYNOPSIS
    Discovers, exports, and connects USB devices from the USBHub Pi through SSH-tunneled USB/IP.
.DESCRIPTION
    Device-class agnostic: Windows loads its normal driver after USB/IP attachment.
    Device ownership is exclusive. Do not connect a device that the Pi is using for HID/VHF or iSCSI.
    Eject storage in Windows before disconnecting it.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Tunnel', 'Inventory', 'List', 'Ports', 'SetupPi', 'Connect', 'Attach', 'Disconnect', 'Release', 'Persist')]
    [string] $Action,
    [string] $PiAddress,
    [string] $PiUser,
    [string] $Server = '127.0.0.1',
    [string] $BusId,
    [int] $Port = 0
)

$ErrorActionPreference = 'Stop'
$clientConfigPath = Join-Path $env:LOCALAPPDATA 'UsbHub\client.json'
if (Test-Path -LiteralPath $clientConfigPath -PathType Leaf) {
    try {
        $clientConfig = Get-Content -LiteralPath $clientConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read USBHub client settings at $clientConfigPath`: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($PiAddress)) { $PiAddress = [string]$clientConfig.PiAddress }
    if ([string]::IsNullOrWhiteSpace($PiUser)) { $PiUser = [string]$clientConfig.PiUser }
}
if ([string]::IsNullOrWhiteSpace($PiUser)) { $PiUser = 'admin' }

$ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
$scp = Get-Command scp.exe -ErrorAction SilentlyContinue
$usbip = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
if (-not (Test-Path -LiteralPath $usbip -PathType Leaf)) {
    $usbip = Join-Path ${env:ProgramFiles(x86)} 'USBip\usbip.exe'
}
if (-not (Test-Path -LiteralPath $usbip -PathType Leaf)) { $usbip = $null }
$piHelper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\pi\usbip\manage-usbhub-usbip.sh'))
$remoteHelper = '/usr/local/sbin/manage-usbhub-usbip'

function Assert-SshClient {
    if (-not $script:ssh) { throw 'OpenSSH Client (ssh.exe) was not found. Install the Windows OpenSSH Client feature.' }
}

function Assert-PiTarget {
    if ([string]::IsNullOrWhiteSpace($script:PiAddress)) {
        throw 'Pi address is not configured. Run Install-UsbHubClient.ps1 or pass -PiAddress.'
    }
    if ($script:PiAddress -match '[\s/@]') { throw 'Pi address contains invalid characters.' }
    if ($script:PiUser -match '[\s/@]') { throw 'Pi SSH user contains invalid characters.' }
}

function Assert-UsbIpClient {
    if (-not $script:usbip) { throw 'usbip.exe was not found. Run windows/UsbIp/Install-UsbHubClient.ps1 first.' }
}

function Invoke-PiHelper {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bind', 'unbind')][string] $Verb,
        [Parameter(Mandatory = $true)][string] $TargetBusId
    )
    Assert-SshClient
    if ($TargetBusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $TargetBusId" }
    # A TTY lets sudo request the Pi account password when needed.
    & $script:ssh.Source -t "$script:PiUser@$script:PiAddress" "sudo $script:remoteHelper $Verb $TargetBusId"
    if ($LASTEXITCODE -ne 0) { throw "Pi USB/IP $Verb failed with exit code $LASTEXITCODE." }
}

function Get-PortBusId {
    param([Parameter(Mandatory = $true)][int] $ImportedPort)
    Assert-UsbIpClient
    $output = & $script:usbip port 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not read imported USB/IP ports: $output" }
    $blocks = [regex]::Matches($output, '(?ms)^Port\s+0*(\d+):(?<body>.*?)(?=^Port\s+0*\d+:|\z)')
    foreach ($block in $blocks) {
        if ([int]$block.Groups[1].Value -ne $ImportedPort) { continue }
        $match = [regex]::Match($block.Groups['body'].Value, 'usbip://[^/\s]+/([0-9]+-[0-9]+(?:\.[0-9]+)*)')
        if (-not $match.Success) { throw "Imported port $ImportedPort has no remote USB bus ID." }
        return $match.Groups[1].Value
    }
    throw "Imported USB/IP port $ImportedPort was not found. Run -Action Ports."
}

if ($Action -eq 'Inventory') {
    Assert-PiTarget
    Assert-SshClient
    Write-Host "USB devices on $PiUser@$PiAddress (read-only):"
    & $ssh.Source "$PiUser@$PiAddress" '/usr/sbin/usbip list --local'
    if ($LASTEXITCODE -ne 0) { throw "Pi inventory failed with exit code $LASTEXITCODE." }
    exit 0
}

if ($Action -eq 'Tunnel') {
    Assert-PiTarget
    Assert-SshClient
    Write-Host ('Opening SSH tunnel localhost:3240 to ' + $PiAddress + ':3240. Keep this window open; Ctrl+C closes it.')
    & $ssh.Source -N -L '3240:127.0.0.1:3240' "$PiUser@$PiAddress"
    exit $LASTEXITCODE
}

if ($Action -eq 'SetupPi') {
    Assert-PiTarget
    Assert-SshClient
    if (-not $scp) { throw 'OpenSSH scp.exe was not found.' }
    if (-not (Test-Path -LiteralPath $piHelper -PathType Leaf)) { throw "Pi safety helper not found: $piHelper" }
    $remoteTemp = '/tmp/manage-usbhub-usbip.sh'
    $remoteSpec = $PiUser + '@' + $PiAddress + ':' + $remoteTemp
    & $scp.Source $piHelper $remoteSpec
    if ($LASTEXITCODE -ne 0) { throw "Could not copy the Pi helper (exit $LASTEXITCODE)." }
    & $ssh.Source -t "$PiUser@$PiAddress" "sudo install -o root -g root -m 0755 $remoteTemp $remoteHelper && rm -f $remoteTemp"
    if ($LASTEXITCODE -ne 0) { throw "Could not install the Pi helper (exit $LASTEXITCODE)." }
    Write-Host "Installed the mounted-storage protection helper at $remoteHelper."
    exit 0
}

if ($Action -in @('List', 'Ports', 'Connect', 'Attach', 'Disconnect', 'Release', 'Persist')) { Assert-UsbIpClient }

switch ($Action) {
    'List' { & $usbip list -r $Server }
    'Ports' { & $usbip port }
    'Persist' {
        Write-Warning 'This saves every currently imported device for automatic reattachment on this PC. Disconnect anything you do not want this PC to claim again.'
        if ($PSCmdlet.ShouldProcess('all currently imported USB/IP devices', 'Save as persistent reconnect targets')) {
            & $usbip port --stash
            if ($LASTEXITCODE -ne 0) { throw "Could not save persistent USB/IP devices (exit $LASTEXITCODE)." }
            Write-Host 'Current USB/IP imports are saved for automatic reattachment by the USBip driver.'
        }
    }
    'Connect' {
        Assert-PiTarget
        if ([string]::IsNullOrWhiteSpace($BusId)) { throw 'Pass -BusId from Inventory/List.' }
        if ($BusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $BusId" }
        if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port 3240 -InformationLevel Quiet)) {
            throw 'SSH tunnel not available on localhost:3240. Run -Action Tunnel in another PowerShell window.'
        }
        Write-Warning 'Connect transfers exclusive ownership to this PC. Do not select a device currently used by Pi HID/VHF or iSCSI.'
        if ($PSCmdlet.ShouldProcess("Pi USB device $BusId", 'Export and connect to this PC')) {
            Invoke-PiHelper -Verb bind -TargetBusId $BusId
            try {
                & $usbip attach -r $Server -b $BusId
                if ($LASTEXITCODE -ne 0) { throw "USB/IP attach failed with exit code $LASTEXITCODE." }
            }
            catch {
                Write-Warning 'Attach failed; attempting to return the device to the Pi.'
                Invoke-PiHelper -Verb unbind -TargetBusId $BusId
                throw
            }
        }
    }
    'Attach' {
        if ([string]::IsNullOrWhiteSpace($BusId)) { throw 'Pass -BusId from List, for example -BusId 1-1.4.' }
        if ($BusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $BusId" }
        & $usbip attach -r $Server -b $BusId
    }
    'Disconnect' {
        if ($Port -lt 1) { throw 'Pass the imported port from Ports, for example -Port 1.' }
        $TargetBusId = Get-PortBusId -ImportedPort $Port
        Write-Warning 'For storage, use Windows Safely Remove Hardware and close files before disconnecting.'
        if ($PSCmdlet.ShouldProcess("USB/IP port $Port ($TargetBusId)", 'Disconnect and return device to the Pi')) {
            & $usbip detach -p $Port
            if ($LASTEXITCODE -ne 0) { throw "USB/IP detach failed with exit code $LASTEXITCODE; export remains bound." }
            Invoke-PiHelper -Verb unbind -TargetBusId $TargetBusId
        }
    }
    'Release' {
        if ([string]::IsNullOrWhiteSpace($BusId)) { throw 'Pass -BusId for the exported device.' }
        if ($BusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $BusId" }
        $ports = & $usbip port 2>&1 | Out-String
        if ($ports -match [regex]::Escape("/$BusId")) { throw "Device $BusId is still attached. Disconnect it from Windows first." }
        if ($PSCmdlet.ShouldProcess("Pi USB device $BusId", 'Unbind and return it to the Pi')) {
            Invoke-PiHelper -Verb unbind -TargetBusId $BusId
        }
    }
}

if ($Action -in @('List', 'Ports', 'Attach') -and $LASTEXITCODE -ne 0) { throw "usbip.exe failed with exit code $LASTEXITCODE." }
