$ErrorActionPreference = 'Stop'

$receiverExe = Join-Path $env:ProgramData 'UsbHub\GenericReceiver\UsbVhfReceiver.exe'
$pfxPath = Join-Path $env:LOCALAPPDATA 'UsbHub\certs\receiver.pfx'
$passwordPath = Join-Path $env:LOCALAPPDATA 'UsbHub\certs\receiver-password.dpapi'
$clientPinPath = Join-Path $env:LOCALAPPDATA 'UsbHub\certs\pi-client.sha256'
$logPath = Join-Path $env:LOCALAPPDATA 'UsbHub\generic-receiver.log'
$listenerPort = 5001 # Keep the experimental receiver separate from the working bridge on 5000.

foreach ($path in @($receiverExe, $pfxPath, $passwordPath, $clientPinPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required USBHub receiver file not found: $path"
    }
}

$clientCertificateSha256 = (Get-Content -LiteralPath $clientPinPath -Raw).Trim()
if ($clientCertificateSha256 -notmatch '^(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$') {
    throw "Invalid SHA-256 certificate pin in $clientPinPath. Save 32 colon-separated hexadecimal bytes."
}

$encryptedPassword = Get-Content -LiteralPath $passwordPath -Raw
$securePassword = ConvertTo-SecureString -String $encryptedPassword
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:USBHUB_RECEIVER_PFX_PASSWORD = $plainPassword
    & $receiverExe $pfxPath '--password-from-environment' $clientCertificateSha256 $listenerPort *>> $logPath
    exit $LASTEXITCODE
}
finally {
    Remove-Item Env:\USBHUB_RECEIVER_PFX_PASSWORD -ErrorAction SilentlyContinue
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    Remove-Variable plainPassword -ErrorAction SilentlyContinue
}
