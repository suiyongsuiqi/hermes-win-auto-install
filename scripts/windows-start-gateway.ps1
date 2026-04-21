[CmdletBinding()]
param(
    [switch]$FromStartup,
    [switch]$AllowRecentWechatSessionSuccess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$paths = Get-HermesPaths
$completed = New-Object System.Collections.Generic.List[string]

function Open-WeixinSetupWindow {
    $shellPath = Get-PreferredPowerShellExecutable
    if (-not $shellPath) {
        return
    }

    Start-Process -FilePath $shellPath -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $paths.WeChatSetupPs) | Out-Null
}

function Start-GatewayProcess {
    param(
        [Parameter(Mandatory = $true)]$ResolvedConfig,
        [switch]$ReplaceExisting
    )

    $command = @'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.hermes/logs" "$HOME/.hermes/run"

if ps -eo args= | grep -F "hermes gateway run" | grep -v "grep" >/dev/null; then
  if [ "__REPLACE_EXISTING__" = "true" ]; then
    nohup ~/.local/bin/hermes gateway run --replace >> "$HOME/.hermes/logs/gateway.log" 2>&1 < /dev/null &
    sleep 8
    if ps -eo args= | grep -F "hermes gateway run" | grep -v "grep" >/dev/null; then
      printf 'replaced'
      exit 0
    fi
    printf 'failed'
    exit 1
  fi
  printf 'already-running'
  exit 0
fi

nohup ~/.local/bin/hermes gateway run >> "$HOME/.hermes/logs/gateway.log" 2>&1 < /dev/null &
sleep 8

if ps -eo args= | grep -F "hermes gateway run" | grep -v "grep" >/dev/null; then
  printf 'started'
  exit 0
fi

printf 'failed'
exit 1
'@
    $command = $command.Replace('__REPLACE_EXISTING__', $(if ($ReplaceExisting) { 'true' } else { 'false' }))

    return Invoke-WslBash `
        -Distro $ResolvedConfig.DistroName `
        -User $ResolvedConfig.Username `
        -Command $command `
        -TimeoutSeconds 180 `
        -ProgressMessage '正在等待 Hermes gateway run 在 WSL 内稳定运行。'
}

try {
    $config = Get-ResolvedInstallConfig
    $state = Get-HermesState
    $replaceRunningGateway = ($null -ne $state -and [string]$state.stage -eq 'wechat-bound')
    $weixinConfigured = Test-WeixinConfigured -DistroName $config.DistroName -Username $config.Username
    Write-Step '开始执行 Hermes gateway 启动阶段。'

    if (-not (Test-WslDistributionHealthy -Name $config.DistroName)) {
        throw "Distribution $($config.DistroName) is not healthy enough for gateway startup."
    }

    $completed.Add('Confirmed the target distribution is healthy.')

    if (-not $weixinConfigured -and -not $AllowRecentWechatSessionSuccess) {
        Save-HermesState -Stage 'ready-for-wechat' -Config $config -LastResult 'weixin-not-configured'

        if ($FromStartup) {
            Open-WeixinSetupWindow
        }

        return [PSCustomObject]@{
            Status     = 'not-configured'
            DistroName = $config.DistroName
            Username   = $config.Username
        }
    }

    if ($weixinConfigured) {
        $completed.Add('Confirmed that a Weixin binding is already present.')
    }
    else {
        $completed.Add('Proceeding with gateway startup because the latest Weixin setup session already reported success.')
    }

    if ((Test-HermesGatewayRunning -DistroName $config.DistroName -Username $config.Username) -and -not $replaceRunningGateway) {
        Save-HermesState -Stage 'gateway-running' -Config $config -LastResult 'already-running'
        $completed.Add('Detected an already-running hermes gateway run process.')

        return [PSCustomObject]@{
            Status     = 'already-running'
            DistroName = $config.DistroName
            Username   = $config.Username
        }
    }

    Save-HermesState -Stage 'starting-gateway' -Config $config -LastResult 'starting-gateway'
    $startResult = Start-GatewayProcess -ResolvedConfig $config -ReplaceExisting:$replaceRunningGateway
    if (-not (Test-HermesGatewayRunning -DistroName $config.DistroName -Username $config.Username)) {
        $logTail = Get-HermesGatewayLogTail -DistroName $config.DistroName -Username $config.Username -Lines 80
        if ($logTail -match 'errcode\s*=\s*-14' -or $logTail -match 'errcode=-14') {
            Save-HermesState -Stage 'ready-for-wechat' -Config $config -LastResult 'weixin-reauth-required'
            if ($FromStartup) {
                Open-WeixinSetupWindow
            }

            return [PSCustomObject]@{
                Status     = 'reauth-required'
                DistroName = $config.DistroName
                Username   = $config.Username
                LogTail    = $logTail
            }
        }

        throw "hermes gateway run did not remain running. Latest gateway log:`n$logTail"
    }

    Save-HermesState -Stage 'gateway-running' -Config $config -LastResult $startResult
    if ($startResult -match 'replaced') {
        $completed.Add('Restarted hermes gateway run inside WSL so the latest Weixin policy takes effect.')
    }
    else {
        $completed.Add('Started hermes gateway run inside WSL.')
    }

    return [PSCustomObject]@{
        Status     = 'success'
        DistroName = $config.DistroName
        Username   = $config.Username
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'gateway-start-failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
