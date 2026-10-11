$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$receiverProject = Join-Path $repoRoot 'windows\Receiver\UsbVhfReceiver.csproj'
$driverSolution = Join-Path $repoRoot 'UsbHubVhfKeyboard.slnx'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

if (-not (Test-Path -LiteralPath $receiverProject -PathType Leaf)) {
    throw "Receiver project not found: $receiverProject"
}
if (-not (Test-Path -LiteralPath $driverSolution -PathType Leaf)) {
    throw "Driver solution not found: $driverSolution"
}
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio locator not found: $vswhere"
}

$vsRoots = @(& $vswhere -all -products '*' -property installationPath)
if ($LASTEXITCODE -ne 0 -or $vsRoots.Count -eq 0) {
    throw 'Could not locate a Visual Studio installation.'
}
$msbuild = $null
foreach ($vsRoot in $vsRoots) {
    $candidate = Join-Path $vsRoot 'MSBuild\Current\Bin\amd64\MSBuild.exe'
    $wdkTargets = Join-Path $vsRoot 'MSBuild\Microsoft\VC\v180\Platforms\x64\ImportAfter\Microsoft.Cpp.WDK.targets'
    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
        (Test-Path -LiteralPath $wdkTargets -PathType Leaf)) {
        $msbuild = $candidate
        break
    }
}
if (-not $msbuild) {
    throw '64-bit MSBuild with the Windows Driver Kit targets was not found. Install the C++ and WDK components in Visual Studio.'
}

Write-Host 'Building the .NET 10 receiver...'
& dotnet build $receiverProject --configuration Release
if ($LASTEXITCODE -ne 0) {
    throw "Receiver build failed with exit code $LASTEXITCODE."
}

Write-Host 'Building the generic KMDF/VHF driver with 64-bit MSBuild...'
& $msbuild $driverSolution /t:Build /p:Configuration=Debug /p:Platform=x64 /m /nologo
if ($LASTEXITCODE -ne 0) {
    throw "Driver build failed with exit code $LASTEXITCODE."
}

$packageDir = Join-Path $repoRoot 'x64\Debug\UsbHubVhfKeyboard'
Write-Host "Builds succeeded. Driver package: $packageDir"
