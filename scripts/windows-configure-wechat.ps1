[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$paths = Get-HermesPaths
$completed = New-Object System.Collections.Generic.List[string]

function Show-WeixinSetupIntro {
    Add-Type -AssemblyName System.Windows.Forms

    $message = @(
        '接下来会打开一个新的 CMD 窗口来执行 Hermes 微信绑定。',
        '',
        '请按下面顺序完成：',
        '1. 如果向导先让你选平台，请选择 Weixin',
        '2. 用手机微信扫描窗口里的二维码',
        '3. 在手机上确认登录',
        '4. 扫码成功后主窗口会自动继续，不需要手动关闭弹出的窗口',
        '',
        '取消后不会重装 WSL 或 Hermes，稍后重新运行安装器即可回到这一阶段。'
    ) -join [Environment]::NewLine

    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Hermes 微信绑定',
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )

    return $result -eq [System.Windows.Forms.DialogResult]::OK
}

function Ensure-WeixinDependencies {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $wheelhousePath = Join-Path $paths.Downloads 'weixin-wheelhouse'
    $wheelhousePathB64 = Convert-ToBase64 -Value $wheelhousePath
    $command = @'
set -euo pipefail
USER_NAME="$(id -un)"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -z "$HOME_DIR" ]; then
  HOME_DIR="${HOME:-/home/$USER_NAME}"
fi
export PATH="$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
REPO_DIR="$HOME_DIR/.hermes/hermes-agent"
PYTHON_BIN=""
WINDOWS_WHEELHOUSE="$(printf '%s' '__WHEELHOUSE_B64__' | base64 --decode)"
LINUX_WHEELHOUSE=""
INSTALL_MODE=""

if [ -x "$REPO_DIR/venv/bin/python" ]; then
  PYTHON_BIN="$REPO_DIR/venv/bin/python"
elif [ -x "$REPO_DIR/.venv/bin/python" ]; then
  PYTHON_BIN="$REPO_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo 'No usable Python interpreter was found for Weixin dependency install.' >&2
  exit 1
fi

if "$PYTHON_BIN" -c 'import importlib.util; modules=("aiohttp","cryptography","qrcode"); missing=[name for name in modules if importlib.util.find_spec(name) is None]; raise SystemExit(0 if not missing else 1)'
then
  exit 0
fi

if "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
  INSTALL_MODE="pip"
elif command -v uv >/dev/null 2>&1; then
  INSTALL_MODE="uv"
elif "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 && "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
  INSTALL_MODE="pip"
else
  echo 'Neither pip nor uv is available for the Weixin dependency install.' >&2
  exit 1
fi

if command -v wslpath >/dev/null 2>&1; then
  LINUX_WHEELHOUSE="$(wslpath -a "$WINDOWS_WHEELHOUSE" 2>/dev/null || true)"
fi

if [ -n "$LINUX_WHEELHOUSE" ] && [ -d "$LINUX_WHEELHOUSE" ]; then
  if [ "$INSTALL_MODE" = "uv" ]; then
    uv pip install --python "$PYTHON_BIN" --no-index --find-links "$LINUX_WHEELHOUSE" aiohttp cryptography qrcode
  else
    "$PYTHON_BIN" -m pip install --disable-pip-version-check --no-index --find-links "$LINUX_WHEELHOUSE" aiohttp cryptography qrcode
  fi
else
  if [ "$INSTALL_MODE" = "uv" ]; then
    uv pip install --python "$PYTHON_BIN" aiohttp cryptography qrcode
  else
    "$PYTHON_BIN" -m pip install --disable-pip-version-check aiohttp cryptography qrcode
  fi
fi
'@
    $command = $command.Replace('__WHEELHOUSE_B64__', $wheelhousePathB64)
    Ensure-Directory -Path $paths.StateRoot
    $tempScriptPath = Join-Path $paths.StateRoot ("weixin-deps-{0}.sh" -f ([guid]::NewGuid().ToString()))
    $scriptContent = ($command -replace "`r`n", "`n") -replace "`r", ''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScriptPath, $scriptContent, $utf8NoBom)
    $tempScriptPathInWsl = Convert-WindowsPathToWslMountPath -Path $tempScriptPath

    try {
        Invoke-WslBash `
            -Distro $ResolvedConfig.DistroName `
            -User $ResolvedConfig.Username `
            -Command ("chmod 700 '{0}' && bash '{0}'" -f $tempScriptPathInWsl) `
            -TimeoutSeconds 900 `
            -ProgressMessage '正在 WSL 内安装 Weixin 依赖。' `
            -RequireSuccess | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force
        }
    }
}

function Get-TextFileTail {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Lines = 80
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join [Environment]::NewLine).Trim()
    }
    catch {
        return ''
    }
}

function Get-WeixinBindingSnapshot {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $command = @'
set -euo pipefail
USER_NAME="$(id -un)"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -z "$HOME_DIR" ]; then
  HOME_DIR="${HOME:-/home/$USER_NAME}"
fi
HERMES_ENV="$HOME_DIR/.hermes/.env"
ACCOUNT_COUNT="0"
ACCOUNT_ID=""
TOKEN=""

if [ -d "$HOME_DIR/.hermes/weixin/accounts" ]; then
  ACCOUNT_COUNT="$(find "$HOME_DIR/.hermes/weixin/accounts" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
fi

if [ -f "$HERMES_ENV" ]; then
  ACCOUNT_ID="$(grep -m1 '^WEIXIN_ACCOUNT_ID=' "$HERMES_ENV" | cut -d= -f2- || true)"
  TOKEN="$(grep -m1 '^WEIXIN_TOKEN=' "$HERMES_ENV" | cut -d= -f2- || true)"
fi

printf 'account_count=%s\n' "$ACCOUNT_COUNT"
printf 'has_account_id=%s\n' "$(if [ -n "$ACCOUNT_ID" ]; then printf 'true'; else printf 'false'; fi)"
printf 'has_token=%s\n' "$(if [ -n "$TOKEN" ]; then printf 'true'; else printf 'false'; fi)"
printf 'configured=%s\n' "$(if [ -n "$ACCOUNT_ID" ] && [ -n "$TOKEN" ] && [ "${ACCOUNT_COUNT:-0}" -gt 0 ]; then printf 'true'; else printf 'false'; fi)"
'@

    $rawText = ''
    $details = @{
        account_count   = '0'
        has_account_id  = 'false'
        has_token       = 'false'
        configured      = 'false'
    }

    try {
        $rawText = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command $command -TimeoutSeconds 20
        foreach ($line in ($rawText -split "(`r`n|`n|`r)")) {
            if ($line -match '^(?<key>[a-z_]+)=(?<value>.*)$') {
                $details[$matches['key']] = $matches['value']
            }
        }
    }
    catch {
    }

    $accountCount = 0
    [int]::TryParse([string]$details.account_count, [ref]$accountCount) | Out-Null

    return [PSCustomObject]@{
        AccountCount  = $accountCount
        HasAccountId  = ([string]$details.has_account_id).Trim().ToLowerInvariant() -eq 'true'
        HasToken      = ([string]$details.has_token).Trim().ToLowerInvariant() -eq 'true'
        IsConfigured  = ([string]$details.configured).Trim().ToLowerInvariant() -eq 'true'
        RawText       = $rawText
    }
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>$null | Out-Null
    }
    catch {
    }
}

function Ensure-WeixinPostBindDefaults {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $command = @'
set -euo pipefail
USER_NAME="$(id -un)"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -z "$HOME_DIR" ]; then
  HOME_DIR="${HOME:-/home/$USER_NAME}"
fi
HERMES_ENV="$HOME_DIR/.hermes/.env"
mkdir -p "$HOME_DIR/.hermes"
touch "$HERMES_ENV"

write_env_value() {
  key="$1"
  value="$2"
  if grep -q "^${key}=" "$HERMES_ENV" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$HERMES_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >> "$HERMES_ENV"
  fi
}

sed -i '/^GATEWAY_ALLOW_ALL_USERS=/d' "$HERMES_ENV" 2>/dev/null || true
write_env_value 'WEIXIN_DM_POLICY' 'open'
write_env_value 'WEIXIN_ALLOW_ALL_USERS' 'true'
write_env_value 'WEIXIN_ALLOWED_USERS' ''
write_env_value 'WEIXIN_GROUP_POLICY' 'disabled'
write_env_value 'WEIXIN_GROUP_ALLOWED_USERS' ''

printf 'ok'
'@
    Ensure-Directory -Path $paths.StateRoot
    $tempScriptPath = Join-Path $paths.StateRoot ("weixin-dm-policy-{0}.sh" -f ([guid]::NewGuid().ToString()))
    $scriptContent = ($command -replace "`r`n", "`n") -replace "`r", ''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScriptPath, $scriptContent, $utf8NoBom)
    $tempScriptPathInWsl = Convert-WindowsPathToWslMountPath -Path $tempScriptPath

    try {
        $result = Invoke-WslBash `
            -Distro $ResolvedConfig.DistroName `
            -User $ResolvedConfig.Username `
            -Command ("chmod 700 '{0}' && bash '{0}'" -f $tempScriptPathInWsl) `
            -TimeoutSeconds 30 `
            -RequireSuccess

        if ($result.Trim() -ne 'ok') {
            throw 'Failed to normalize the post-bind Weixin defaults in ~/.hermes/.env.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force
        }
    }
}

function Start-WeixinSetupWindow {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    Ensure-Directory -Path $paths.StateRoot
    $tempCmdPath = Join-Path $paths.StateRoot ("weixin-setup-{0}.cmd" -f ([guid]::NewGuid().ToString()))
    $tempBashPath = Join-Path $paths.StateRoot ("weixin-setup-{0}.sh" -f ([guid]::NewGuid().ToString()))
    $windowLogPath = Join-Path $paths.StateRoot ("weixin-setup-window-{0}.log" -f ([guid]::NewGuid().ToString()))
    $windowLogPathB64 = Convert-ToBase64 -Value $windowLogPath
    $bashScript = @'
WINDOWS_LOG_PATH="$(printf '%s' '__WINDOW_LOG_B64__' | base64 --decode)"
WINDOW_LOG_FILE=""
if command -v wslpath >/dev/null 2>&1; then
  WINDOW_LOG_FILE="$(wslpath -a "$WINDOWS_LOG_PATH" 2>/dev/null || true)"
fi
if [ -n "$WINDOW_LOG_FILE" ]; then
  exec > >(tee -a "$WINDOW_LOG_FILE") 2>&1
fi
export PATH="$HOME/.local/bin:$PATH"
export COLUMNS="${COLUMNS:-140}"
export LINES="${LINES:-50}"
set -o pipefail
printf '\nHermes 微信绑定即将开始。\n脚本会自动选择 Weixin，并在扫码成功后默认允许当前微信直接发送私信，不再要求额外输入配对码。\n如果终端二维码不方便扫描，检测到腾讯 iLink 链接后会自动在默认浏览器里打开。\n绑定完成前不要关闭这个窗口。\n\n'
{
  printf '14\ny\n2\n1\n\n\n' | ~/.local/bin/hermes gateway setup
} 2>&1 | while IFS= read -r line; do
  printf '%s\n' "$line"
  case "$line" in
    https://liteapp.weixin.qq.com/q/*)
      printf '\n已在 Windows 默认浏览器中打开微信登录页面，请直接扫描浏览器里的二维码。\n\n'
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '$line'" >/dev/null 2>&1 || true
      ;;
  esac
done
status=${PIPESTATUS[0]}
exit "$status"
'@
    $bashScript = $bashScript.Replace('__WINDOW_LOG_B64__', $windowLogPathB64)
    $bashScriptContent = ($bashScript -replace "`r`n", "`n") -replace "`r", ''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempBashPath, $bashScriptContent, $utf8NoBom)
    $tempBashPathInWsl = Convert-WindowsPathToWslMountPath -Path $tempBashPath
    $wslLaunchLine = ('"%SystemRoot%\System32\wsl.exe" -d {0} -u {1} -- bash "{2}"' -f $ResolvedConfig.DistroName, $ResolvedConfig.Username, $tempBashPathInWsl)
    $cmdContent = @(
        '@echo off',
        'setlocal',
        'title Hermes 微信绑定',
        'chcp 65001 >nul',
        'mode con cols=140 lines=45',
        $wslLaunchLine,
        'set "EXITCODE=%ERRORLEVEL%"',
        'exit /b %EXITCODE%'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $tempCmdPath -Value $cmdContent -Encoding Ascii

    try {
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"{0}"' -f $tempCmdPath)) -PassThru
        $bindingSnapshot = $null
        $bindingDetected = $false
        $nextProgressAt = Get-Date

        while ($true) {
            $process.Refresh()
            $bindingSnapshot = Get-WeixinBindingSnapshot -ResolvedConfig $ResolvedConfig
            if ($bindingSnapshot.IsConfigured) {
                $bindingDetected = $true
                break
            }

            if ($process.HasExited) {
                break
            }

            if ((Get-Date) -ge $nextProgressAt) {
                Write-Step '正在等待用户完成可见的 Weixin 二维码绑定窗口。'
                $nextProgressAt = (Get-Date).AddSeconds(15)
            }

            Start-Sleep -Seconds 5
        }

        if (-not $bindingDetected) {
            $bindingSnapshot = Get-WeixinBindingSnapshot -ResolvedConfig $ResolvedConfig
            $bindingDetected = $bindingSnapshot.IsConfigured
        }

        if ($bindingDetected) {
            Write-Step '已检测到 Weixin 账号凭据写入，正在结束绑定窗口并继续主流程。'
            $graceDeadline = (Get-Date).AddSeconds(10)
            while (-not $process.HasExited -and (Get-Date) -lt $graceDeadline) {
                Start-Sleep -Seconds 1
                $process.Refresh()
            }

            if (-not $process.HasExited) {
                Stop-ProcessTree -ProcessId $process.Id
                Start-Sleep -Seconds 2
                $process.Refresh()
            }
        }

        $windowLogTail = Get-TextFileTail -Path $windowLogPath -Lines 120
        return [PSCustomObject]@{
            ExitCode       = $(if ($process.HasExited) { $process.ExitCode } else { -1 })
            BindingDetected = $bindingDetected
            AccountCount   = $(if ($null -ne $bindingSnapshot) { $bindingSnapshot.AccountCount } else { 0 })
            HasAccountId   = $(if ($null -ne $bindingSnapshot) { $bindingSnapshot.HasAccountId } else { $false })
            HasToken       = $(if ($null -ne $bindingSnapshot) { $bindingSnapshot.HasToken } else { $false })
            WindowLogPath  = $windowLogPath
            WindowLogTail  = $windowLogTail
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempCmdPath) {
            Remove-Item -LiteralPath $tempCmdPath -Force
        }
        if (Test-Path -LiteralPath $tempBashPath) {
            Remove-Item -LiteralPath $tempBashPath -Force
        }
    }
}

try {
    $config = Get-ResolvedInstallConfig
    Write-Step '开始执行 Weixin 绑定阶段。'

    if (-not (Test-WslDistributionHealthy -Name $config.DistroName)) {
        try {
            Invoke-WslDirectCommand -Distro $config.DistroName -User 'root' -CommandPath '/bin/echo' -Arguments @('ready') -TimeoutSeconds 20 | Out-Null
            Start-Sleep -Seconds 2
        }
        catch {
        }
    }

    if (-not (Test-WslDistributionHealthy -Name $config.DistroName)) {
        throw "Distribution $($config.DistroName) is not healthy enough for Weixin setup."
    }

    $completed.Add('Confirmed the target distribution is healthy.')

    if (Test-WeixinConfigured -DistroName $config.DistroName -Username $config.Username) {
        $accountCount = Get-WeixinAccountCount -DistroName $config.DistroName -Username $config.Username
        Ensure-WeixinPostBindDefaults -ResolvedConfig $config
        Save-HermesState -Stage 'wechat-bound' -Config $config -Notes ("account_count={0}" -f $accountCount) -LastResult 'already-bound'
        $completed.Add(("Detected an existing Weixin binding with {0} stored account file(s)." -f $accountCount))
        $completed.Add('Normalized the Weixin post-bind defaults so Hermes allows private messages and keeps group chats disabled.')

        return [PSCustomObject]@{
            Status       = 'already-bound'
            DistroName   = $config.DistroName
            Username     = $config.Username
            AccountCount = $accountCount
            WindowLogPath = ''
        }
    }
    Save-HermesState -Stage 'preparing-wechat' -Config $config -LastResult 'preparing-wechat'
    $gatewayHelp = Invoke-WslBash -Distro $config.DistroName -User $config.Username -Command '~/.local/bin/hermes gateway --help' -TimeoutSeconds 30 -RequireSuccess
    if (-not $gatewayHelp) {
        throw 'hermes gateway --help returned no output.'
    }

    $completed.Add('Confirmed hermes gateway is available inside WSL.')
    Ensure-WeixinDependencies -ResolvedConfig $config
    $completed.Add('Installed aiohttp, cryptography, and qrcode for the native Weixin flow.')
    Save-HermesState -Stage 'ready-for-wechat' -Config $config -LastResult 'ready-for-wechat'
    if (-not (Show-WeixinSetupIntro)) {
        Save-HermesState -Stage 'ready-for-wechat' -Config $config -LastResult 'wechat-cancelled'
        return [PSCustomObject]@{
            Status     = 'cancelled'
            DistroName = $config.DistroName
            Username   = $config.Username
            WindowLogPath = ''
        }
    }

    $setupResult = Start-WeixinSetupWindow -ResolvedConfig $config
    $accountCount = [int]$setupResult.AccountCount

    if ($setupResult.BindingDetected -or $accountCount -gt 0) {
        Ensure-WeixinPostBindDefaults -ResolvedConfig $config
        Save-HermesState -Stage 'wechat-bound' -Config $config -Notes ("account_count={0}" -f $accountCount) -LastResult 'wechat-bound'
        $completed.Add(("Stored {0} Weixin account file(s) under ~/.hermes/weixin/accounts." -f $accountCount))
        $completed.Add('Normalized the Weixin post-bind defaults so Hermes allows private messages and keeps group chats disabled.')

        return [PSCustomObject]@{
            Status       = 'success'
            DistroName   = $config.DistroName
            Username     = $config.Username
            AccountCount = $accountCount
            WindowLogPath = $setupResult.WindowLogPath
        }
    }

    $setupFailure = "The visible Weixin setup window exited before Hermes stored any Weixin account credentials. Exit code: $($setupResult.ExitCode)"
    if ($setupResult.WindowLogTail) {
        $setupFailure = "$setupFailure`nVisible setup window tail:`n$($setupResult.WindowLogTail)"
    }
    Save-HermesState -Stage 'wechat-setup-failed' -Config $config -LastResult ("wechat-setup-exit={0}" -f $setupResult.ExitCode)
    return [PSCustomObject]@{
        Status      = 'failed'
        DistroName  = $config.DistroName
        Username    = $config.Username
        ExitCode    = $setupResult.ExitCode
        LogTail     = $setupResult.WindowLogTail
        WindowLogPath = $setupResult.WindowLogPath
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'wechat-setup-failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
