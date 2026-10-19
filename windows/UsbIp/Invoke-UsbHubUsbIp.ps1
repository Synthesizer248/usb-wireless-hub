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
    [ValidateSet('Tunnel', 'Inventory', 'List', 'Ports', 'SetupPi', 'Claim', 'Auto', 'Connect', 'Attach', 'Disconnect', 'Release', 'Persist')]
    [string] $Action,
    [string] $PiAddress,
    [string] $PiUser,
    [string] $Server = '127.0.0.1',
    [ValidateSet('zero-copy', 'low-latency')]
    [string] $ReceiveMode,
    [string] $BusId,
    [int] $Port = 0
)

$ErrorActionPreference = 'Stop'
$networkResolver = Join-Path $PSScriptRoot 'Resolve-UsbHubPiAddress.ps1'
if (-not (Test-Path -LiteralPath $networkResolver -PathType Leaf)) {
    throw "USBHub network resolver is missing: $networkResolver. Re-run Install-UsbHubClient.ps1."
}
. $networkResolver

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
    $script:PiHostKeyAlias = [string]$clientConfig.HostKeyAlias
    $script:PiIdentityFile = [string]$clientConfig.IdentityFile
    $configuredReceiveMode = [string]$clientConfig.ReceiveMode
    if ([string]::IsNullOrWhiteSpace($ReceiveMode) -and -not [string]::IsNullOrWhiteSpace($configuredReceiveMode)) {
        $ReceiveMode = $configuredReceiveMode
    }
}
if ([string]::IsNullOrWhiteSpace($PiUser)) { $PiUser = 'admin' }
if ([string]::IsNullOrWhiteSpace($ReceiveMode)) { $ReceiveMode = 'zero-copy' }

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

function Get-PiConnectAddress {
    Assert-PiTarget
    return Resolve-UsbHubPiAddress -Address $script:PiAddress
}

function Assert-UsbIpClient {
    if (-not $script:usbip) { throw 'usbip.exe was not found. Run windows/UsbIp/Install-UsbHubClient.ps1 first.' }
}

function Get-SshIdentityArguments {
    $identityFile = $script:PiIdentityFile
    if ([string]::IsNullOrWhiteSpace($identityFile)) {
        $keySuffix = $script:PiAddress -replace '[^A-Za-z0-9.-]', '_'
        $identityFile = Join-Path $env:USERPROFILE ('.ssh\usbhub_' + $keySuffix + '_ed25519')
    }
    $arguments = @()
    if (Test-Path -LiteralPath $identityFile -PathType Leaf) {
        $arguments += @('-o', "IdentityFile=$identityFile")
    }
    if (-not [string]::IsNullOrWhiteSpace($script:PiHostKeyAlias)) {
        $arguments += @('-o', "HostKeyAlias=$script:PiHostKeyAlias")
    }
    return $arguments
}

function Invoke-PiHelper {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bind', 'unbind')][string] $Verb,
        [Parameter(Mandatory = $true)][string] $TargetBusId
    )
    Assert-SshClient
    if ($TargetBusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $TargetBusId" }
    # SetupPi grants this narrowly scoped helper passwordless sudo. Keep the
    # operation non-interactive: the Device Center has no terminal attached,
    # so ssh -t produces a misleading PTY warning and can hang on sudo.
    $sshArgs = @('-T', '-o', 'BatchMode=yes') + (Get-SshIdentityArguments) + @(
        "$script:PiUser@$(Get-PiConnectAddress)", "sudo -n $script:remoteHelper $Verb $TargetBusId")
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = @(& $script:ssh.Source @sshArgs 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()

    if ($Verb -eq 'bind') {
        if ($output -match '(?im)^\s*USBHUB_BIND_RESULT=newly-bound\s*$') { return $true }
        if ($output -match '(?im)^\s*USBHUB_BIND_RESULT=already-bound\s*$') { return $false }
        # Accept the exact benign response from older copies of the helper so
        # users do not need to reinstall the Pi helper before retrying a claim.
        if ($output -match '(?i)device on busid\s+[0-9]+-[0-9]+(?:\.[0-9]+)*\s+(?:is\s+)?already bound to usbip-host') { return $false }
    }
    else {
        if ($output -match '(?im)^\s*USBHUB_UNBIND_RESULT=unbound\s*$') { return $true }
        if ($output -match '(?im)^\s*USBHUB_UNBIND_RESULT=already-unbound\s*$') { return $false }
        if ($output -match '(?i)device is not bound to usbip-host') { return $false }
    }

    if ($exitCode -ne 0) {
        if ($output -match '(?i)sudo: a password is required|a terminal is required') {
            throw "Pi USB/IP permissions are not configured. Run -Action SetupPi once. $output"
        }
        throw "Pi USB/IP $Verb failed for $TargetBusId (exit $exitCode): $output"
    }
    return $true
}

function Invoke-UsbIpClient {
    param([Parameter(Mandatory = $true)][string[]] $UsbIpArguments)
    Assert-UsbIpClient
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = @(& $script:usbip @UsbIpArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-PortBusId {
    param([Parameter(Mandatory = $true)][int] $ImportedPort)
    $result = Invoke-UsbIpClient -UsbIpArguments @('port')
    if ($result.ExitCode -ne 0) { throw "Could not read imported USB/IP ports: $($result.Output)" }
    $output = $result.Output
    $blocks = [regex]::Matches($output, '(?ms)^Port\s+0*(\d+):(?<body>.*?)(?=^Port\s+0*\d+:|\z)')
    foreach ($block in $blocks) {
        if ([int]$block.Groups[1].Value -ne $ImportedPort) { continue }
        $match = [regex]::Match($block.Groups['body'].Value, 'usbip://[^/\s]+/([0-9]+-[0-9]+(?:\.[0-9]+)*)')
        if (-not $match.Success) { throw "Imported port $ImportedPort has no remote USB bus ID." }
        return $match.Groups[1].Value
    }
    throw "Imported USB/IP port $ImportedPort was not found. Run -Action Ports."
}

function Write-AutoLog {
    param([string] $Message)
    $logPath = Join-Path $env:LOCALAPPDATA 'UsbHub\auto-claim.log'
    "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $logPath
}

function Add-AutoClaimSuppression {
    param([Parameter(Mandatory = $true)][string] $TargetBusId)
    $path = Join-Path $env:LOCALAPPDATA 'UsbHub\auto-claim-suppress.txt'
    $now = [DateTime]::UtcNow
    $expiry = $now.AddMinutes(2)
    $retained = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($entry in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $columns = ([string]$entry) -split "`t", 2
            if ($columns.Count -ne 2 -or $columns[0] -eq $TargetBusId) { continue }
            try { $existingExpiry = [DateTime]::new([Int64]$columns[1], [DateTimeKind]::Utc) } catch { continue }
            if ($existingExpiry -gt $now) { $retained.Add("$($columns[0])`t$($existingExpiry.Ticks)") }
        }
    }
    $retained.Add("$TargetBusId`t$($expiry.Ticks)")
    Set-Content -LiteralPath $path -Value $retained -Encoding UTF8
}

function Get-AutoClaimSuppressions {
    $path = Join-Path $env:LOCALAPPDATA 'UsbHub\auto-claim-suppress.txt'
    $suppressed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $suppressed }

    $now = [DateTime]::UtcNow
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($entry in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $columns = ([string]$entry) -split "`t", 2
        if ($columns.Count -ne 2) { continue }
        try { $expiry = [DateTime]::new([Int64]$columns[1], [DateTimeKind]::Utc) } catch { continue }
        if ($expiry -le $now) { continue }
        [void]$suppressed.Add($columns[0])
        $retained.Add("$($columns[0])`t$($expiry.Ticks)")
    }
    Set-Content -LiteralPath $path -Value $retained -Encoding UTF8
    return $suppressed
}

function Get-AutoClaimCandidates {
    Assert-PiTarget
    Assert-SshClient
    $sshArgs = @('-o', 'BatchMode=yes') + (Get-SshIdentityArguments)
    $sshArgs += @("$script:PiUser@$(Get-PiConnectAddress)", "$script:remoteHelper inventory")
    $lines = @(& $script:ssh.Source @sshArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Pi auto-inventory failed: $($lines -join ' ')"
    }
    foreach ($line in $lines) {
        $match = [regex]::Match([string]$line, '^([0-9]+-[0-9]+(?:\.[0-9]+)*)\t([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\t([0-9A-Fa-f]{2}(?:,[0-9A-Fa-f]{2})*)\t([A-Za-z0-9_.-]*(?:,[A-Za-z0-9_.-]+)*)$')
        if (-not $match.Success) { continue }
        $classes = @($match.Groups[3].Value.Split(',') | ForEach-Object { $_.ToLowerInvariant() })
        # HID remains on the Pi's VHF bridge; hubs, network interfaces, and
        # webcams are excluded from unattended USB/IP ownership changes.
        $eligible = -not [bool]($classes | Where-Object { $_ -in @('03', '09', '02', '0a', '0e') })
        $drivers = @($match.Groups[4].Value.Split(',') | ForEach-Object { $_.ToLowerInvariant() })
        if ($drivers | Where-Object { $_ -in @('xpad', 'usbhid', 'hid-generic', 'hid-multitouch', 'usbip-host') }) { $eligible = $false }
        [pscustomobject]@{
            BusId = $match.Groups[1].Value
            VidPid = $match.Groups[2].Value.ToUpperInvariant()
            Classes = $classes -join ','
            Drivers = $drivers -join ','
            Eligible = $eligible
        }
    }
}

function Invoke-AutoPiHelper {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bind', 'unbind')][string] $Verb,
        [Parameter(Mandatory = $true)][string] $TargetBusId
    )
    return Invoke-PiHelper -Verb $Verb -TargetBusId $TargetBusId
}

if ($Action -eq 'Inventory') {
    Assert-PiTarget
    Assert-SshClient
    Write-Host "USB devices on $PiUser@$PiAddress (read-only):"
    $sshArgs = (Get-SshIdentityArguments) + @("$PiUser@$(Get-PiConnectAddress)", '/usr/sbin/usbip list --local')
    & $ssh.Source @sshArgs
    if ($LASTEXITCODE -ne 0) { throw "Pi inventory failed with exit code $LASTEXITCODE." }
    exit 0
}

if ($Action -eq 'Tunnel') {
    Assert-PiTarget
    Assert-SshClient
    Write-Host ('Opening SSH tunnel localhost:3240 to ' + $PiAddress + ':3240. Keep this window open; Ctrl+C closes it.')
    $sshArgs = @('-N', '-L', '3240:127.0.0.1:3240') + (Get-SshIdentityArguments) + @("$PiUser@$(Get-PiConnectAddress)")
    & $ssh.Source @sshArgs
    exit $LASTEXITCODE
}

if ($Action -eq 'SetupPi') {
    Assert-PiTarget
    Assert-SshClient
    if (-not $scp) { throw 'OpenSSH scp.exe was not found.' }
    if (-not (Test-Path -LiteralPath $piHelper -PathType Leaf)) { throw "Pi safety helper not found: $piHelper" }
    $remoteTemp = '/tmp/manage-usbhub-usbip.sh'
    $remoteSpec = $PiUser + '@' + (Get-PiConnectAddress) + ':' + $remoteTemp
    $scpArgs = (Get-SshIdentityArguments) + @($piHelper, $remoteSpec)
    & $scp.Source @scpArgs
    if ($LASTEXITCODE -ne 0) { throw "Could not copy the Pi helper (exit $LASTEXITCODE)." }
    if ($PiUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]*\$?$') { throw 'Pi SSH user must be a simple Linux account name to configure the scoped USB/IP rule.' }
    $sudoersRule = "$PiUser ALL=(root) NOPASSWD: $remoteHelper bind *, $remoteHelper unbind *`n"
    $sudoersBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($sudoersRule))
    $setupCommand = "sudo install -o root -g root -m 0755 $remoteTemp $remoteHelper && rm -f $remoteTemp && printf '%s' '$sudoersBase64' | base64 -d > /tmp/usbhub-usbip.sudoers && sudo visudo -cf /tmp/usbhub-usbip.sudoers && sudo install -o root -g root -m 0440 /tmp/usbhub-usbip.sudoers /etc/sudoers.d/usbhub-usbip && rm -f /tmp/usbhub-usbip.sudoers && sudo visudo -cf /etc/sudoers.d/usbhub-usbip"
    $sshArgs = @('-t') + (Get-SshIdentityArguments) + @("$PiUser@$(Get-PiConnectAddress)", $setupCommand)
    & $ssh.Source @sshArgs
    if ($LASTEXITCODE -ne 0) { throw "Could not install the Pi helper (exit $LASTEXITCODE)." }
    Write-Host "Installed the mounted-storage safety helper and scoped unattended bind permission on the Pi."
    exit 0
}

if ($Action -in @('List', 'Ports', 'Claim', 'Auto', 'Connect', 'Attach', 'Disconnect', 'Release', 'Persist')) { Assert-UsbIpClient }

if ($Action -eq 'Auto') {
    Assert-PiTarget
    Assert-SshClient
    Assert-UsbIpClient
    $mutexName = 'Local\UsbHubAutoClaim'
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    if (-not $mutex.WaitOne(0)) { Write-AutoLog 'Another auto-claim process is already running; exiting.'; exit 0 }
    Write-AutoLog "Automatic claiming started for $PiUser@$PiAddress using receive mode $ReceiveMode. First PC to bind an eligible device owns it."
    try {
        while ($true) {
            try {
                if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port 3240 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
                    Start-Sleep -Seconds 5
                    continue
                }
                $portResult = Invoke-UsbIpClient -UsbIpArguments @('port')
                if ($portResult.ExitCode -ne 0) { throw "Could not inspect current USB/IP imports: $($portResult.Output)" }
                $portOutput = $portResult.Output
                $attached = @([regex]::Matches($portOutput, 'usbip://[^/\s]+/([0-9]+-[0-9]+(?:\.[0-9]+)*)') | ForEach-Object { $_.Groups[1].Value })
                $candidates = @(Get-AutoClaimCandidates)
                $suppressed = Get-AutoClaimSuppressions
                foreach ($candidate in $candidates) {
                    if (-not $candidate.Eligible -or $candidate.BusId -in $suppressed) { continue }
                    if ($candidate.BusId -in $attached) { continue }
                    try {
                        $newlyBound = [bool](Invoke-AutoPiHelper -Verb bind -TargetBusId $candidate.BusId)
                        $attach = Invoke-UsbIpClient -UsbIpArguments @('attach', '-r', $Server, '-b', $candidate.BusId, '--receive-mode', $ReceiveMode)
                        if ($attach.ExitCode -ne 0) {
                            if ($newlyBound) {
                                try { [void](Invoke-AutoPiHelper -Verb unbind -TargetBusId $candidate.BusId) }
                                catch { Write-AutoLog "Cleanup unbind failed for $($candidate.BusId): $($_.Exception.Message)" }
                            }
                            Write-AutoLog "Attach failed for $($candidate.BusId) $($candidate.VidPid): $($attach.Output)"
                            continue
                        }
                        Write-AutoLog "Claimed $($candidate.BusId) $($candidate.VidPid) (classes $($candidate.Classes); drivers $($candidate.Drivers); receive mode $ReceiveMode)."
                        $attached += $candidate.BusId
                        # Give Windows time to enumerate the storage stack and
                        # assign a mount point before exporting another device.
                        Start-Sleep -Seconds 8
                    }
                    catch {
                        # Another PC may have won the exclusive bind race, or a
                        # storage device may be mounted on the Pi. Retry later.
                        Write-AutoLog "Skipped $($candidate.BusId) $($candidate.VidPid): $($_.Exception.Message)"
                    }
                }
            }
            catch { Write-AutoLog "Scan failed: $($_.Exception.Message)" }
            Start-Sleep -Seconds 10
        }
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

if ($Action -eq 'Claim') {
    Assert-PiTarget
    Assert-SshClient
    if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port 3240 -InformationLevel Quiet)) {
        throw 'SSH tunnel not available on localhost:3240. Run -Action Tunnel in another PowerShell window.'
    }

    Write-Host "Reading devices attached to $PiUser@$PiAddress..."
    $inventory = @(& $ssh.Source "$PiUser@$PiAddress" '/usr/sbin/usbip list --local' 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Pi inventory failed with exit code $LASTEXITCODE`: $($inventory -join [Environment]::NewLine)" }

    $devices = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $inventory.Count; $i++) {
        $busMatch = [regex]::Match([string]$inventory[$i], '^\s*-\s*busid\s+([0-9]+-[0-9]+(?:\.[0-9]+)*)\s*(.*)$')
        if (-not $busMatch.Success) { continue }

        $description = $busMatch.Groups[2].Value.Trim()
        if (($i + 1) -lt $inventory.Count -and [string]$inventory[$i + 1] -notmatch '^\s*-\s*busid\s+') {
            $detail = ([string]$inventory[$i + 1]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                $description = (@($description, $detail) -join ' ').Trim()
            }
        }
        $devices.Add([pscustomobject]@{ BusId = $busMatch.Groups[1].Value; Description = $description })
    }
    if ($devices.Count -eq 0) { throw 'The Pi did not report any USB devices to choose from.' }

    Write-Host ''
    Write-Host 'Choose a device to claim for this PC:'
    for ($i = 0; $i -lt $devices.Count; $i++) {
        Write-Host ("[{0}] {1}  {2}" -f ($i + 1), $devices[$i].BusId, $devices[$i].Description)
    }
    $selection = Read-Host 'Enter a number (Ctrl+C to cancel)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $devices.Count) {
        throw 'Invalid device selection; no device was claimed.'
    }

    $BusId = $devices[[int]$selection - 1].BusId
    Write-Host "Requesting exclusive claim for USB device $BusId."
    $Action = 'Connect'
}

switch ($Action) {
    'List' { & $usbip list -r $Server }
    'Ports' {
        $result = Invoke-UsbIpClient -UsbIpArguments @('port')
        if ($result.ExitCode -ne 0) { throw "Could not read imported USB/IP ports: $($result.Output)" }
        Write-Host $result.Output
    }
    'Persist' {
        Write-Warning 'This saves every currently imported device for automatic reattachment on this PC. Disconnect anything you do not want this PC to claim again.'
        if ($PSCmdlet.ShouldProcess('all currently imported USB/IP devices', 'Save as persistent reconnect targets')) {
            $result = Invoke-UsbIpClient -UsbIpArguments @('port', '--stash')
            if ($result.ExitCode -ne 0) { throw "Could not save persistent USB/IP devices (exit $($result.ExitCode)): $($result.Output)" }
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) { Write-Host $result.Output }
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
        Write-Host "USB/IP receive mode: $ReceiveMode"
        if ($PSCmdlet.ShouldProcess("Pi USB device $BusId", 'Export and connect to this PC')) {
            $newlyBound = [bool](Invoke-PiHelper -Verb bind -TargetBusId $BusId)
            try {
                $attach = Invoke-UsbIpClient -UsbIpArguments @('attach', '-r', $Server, '-b', $BusId, '--receive-mode', $ReceiveMode)
                if ($attach.ExitCode -ne 0) { throw "USB/IP attach failed with exit code $($attach.ExitCode): $($attach.Output)" }
                if (-not [string]::IsNullOrWhiteSpace($attach.Output)) { Write-Host $attach.Output }
            }
            catch {
                if ($newlyBound) {
                    Write-Warning 'Attach failed; returning the newly created export to the Pi.'
                    try { [void](Invoke-PiHelper -Verb unbind -TargetBusId $BusId) }
                    catch { Write-Warning "Could not undo the new export: $($_.Exception.Message)" }
                }
                throw
            }
        }
    }
    'Attach' {
        if ([string]::IsNullOrWhiteSpace($BusId)) { throw 'Pass -BusId from List, for example -BusId 1-1.4.' }
        if ($BusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $BusId" }
        $result = Invoke-UsbIpClient -UsbIpArguments @('attach', '-r', $Server, '-b', $BusId, '--receive-mode', $ReceiveMode)
        if ($result.ExitCode -ne 0) { throw "USB/IP attach failed with exit code $($result.ExitCode): $($result.Output)" }
        if (-not [string]::IsNullOrWhiteSpace($result.Output)) { Write-Host $result.Output }
    }
    'Disconnect' {
        if ($Port -lt 1) { throw 'Pass the imported port from Ports, for example -Port 1.' }
        $TargetBusId = Get-PortBusId -ImportedPort $Port
        Write-Warning 'For storage, use Windows Safely Remove Hardware and close files before disconnecting.'
        if ($PSCmdlet.ShouldProcess("USB/IP port $Port ($TargetBusId)", 'Disconnect and return device to the Pi')) {
            Add-AutoClaimSuppression -TargetBusId $TargetBusId
            $detach = Invoke-UsbIpClient -UsbIpArguments @('detach', '-p', [string]$Port)
            if ($detach.ExitCode -ne 0) { throw "USB/IP detach failed with exit code $($detach.ExitCode); export remains bound. $($detach.Output)" }
            if (-not [string]::IsNullOrWhiteSpace($detach.Output)) { Write-Host $detach.Output }
            [void](Invoke-PiHelper -Verb unbind -TargetBusId $TargetBusId)
        }
    }
    'Release' {
        if ([string]::IsNullOrWhiteSpace($BusId)) { throw 'Pass -BusId for the exported device.' }
        if ($BusId -notmatch '^[0-9]+-[0-9]+(\.[0-9]+)*$') { throw "Invalid USB bus ID: $BusId" }
        $ports = Invoke-UsbIpClient -UsbIpArguments @('port')
        if ($ports.ExitCode -ne 0) { throw "Could not inspect imported USB/IP devices: $($ports.Output)" }
        if ($ports.Output -match [regex]::Escape("/$BusId")) { throw "Device $BusId is still attached. Disconnect it from Windows first." }
        if ($PSCmdlet.ShouldProcess("Pi USB device $BusId", 'Unbind and return it to the Pi')) {
            Add-AutoClaimSuppression -TargetBusId $BusId
            [void](Invoke-PiHelper -Verb unbind -TargetBusId $BusId)
        }
    }
}

if ($Action -in @('List', 'Ports', 'Attach') -and $LASTEXITCODE -ne 0) { throw "usbip.exe failed with exit code $LASTEXITCODE." }
