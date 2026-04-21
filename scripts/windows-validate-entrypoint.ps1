[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryScripts = @(
    'scripts/windows-common.ps1',
    'scripts/windows-prefetch-assets.ps1',
    'scripts/windows-install-hermes.ps1',
    'scripts/windows-bootstrap.ps1',
    'scripts/windows-reuse-existing.ps1',
    'scripts/windows-enter-key.ps1',
    'scripts/windows-configure-wechat.ps1',
    'scripts/windows-start-gateway.ps1',
    'scripts/windows-webui.ps1',
    'scripts/windows-check-status.ps1'
)

function Write-Step {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

function Test-Utf8BomRequirement {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasNonAscii = $false

    foreach ($byte in $bytes) {
        if ($byte -gt 0x7F) {
            $hasNonAscii = $true
            break
        }
    }

    return [PSCustomObject]@{
        HasUtf8Bom  = $hasUtf8Bom
        HasNonAscii = $hasNonAscii
    }
}

function Invoke-ParserValidation {
    param(
        [Parameter(Mandatory = $true)][string]$ShellPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $tempScript = Join-Path $env:TEMP ("hermes-parse-{0}.ps1" -f ([guid]::NewGuid().ToString()))
    $content = @'
param([string]$TargetPath)

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($TargetPath, [ref]$tokens, [ref]$errors) | Out-Null

if ($errors.Count -gt 0) {
    foreach ($item in $errors) {
        Write-Output $item.Message
    }
    exit 1
}
'@

    Set-Content -LiteralPath $tempScript -Value $content -Encoding Ascii

    try {
        $output = & $ShellPath -NoProfile -ExecutionPolicy Bypass -File $tempScript $TargetPath 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($output | ForEach-Object { $_.ToString() })
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force
        }
    }
}

$shells = @()
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue

if (-not $pwsh) {
    throw 'pwsh.exe was not found. Install PowerShell 7.x before running windows-validate-entrypoint.ps1.'
}

if (-not $windowsPowerShell) {
    throw 'powershell.exe was not found. Windows PowerShell 5.1 is required for entrypoint fallback validation.'
}

$shells += [PSCustomObject]@{ Name = 'pwsh'; Path = $pwsh.Source }
$shells += [PSCustomObject]@{ Name = 'powershell'; Path = $windowsPowerShell.Source }

$failures = New-Object System.Collections.Generic.List[string]

foreach ($relativePath in $entryScripts) {
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $failures.Add("Missing entrypoint script: $relativePath")
        continue
    }

    $encoding = Test-Utf8BomRequirement -Path $fullPath
    if ($encoding.HasNonAscii -and -not $encoding.HasUtf8Bom) {
        $failures.Add("$relativePath contains non-ASCII text but is not saved as UTF-8 BOM.")
    }

    foreach ($shell in $shells) {
        $result = Invoke-ParserValidation -ShellPath $shell.Path -TargetPath $fullPath
        if ($result.ExitCode -ne 0) {
            $joined = if ($result.Output.Count -gt 0) { $result.Output -join ' | ' } else { 'unknown parser error' }
            $failures.Add("$relativePath failed parser validation in $($shell.Name): $joined")
        }
        else {
            Write-Step ("Validated {0} in {1}" -f $relativePath, $shell.Name)
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Entrypoint validation failed:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host ("- {0}" -f $failure) -ForegroundColor Red
    }
    exit 1
}

Write-Host ''
Write-Host 'Entrypoint validation passed for all Windows installer scripts.' -ForegroundColor Green
