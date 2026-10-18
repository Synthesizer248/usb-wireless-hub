#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:configPath = Join-Path $env:LOCALAPPDATA 'UsbHub\client.json'
$script:clientRoot = Join-Path $env:LOCALAPPDATA 'UsbHub\client'
$script:backendPath = Join-Path $script:clientRoot 'windows\UsbIp\Invoke-UsbHubUsbIp.ps1'
$script:tunnelPath = Join-Path $script:clientRoot 'windows\UsbIp\Start-UsbHubTunnel.ps1'
$script:powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:sshPath = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
$script:usbipPath = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
if (-not (Test-Path -LiteralPath $script:usbipPath -PathType Leaf)) {
    $script:usbipPath = Join-Path ${env:ProgramFiles(x86)} 'USBip\usbip.exe'
}

if (-not (Test-Path -LiteralPath $script:configPath -PathType Leaf)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        'This PC is not configured for USBHub yet. Run Install-UsbHubClient.ps1 once, then open Device Center again.',
        'USBHub setup needed', 'OK', 'Information')
    exit 1
}
try {
    $script:config = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$script:config.PiAddress)) { throw 'The Pi address is missing from client.json.' }
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Could not read USBHub settings: $($_.Exception.Message)", 'USBHub setup error', 'OK', 'Error')
    exit 1
}
if (-not (Test-Path -LiteralPath $script:backendPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $script:tunnelPath -PathType Leaf)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        'USBHub client files are incomplete. Re-run Install-UsbHubClient.ps1.', 'USBHub setup needed', 'OK', 'Warning')
    exit 1
}
if (-not $script:sshPath -or -not (Test-Path -LiteralPath $script:usbipPath -PathType Leaf)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        'OpenSSH Client or the USBip client is missing. Re-run Install-UsbHubClient.ps1 to repair this PC.',
        'USBHub client missing', 'OK', 'Warning')
    exit 1
}

function ConvertTo-PowerShellLiteral {
    param([AllowEmptyString()][string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-UsbHubTunnel {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect('127.0.0.1', 3240, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(350)) { return $false }
        $client.EndConnect($pending)
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

$script:queryCommand = @'
$ErrorActionPreference = 'Stop'
try {
    $config = Get-Content -LiteralPath $env:USBHUB_CONFIG_PATH -Raw | ConvertFrom-Json
    $sshArgs = @('-o', 'BatchMode=yes')
    if (-not [string]::IsNullOrWhiteSpace([string]$config.IdentityFile)) { $sshArgs += @('-i', [string]$config.IdentityFile) }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.HostKeyAlias)) { $sshArgs += @('-o', "HostKeyAlias=$($config.HostKeyAlias)") }
    $target = '{0}@{1}' -f $config.PiUser, $config.PiAddress

    $inventory = @(& $env:USBHUB_SSH_PATH @sshArgs $target '/usr/sbin/usbip list --local' 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Could not read the Pi USB inventory: $($inventory -join ' ')" }
    $classLines = @(& $env:USBHUB_SSH_PATH @sshArgs $target '/usr/local/sbin/manage-usbhub-usbip inventory' 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Could not read device class information: $($classLines -join ' ')" }

    $exportLines = @(& $env:USBHUB_USBIP_PATH list -r 127.0.0.1 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "The USB/IP tunnel is not ready: $($exportLines -join ' ')" }
    $portLines = @(& $env:USBHUB_USBIP_PATH port 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Could not read this PC's USB/IP devices: $($portLines -join ' ')" }

    $classMap = @{}
    foreach ($line in $classLines) {
        $parts = ([string]$line) -split "`t"
        if ($parts.Count -ge 4 -and $parts[0] -match '^[0-9]+-[0-9]+(\.[0-9]+)*$') {
            $classMap[$parts[0]] = [pscustomobject]@{ Classes = $parts[2]; Drivers = $parts[3] }
        }
    }
    $exported = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $exportLines) {
        $match = [regex]::Match([string]$line, '^\s*([0-9]+-[0-9]+(?:\.[0-9]+)*)\s*:')
        if ($match.Success) { [void]$exported.Add($match.Groups[1].Value) }
    }
    $connected = @{}
    $portText = $portLines -join [Environment]::NewLine
    $blocks = [regex]::Matches($portText, '(?ms)^Port\s+0*(?<port>\d+):(?<body>.*?)(?=^Port\s+0*\d+:|\z)')
    foreach ($block in $blocks) {
        $body = $block.Groups['body'].Value
        $busMatch = [regex]::Match($body, 'usbip://[^/\s]+/(?<bus>[0-9]+-[0-9]+(?:\.[0-9]+)*)')
        if (-not $busMatch.Success) { continue }
        $deviceMatch = [regex]::Match($body, '(?m)^\s*(?<name>.+?)\s+\((?<vid>[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\)\s*$')
        $portName = if ($deviceMatch.Success) { $deviceMatch.Groups['name'].Value.Trim() } else { 'USB device' }
        $portVidPid = if ($deviceMatch.Success) { $deviceMatch.Groups['vid'].Value.ToUpperInvariant() } else { '' }
        $connected[$busMatch.Groups['bus'].Value] = [pscustomobject]@{ Port = [int]$block.Groups['port'].Value; Name = $portName; VidPid = $portVidPid }
    }

    $devices = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $inventory.Count; $i++) {
        $line = [string]$inventory[$i]
        $match = [regex]::Match($line, '^\s*-\s*busid\s+(?<bus>[0-9]+-[0-9]+(?:\.[0-9]+)*)\s*(?:\((?<vid>[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\))?')
        if (-not $match.Success) { continue }
        $bus = $match.Groups['bus'].Value
        $vidPid = $match.Groups['vid'].Value.ToUpperInvariant()
        $name = $line.Trim()
        if (($i + 1) -lt $inventory.Count -and [string]$inventory[$i + 1] -notmatch '^\s*-\s*busid\s+') {
            $detail = ([string]$inventory[$i + 1]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($detail)) { $name = $detail }
        }
        if ($name -match '\s+\([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}\)$') { $name = $name -replace '\s+\([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}\)$', '' }
        $classes = ''
        $drivers = ''
        if ($classMap.ContainsKey($bus)) { $classes = [string]$classMap[$bus].Classes; $drivers = [string]$classMap[$bus].Drivers }
        $classValues = @($classes -split ',' | ForEach-Object { $_.ToLowerInvariant() })
        $driverValues = @($drivers -split ',' | ForEach-Object { $_.ToLowerInvariant() })
        if (($classValues -contains '03') -or ($driverValues | Where-Object { $_ -in @('usbhid', 'hid-generic', 'hid-multitouch', 'xpad') })) { $kind = 'HID input' }
        elseif (($classValues -contains '08') -or ($driverValues -contains 'usb-storage')) { $kind = 'Storage' }
        elseif ($classValues -contains '07') { $kind = 'Printer' }
        elseif ($classValues -contains '0e') { $kind = 'Webcam' }
        else { $kind = 'USB device' }
        if ($connected.ContainsKey($bus)) { $state = 'Connected to this PC'; $port = [int]$connected[$bus].Port; if ($vidPid -eq '') { $vidPid = [string]$connected[$bus].VidPid } }
        elseif ($exported.Contains($bus)) { $state = 'Available'; $port = 0 }
        else { $state = 'On hub'; $port = 0 }
        $devices.Add([pscustomobject]@{ BusId = $bus; VidPid = $vidPid; Name = $name; Kind = $kind; State = $state; Port = $port })
    }
    foreach ($bus in @($connected.Keys)) {
        if (@($devices | Where-Object { $_.BusId -eq $bus }).Count -gt 0) { continue }
        $entry = $connected[$bus]
        $devices.Add([pscustomobject]@{ BusId = $bus; VidPid = [string]$entry.VidPid; Name = [string]$entry.Name; Kind = 'USB device'; State = 'Connected to this PC'; Port = [int]$entry.Port })
    }

    [pscustomobject]@{ Ok = $true; Hub = $target; Devices = @($devices.ToArray()); Error = '' } | ConvertTo-Json -Depth 5 -Compress
}
catch {
    [pscustomobject]@{ Ok = $false; Hub = ''; Devices = @(); Error = $_.Exception.Message } | ConvertTo-Json -Depth 4 -Compress
}
'@

function Start-ChildPowerShell {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][ValidateSet('Inventory', 'Connect', 'Disconnect')][string] $Kind
    )
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:powershellPath
    $startInfo.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.EnvironmentVariables['USBHUB_CONFIG_PATH'] = $script:configPath
    $startInfo.EnvironmentVariables['USBHUB_SSH_PATH'] = $script:sshPath
    $startInfo.EnvironmentVariables['USBHUB_USBIP_PATH'] = $script:usbipPath
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start the USBHub background operation.' }
    $process.StandardInput.Close()
    $script:childProcess = $process
    $script:childOutput = $process.StandardOutput.ReadToEndAsync()
    $script:childError = $process.StandardError.ReadToEndAsync()
    $script:operationKind = $Kind
    $script:operationStarted = Get-Date
    $script:refreshButton.Enabled = $false
    $script:hubButton.Enabled = $false
    $script:deviceActionButton.Enabled = $false
    $script:statusLabel.Text = if ($Kind -eq 'Inventory') { 'Reading devices from the USBHub...' } elseif ($Kind -eq 'Connect') { 'Connecting the selected device...' } else { 'Returning the device to the USBHub...' }
    $script:timer.Start()
}

function Start-Inventory {
    if (-not (Test-UsbHubTunnel)) {
        $script:statusLabel.Text = 'Hub tunnel is offline. Select Connect to Hub.'
        Update-Buttons
        return
    }
    Start-ChildPowerShell -Command $script:queryCommand -Kind Inventory
}

function Start-HubTunnel {
    if (Test-UsbHubTunnel) { Start-Inventory; return }
    $tunnelRunning = $false
    try {
        $tunnelRunning = [bool](Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:tunnelPath) } | Select-Object -First 1)
    }
    catch { }
    if (-not $tunnelRunning) {
        $command = '& {0} -PiAddress {1} -PiUser {2} -IdentityFile {3} -HostKeyAlias {4}' -f `
            (ConvertTo-PowerShellLiteral $script:tunnelPath),
            (ConvertTo-PowerShellLiteral ([string]$script:config.PiAddress)),
            (ConvertTo-PowerShellLiteral ([string]$script:config.PiUser)),
            (ConvertTo-PowerShellLiteral ([string]$script:config.IdentityFile)),
            (ConvertTo-PowerShellLiteral ([string]$script:config.HostKeyAlias))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Start-Process -FilePath $script:powershellPath -WindowStyle Hidden -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    }
    $script:waitingForTunnel = $true
    $script:tunnelDeadline = (Get-Date).AddSeconds(20)
    $script:statusLabel.Text = 'Connecting to the USBHub over the saved SSH tunnel...'
    $script:refreshButton.Enabled = $false
    $script:hubButton.Enabled = $false
    $script:deviceActionButton.Enabled = $false
    $script:timer.Start()
}

function Update-Buttons {
    $idle = ($null -eq $script:childProcess) -and -not $script:waitingForTunnel
    $tunnelReady = Test-UsbHubTunnel
    $script:refreshButton.Enabled = $idle
    $script:hubButton.Text = if ($tunnelReady) { 'Hub Connected' } else { 'Connect to Hub' }
    $script:hubButton.Enabled = $idle -and -not $tunnelReady
    $script:deviceActionButton.Enabled = $false
    $script:deviceActionButton.Text = 'Use on this PC'
    if ($script:deviceList.SelectedItems.Count -eq 0 -or $null -eq $script:inventoryData) { return }
    $device = $script:deviceList.SelectedItems[0].Tag
    if ($device.State -eq 'Connected to this PC') {
        $script:deviceActionButton.Text = 'Return to Hub'
        $script:deviceActionButton.Enabled = $idle
    }
    elseif ($device.State -in @('Available', 'On hub') -and $tunnelReady) {
        $script:deviceActionButton.Text = 'Use on this PC'
        $script:deviceActionButton.Enabled = $idle
    }
}

function Show-Inventory {
    param($Inventory)
    $script:inventoryData = $Inventory
    $script:deviceList.BeginUpdate()
    $script:deviceList.Items.Clear()
    foreach ($device in @($Inventory.Devices)) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$device.Name)
        [void]$item.SubItems.Add([string]$device.BusId)
        [void]$item.SubItems.Add([string]$device.VidPid)
        [void]$item.SubItems.Add([string]$device.Kind)
        [void]$item.SubItems.Add([string]$device.State)
        $item.Tag = $device
        [void]$script:deviceList.Items.Add($item)
    }
    $script:deviceList.EndUpdate()
    $script:hubNameLabel.Text = "USBHub - $($Inventory.Hub)"
    if (@($Inventory.Devices).Count -eq 0) { $script:statusLabel.Text = 'Hub is connected; no USB devices are currently attached.' }
    else { $script:statusLabel.Text = "Found $(@($Inventory.Devices).Count) device(s). Select one, then choose Use on this PC. Mounted drives are refused." }
    Update-Buttons
}

function Invoke-SelectedDeviceAction {
    if ($script:deviceList.SelectedItems.Count -eq 0) { return }
    $device = $script:deviceList.SelectedItems[0].Tag
    if ($device.State -eq 'Connected to this PC') {
        $message = "Return '$($device.Name)' to the USBHub? This disconnects it from this PC."
        if ($device.Kind -eq 'Storage') { $message += "`r`n`r`nClose files and use Windows Safely Remove Hardware first." }
        $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Return USB device', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if ($device.Port -lt 1) { [void][System.Windows.Forms.MessageBox]::Show('Could not determine the active USB/IP port. Refresh the list and try again.', 'USBHub error', 'OK', 'Error'); return }
        $command = '& {0} -Action Disconnect -Port {1} -Confirm:$false' -f (ConvertTo-PowerShellLiteral $script:backendPath), [int]$device.Port
        Start-ChildPowerShell -Command $command -Kind Disconnect
        return
    }
    if ($device.State -notin @('Available', 'On hub')) { return }
    $message = "Use '$($device.Name)' on this PC?`r`n`r`nUSB devices have one owner at a time. This transfers the device from the Pi to this PC."
    if ($device.Kind -eq 'HID input') {
        $message += "`r`n`r`nThis is a keyboard, mouse, or gamepad class device. It will stop being available through the Pi's HID/VHF bridge while this PC owns it."
    }
    if ($device.Kind -eq 'Storage') {
        $message += "`r`n`r`nThe Pi will refuse the transfer if Linux has the drive mounted. Safely eject it in Windows before returning it."
    }
    if ($device.Kind -eq 'Webcam') {
        $message += "`r`n`r`nThe camera will use low-latency USB/IP receive mode for live video. Camera streaming depends on the Pi USB host controller and Wi-Fi bandwidth."
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Use USB device', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $receiveMode = [string]$script:config.ReceiveMode
    if ($device.Kind -eq 'Webcam') { $receiveMode = 'low-latency' }
    $command = '& {0} -Action Connect -BusId {1} -ReceiveMode {2} -Confirm:$false' -f `
        (ConvertTo-PowerShellLiteral $script:backendPath),
        (ConvertTo-PowerShellLiteral ([string]$device.BusId)),
        (ConvertTo-PowerShellLiteral $receiveMode)
    Start-ChildPowerShell -Command $command -Kind Connect
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'USBHub Device Center'
$script:form.StartPosition = 'CenterScreen'
$script:form.Size = New-Object System.Drawing.Size(940, 590)
$script:form.MinimumSize = New-Object System.Drawing.Size(760, 450)
$script:form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$rootPanel = New-Object System.Windows.Forms.TableLayoutPanel
$rootPanel.Dock = 'Fill'
$rootPanel.ColumnCount = 1
$rootPanel.RowCount = 4
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$script:form.Controls.Add($rootPanel)

$headerPanel = New-Object System.Windows.Forms.TableLayoutPanel
$headerPanel.Dock = 'Top'
$headerPanel.AutoSize = $true
$headerPanel.ColumnCount = 2
$headerPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$headerPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
$script:hubNameLabel = New-Object System.Windows.Forms.Label
$script:hubNameLabel.Text = "USBHub - $($script:config.PiAddress)"
$script:hubNameLabel.AutoSize = $true
$script:hubNameLabel.Padding = New-Object System.Windows.Forms.Padding(14, 14, 8, 10)
$script:hubNameLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$headerPanel.Controls.Add($script:hubNameLabel, 0, 0)
$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.AutoSize = $true
$buttonPanel.Dock = 'Fill'
$buttonPanel.FlowDirection = 'LeftToRight'
$buttonPanel.WrapContents = $false
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 9, 10, 4)
$script:refreshButton = New-Object System.Windows.Forms.Button
$script:refreshButton.Text = 'Refresh'
$script:refreshButton.Width = 92
$script:refreshButton.Height = 32
$script:hubButton = New-Object System.Windows.Forms.Button
$script:hubButton.Text = 'Connect to Hub'
$script:hubButton.Width = 126
$script:hubButton.Height = 32
$buttonPanel.Controls.AddRange(@($script:refreshButton, $script:hubButton))
$headerPanel.Controls.Add($buttonPanel, 1, 0)
$rootPanel.Controls.Add($headerPanel, 0, 0)

$script:deviceList = New-Object System.Windows.Forms.ListView
$script:deviceList.Dock = 'Fill'
$script:deviceList.View = 'Details'
$script:deviceList.FullRowSelect = $true
$script:deviceList.GridLines = $true
$script:deviceList.HideSelection = $false
[void]$script:deviceList.Columns.Add('USB device', 360)
[void]$script:deviceList.Columns.Add('Bus ID', 95)
[void]$script:deviceList.Columns.Add('VID:PID', 90)
[void]$script:deviceList.Columns.Add('Type', 115)
[void]$script:deviceList.Columns.Add('Connection', 180)
$rootPanel.Controls.Add($script:deviceList, 0, 1)

$script:deviceActionButton = New-Object System.Windows.Forms.Button
$script:deviceActionButton.Text = 'Use on this PC'
$script:deviceActionButton.Width = 150
$script:deviceActionButton.Height = 36
$script:deviceActionButton.Enabled = $false
$actionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$actionPanel.Dock = 'Fill'
$actionPanel.Height = 50
$actionPanel.FlowDirection = 'RightToLeft'
$actionPanel.Padding = New-Object System.Windows.Forms.Padding(8)
$actionPanel.Controls.Add($script:deviceActionButton)
$rootPanel.Controls.Add($actionPanel, 0, 2)

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = 'Ready.'
$script:statusLabel.Dock = 'Fill'
$script:statusLabel.AutoSize = $true
$script:statusLabel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$rootPanel.Controls.Add($script:statusLabel, 0, 3)

$script:inventoryData = $null
$script:childProcess = $null
$script:childOutput = $null
$script:childError = $null
$script:operationKind = ''
$script:waitingForTunnel = $false
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 350

$script:timer.Add_Tick({
    if ($script:waitingForTunnel) {
        if (Test-UsbHubTunnel) {
            $script:waitingForTunnel = $false
            Start-Inventory
            return
        }
        if ((Get-Date) -ge $script:tunnelDeadline) {
            $script:waitingForTunnel = $false
            $script:statusLabel.Text = 'Could not reach the hub. Check Wi-Fi and SSH; see %LOCALAPPDATA%\UsbHub\tunnel.log.'
            $script:refreshButton.Enabled = $true
            $script:hubButton.Enabled = $true
            $script:hubButton.Text = 'Connect to Hub'
            return
        }
    }
    if ($null -eq $script:childProcess -or -not $script:childProcess.HasExited) { return }
    $script:childProcess.WaitForExit()
    $exitCode = $script:childProcess.ExitCode
    $stdout = $script:childOutput.Result
    $stderr = $script:childError.Result
    $script:childProcess.Dispose()
    $script:childProcess = $null
    $script:childOutput = $null
    $script:childError = $null
    $kind = $script:operationKind
    $script:operationKind = ''
    $script:timer.Stop()

    if ($kind -eq 'Inventory') {
        try {
            $data = $stdout | ConvertFrom-Json -ErrorAction Stop
            if (-not $data.Ok) { throw [string]$data.Error }
            Show-Inventory $data
        }
        catch {
            $detail = $_.Exception.Message
            if (-not [string]::IsNullOrWhiteSpace($stderr)) { $detail += "`r`n$stderr" }
            $script:statusLabel.Text = "Could not read the hub: $detail"
            $script:inventoryData = $null
            $script:deviceList.Items.Clear()
            Update-Buttons
        }
    }
    else {
        if ($exitCode -eq 0) {
            $script:statusLabel.Text = if ($kind -eq 'Connect') { 'Device connected. Refreshing the device list...' } else { 'Device returned. Refreshing the device list...' }
        }
        else {
            $detail = ($stderr + [Environment]::NewLine + $stdout).Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "Operation exited with code $exitCode." }
            [void][System.Windows.Forms.MessageBox]::Show($detail, 'USBHub operation failed', 'OK', 'Error')
            $script:statusLabel.Text = 'The operation failed. Refresh the list after fixing the reported issue.'
        }
        Update-Buttons
        Start-Inventory
    }
})

$script:refreshButton.Add_Click({ Start-Inventory })
$script:hubButton.Add_Click({ Start-HubTunnel })
$script:deviceActionButton.Add_Click({ Invoke-SelectedDeviceAction })
$script:deviceList.Add_SelectedIndexChanged({ Update-Buttons })
$script:form.Add_Shown({ Start-Inventory })
$script:form.Add_FormClosed({ $script:timer.Stop(); $script:timer.Dispose() })
[void][System.Windows.Forms.Application]::Run($script:form)
