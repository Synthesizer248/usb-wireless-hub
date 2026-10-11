$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Administrator PowerShell window.'
}

$receiverInstallDir = Join-Path $env:ProgramData 'UsbHub\GenericReceiver'
$receiverExe = Join-Path $receiverInstallDir 'UsbVhfReceiver.exe'
$receiverProject = Join-Path $PSScriptRoot 'UsbVhfReceiver.csproj'
$pfxPath = Join-Path $env:LOCALAPPDATA 'UsbHub\certs\receiver.pfx'
$certDir = Split-Path -Parent $pfxPath
$passwordPath = Join-Path $certDir 'receiver-password.dpapi'
$startScript = Join-Path $PSScriptRoot 'Start-UsbHubReceiver.ps1'
$taskName = 'USBHub Generic HID Bridge Receiver'

foreach ($path in @($receiverProject, $pfxPath, $startScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required USBHub receiver file not found: $path"
    }
}

New-Item -ItemType Directory -Path $certDir -Force | Out-Null
New-Item -ItemType Directory -Path $receiverInstallDir -Force | Out-Null
$buildOutputDir = Join-Path $receiverInstallDir 'build'
New-Item -ItemType Directory -Path $buildOutputDir -Force | Out-Null
& dotnet publish $receiverProject --configuration Release --output $receiverInstallDir "-p:OutputPath=$buildOutputDir\"
if ($LASTEXITCODE -ne 0) {
    throw "Receiver publish failed with exit code $LASTEXITCODE."
}

$securePassword = Read-Host 'Enter the receiver PFX password (saved encrypted for this Windows account)' -AsSecureString
if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
    throw 'No PFX password was entered. Re-run the script and enter the password you set when exporting receiver.pfx.'
}
$encryptedPassword = ConvertFrom-SecureString -SecureString $securePassword
Set-Content -LiteralPath $passwordPath -Value $encryptedPassword -Encoding ASCII -NoNewline

$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'Starts the experimental USBHub descriptor-driven HID TLS receiver at this account logon.' -Force | Out-Null
Write-Host "Registered '$taskName' to start when $($identity.Name) logs on. The PFX password is DPAPI-encrypted for this account."
Write-Host 'The task has not been started; stop the manually running receiver first, then run Start-ScheduledTask.'
