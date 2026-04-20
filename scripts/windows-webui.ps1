[CmdletBinding()]
param(
    [ValidateSet('Install', 'Start', 'Stop', 'Open', 'Status')]
    [string]$Action = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$completed = New-Object System.Collections.Generic.List[string]

function Test-WebUiInstalled {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $installPath = Get-HermesWebUiInstallPath -Config $ResolvedConfig
    return (Test-Path -LiteralPath (Join-Path $installPath 'start.sh'))
}

function Get-WebUiInstallPathInWsl {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)
    return (Convert-WindowsPathToWslMountPath -Path (Get-HermesWebUiInstallPath -Config $ResolvedConfig))
}

function Test-WebUiRunning {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    if (-not (Test-WslDistributionHealthy -Name $ResolvedConfig.DistroName)) {
        return $false
    }

    $installPathInWsl = (Get-WebUiInstallPathInWsl -ResolvedConfig $ResolvedConfig).Replace("'", "'\''")
    $command = @"
if ps -eo args= | grep -F '$installPathInWsl' | grep -F 'server.py' | grep -v grep >/dev/null; then
  echo running
elif ps -eo args= | grep -F '$installPathInWsl' | grep -F 'start.sh' | grep -v grep >/dev/null; then
  echo running
else
  echo stopped
fi
"@

    try {
        $text = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command $command -TimeoutSeconds 20
        $lines = @(
            $text -split "(`r`n|`n|`r)" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )
        return $lines -contains 'running'
    }
    catch {
        return $false
    }
}

function Install-WebUi {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $archivePath = Get-HermesWebUiArchivePath -Config $ResolvedConfig
    if (-not (Test-Path -LiteralPath $archivePath)) {
        throw "Missing WebUI archive: $archivePath"
    }

    $installRoot = Get-HermesWebUiInstallRoot
    $installPath = Get-HermesWebUiInstallPath -Config $ResolvedConfig
    Ensure-Directory -Path $installRoot

    if (Test-WebUiInstalled -ResolvedConfig $ResolvedConfig) {
        $completed.Add(("Reused existing Hermes WebUI files: {0}" -f $installPath))
        return
    }

    $tempRoot = Join-Path $installRoot ("extract-{0}" -f ([guid]::NewGuid().ToString()))
    Ensure-Directory -Path $tempRoot

    try {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $tempRoot -Force
        $sourceDir = Get-ChildItem -LiteralPath $tempRoot -Directory | Select-Object -First 1
        if ($null -eq $sourceDir) {
            throw 'Failed to find the extracted Hermes WebUI directory.'
        }

        if (Test-Path -LiteralPath $installPath) {
            Remove-Item -LiteralPath $installPath -Recurse -Force
        }

        Move-Item -LiteralPath $sourceDir.FullName -Destination $installPath
        $completed.Add(("Installed Hermes WebUI files into {0}" -f $installPath))
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Start-WebUi {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    if (-not (Test-WebUiInstalled -ResolvedConfig $ResolvedConfig)) {
        throw 'Hermes WebUI is not installed yet.'
    }

    if (-not (Test-WslDistributionHealthy -Name $ResolvedConfig.DistroName)) {
        throw "Distribution $($ResolvedConfig.DistroName) is not healthy enough for Hermes WebUI startup."
    }

    if (Test-WebUiRunning -ResolvedConfig $ResolvedConfig) {
        $completed.Add('Detected an already-running Hermes WebUI process.')
        return 'already-running'
    }

    $installPathInWsl = (Get-WebUiInstallPathInWsl -ResolvedConfig $ResolvedConfig).Replace("'", "'\''")
    $port = [string]$ResolvedConfig.WebUiPort
    $command = @'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.hermes/logs"
cd '__WEBUI_DIR__'

if [ ! -f ".venv/bin/activate" ]; then
  rm -rf .venv
  if python3 -m venv .venv >/dev/null 2>&1; then
    :
  else
    rm -rf .venv
    if command -v uv >/dev/null 2>&1; then
      uv venv .venv >/dev/null 2>&1
    else
      echo 'Failed to create the Hermes WebUI virtual environment: python3 -m venv is unavailable and uv is not installed.' >&2
      exit 1
    fi
  fi
fi

if [ ! -f ".venv/bin/activate" ]; then
  echo 'Hermes WebUI virtual environment creation did not produce .venv/bin/activate.' >&2
  exit 1
fi

. ".venv/bin/activate"
if python -m pip --version >/dev/null 2>&1; then
  python -m pip install --disable-pip-version-check -r requirements.txt >/dev/null 2>&1 || python -m pip install -r requirements.txt >/dev/null 2>&1
elif command -v uv >/dev/null 2>&1; then
  uv pip install --python ".venv/bin/python" -r requirements.txt >/dev/null 2>&1
else
  echo 'Neither pip nor uv is available to install Hermes WebUI requirements.' >&2
  exit 1
fi
export HERMES_WEBUI_AGENT_DIR="$HOME/.hermes/hermes-agent"
export HERMES_WEBUI_PORT='__WEBUI_PORT__'
nohup bash start.sh >> "$HOME/.hermes/logs/hermes_webui.log" 2>&1 < /dev/null &
sleep 8

if ps -eo args= | grep -F '__WEBUI_DIR__' | grep -F 'server.py' | grep -v grep >/dev/null; then
  printf 'started'
  exit 0
fi

if ps -eo args= | grep -F '__WEBUI_DIR__' | grep -F 'start.sh' | grep -v grep >/dev/null; then
  printf 'started'
  exit 0
fi

printf 'failed'
exit 1
'@
    $command = $command.Replace('__WEBUI_DIR__', $installPathInWsl)
    $command = $command.Replace('__WEBUI_PORT__', $port)

    $result = Invoke-WslBash `
        -Distro $ResolvedConfig.DistroName `
        -User $ResolvedConfig.Username `
        -Command $command `
        -TimeoutSeconds 900 `
        -ProgressMessage '正在 WSL 内启动 Hermes WebUI。'

    if (-not (Test-WebUiRunning -ResolvedConfig $ResolvedConfig)) {
        throw 'Hermes WebUI did not remain running after startup.'
    }

    $completed.Add('Started Hermes WebUI inside WSL.')
    return $result.Trim()
}

function Stop-WebUi {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    if (-not (Test-WslDistributionHealthy -Name $ResolvedConfig.DistroName)) {
        return 'skipped'
    }

    $installPathInWsl = (Get-WebUiInstallPathInWsl -ResolvedConfig $ResolvedConfig).Replace("'", "'\''")
    $command = @"
pkill -f '$installPathInWsl' 2>/dev/null || true
sleep 2
printf 'stopped'
"@
    Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command $command -TimeoutSeconds 30 | Out-Null
    $completed.Add('Stopped Hermes WebUI processes for the selected environment.')
    return 'stopped'
}

function Open-WebUi {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $url = "http://localhost:$($ResolvedConfig.WebUiPort)"
    Start-Process $url | Out-Null
    $completed.Add(("Opened Hermes WebUI in the default browser: {0}" -f $url))
    return $url
}

try {
    $config = Get-ResolvedInstallConfig

    switch ($Action) {
        'Install' {
            Install-WebUi -ResolvedConfig $config
            Save-HermesState -Stage 'webui-installed' -Config $config -LastResult 'webui-installed'
            return [PSCustomObject]@{
                Status     = 'installed'
                DistroName = $config.DistroName
            }
        }
        'Start' {
            $status = Start-WebUi -ResolvedConfig $config
            Save-HermesState -Stage 'webui-running' -Config $config -LastResult $status
            return [PSCustomObject]@{
                Status     = $status
                DistroName = $config.DistroName
            }
        }
        'Stop' {
            $status = Stop-WebUi -ResolvedConfig $config
            return [PSCustomObject]@{
                Status     = $status
                DistroName = $config.DistroName
            }
        }
        'Open' {
            $url = Open-WebUi -ResolvedConfig $config
            return [PSCustomObject]@{
                Status     = 'opened'
                Url        = $url
                DistroName = $config.DistroName
            }
        }
        'Status' {
            $installed = Test-WebUiInstalled -ResolvedConfig $config
            $running = if ($installed) { Test-WebUiRunning -ResolvedConfig $config } else { $false }
            return [PSCustomObject]@{
                Status     = $(if ($running) { 'running' } elseif ($installed) { 'installed' } else { 'missing' })
                Installed  = $installed
                Running    = $running
                DistroName = $config.DistroName
            }
        }
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'webui-failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
