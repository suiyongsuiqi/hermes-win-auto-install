[CmdletBinding()]
param(
    [switch]$FactoryClean,
    [switch]$RemoveDownloads
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

if (-not $FactoryClean) {
    throw 'This script is destructive. Pass -FactoryClean explicitly to continue.'
}

if (-not (Test-IsAdministrator)) {
    throw 'windows-reset-wsl.ps1 must run as administrator.'
}

$paths = Get-HermesPaths
Write-Step 'Starting WSL factory clean.'
Write-Step 'This script is for internal validation only. It unregisters every WSL distribution on the machine.'

Unregister-HermesResume
Unregister-HermesGatewayAutostart
Clear-HermesState

try {
    & wsl.exe --shutdown 2>$null | Out-Null
}
catch {
    Write-Step 'wsl --shutdown did not report success. Continuing cleanup.'
}

$distros = Get-WslDistributions
foreach ($distro in $distros) {
    Write-Step "Unregistering distribution: $distro"
    & wsl.exe --unregister $distro | Out-Null
}

if (Test-Path -LiteralPath $paths.CloudInitDir) {
    Get-ChildItem -LiteralPath $paths.CloudInitDir -Filter '*.user-data' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Step "Removing cloud-init file: $($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Force
    }
}

if ($RemoveDownloads -and (Test-Path -LiteralPath $paths.Downloads)) {
    Write-Step "Removing downloads directory: $($paths.Downloads)"
    Remove-Item -LiteralPath $paths.Downloads -Recurse -Force
}
elseif (Test-Path -LiteralPath $paths.Downloads) {
    Write-Step "Preserving downloads directory: $($paths.Downloads)"
}

if (Test-Path -LiteralPath $paths.StateRoot) {
    Write-Step "Removing local state directory: $($paths.StateRoot)"
    Remove-Item -LiteralPath $paths.StateRoot -Recurse -Force
}

$help = Get-WslHelpText
if ($help -match '--uninstall') {
    Write-Step 'Detected wsl --uninstall. Attempting app-layer uninstall.'
    try {
        & wsl.exe --uninstall | Out-Null
    }
    catch {
        Write-Step 'wsl --uninstall did not complete. Continuing with optional feature cleanup.'
    }
}

Write-Step 'Disabling optional feature: Microsoft-Windows-Subsystem-Linux'
dism.exe /online /Disable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /NoRestart | Out-Null
Write-Step 'Disabling optional feature: VirtualMachinePlatform'
dism.exe /online /Disable-Feature /FeatureName:VirtualMachinePlatform /NoRestart | Out-Null

$reboot = Test-RebootPending
Write-Step ("Factory clean complete. CBS_RebootPending={0}; WU_RebootRequired={1}" -f $reboot.CBSRebootPending, $reboot.WURebootRequired)
Write-Step 'Restart Windows now, then rerun start-install.bat when you are ready to validate the clean-room path again.'
