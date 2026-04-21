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
        '接下来 Hermes 会在后台启动微信绑定流程，并自动打开默认浏览器中的登录页面。',
        '',
        '请按下面顺序完成：',
        '1. 如果向导先让你选平台，请选择 Weixin',
        '2. 用手机微信扫描浏览器页面里的二维码',
        '3. 在手机上确认登录',
        '4. 扫码成功后主窗口会自动继续，不需要手动关闭安装器',
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

function Get-TextFileContent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    }
    catch {
        return ''
    }
}

function Get-WeixinLoginUrlFromText {
    param([AllowNull()][string]$Text)

    $normalized = ConvertTo-HermesTrimmedText -Value $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    $match = [regex]::Match($normalized, 'https://liteapp\.weixin\.qq\.com/q/\S+')
    if (-not $match.Success) {
        return ''
    }

    return $match.Value.TrimEnd('"', "'", ')', ']', '}')
}

function Test-WeixinQrNoiseLine {
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $normalized = ([string]$Line).Replace([char]0x00A0, ' ').Trim()
    if ($normalized.Length -lt 20) {
        return $false
    }

    return $normalized -match '^[█▀▄ ]+$'
}

function ConvertTo-WeixinSessionLogText {
    param(
        [AllowNull()][string]$Text,
        [string]$BrowserUrl = '',
        [bool]$BrowserOpened = $false,
        [string]$BrowserOpenError = ''
    )

    $normalized = ConvertTo-HermesText -Value $Text
    $lines = New-Object System.Collections.Generic.List[string]
    $previousBlank = $false

    foreach ($line in ($normalized -split "(`r`n|`n|`r)")) {
        if (Test-WeixinQrNoiseLine -Line $line) {
            continue
        }

        $trimmedRight = [string]$line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmedRight)) {
            if (-not $previousBlank) {
                $lines.Add('') | Out-Null
                $previousBlank = $true
            }
            continue
        }

        $lines.Add($trimmedRight) | Out-Null
        $previousBlank = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($BrowserUrl)) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add('') | Out-Null
        }
        $lines.Add(("Weixin browser login URL: {0}" -f $BrowserUrl)) | Out-Null
        if ($BrowserOpened) {
            $lines.Add('已在 Windows 默认浏览器中打开微信登录页面，请直接扫描浏览器里的二维码。') | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BrowserOpenError)) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add('') | Out-Null
        }
        $lines.Add(("打开默认浏览器失败：{0}" -f $BrowserOpenError)) | Out-Null
    }

    return (($lines -join [Environment]::NewLine).Trim())
}

function Write-WeixinSessionLog {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$RawLogPath = '',
        [string]$StdOutCapturePath = '',
        [string]$StdErrCapturePath = '',
        [string]$BrowserUrl = '',
        [bool]$BrowserOpened = $false,
        [string]$BrowserOpenError = ''
    )

    $rawText = Get-TextFileContent -Path $RawLogPath
    if ([string]::IsNullOrWhiteSpace($rawText)) {
        $fallbackSegments = @(
            Get-TextFileContent -Path $StdOutCapturePath,
            Get-TextFileContent -Path $StdErrCapturePath
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $rawText = (($fallbackSegments -join [Environment]::NewLine).Trim())
    }

    $sanitized = ConvertTo-WeixinSessionLogText `
        -Text $rawText `
        -BrowserUrl $BrowserUrl `
        -BrowserOpened:$BrowserOpened `
        -BrowserOpenError $BrowserOpenError

    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return ''
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $sanitized + [Environment]::NewLine, $utf8NoBom)
    return $sanitized
}

function Test-WeixinSetupSessionSuccessText {
    param([AllowNull()][string]$Text)

    $normalized = ConvertTo-HermesText -Value $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    return (
        $normalized -match '微信连接成功' -or
        $normalized -match 'Weixin configured!' -or
        $normalized -match '(?m)^\s*Account ID:\s*\S+'
    )
}

function Get-WeixinVerificationMode {
    param(
        [AllowNull()]$BindingSnapshot,
        [bool]$SessionReportedSuccess = $false
    )

    if ($null -ne $BindingSnapshot) {
        if ($BindingSnapshot.AccountCount -gt 0) {
            return 'persisted'
        }
        if ($BindingSnapshot.HasAccountId -and $BindingSnapshot.HasToken) {
            return 'env-only'
        }
    }

    if ($SessionReportedSuccess) {
        return 'session-success-only'
    }

    return ''
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
    $tempBashPath = Join-Path $paths.StateRoot ("weixin-setup-{0}.sh" -f ([guid]::NewGuid().ToString()))
    $rawLogPath = Join-Path $paths.StateRoot ("weixin-setup-session-{0}.raw.log" -f ([guid]::NewGuid().ToString()))
    $windowLogPath = Join-Path $paths.StateRoot ("weixin-setup-session-{0}.log" -f ([guid]::NewGuid().ToString()))
    $stdoutCapturePath = Join-Path $paths.StateRoot ("weixin-setup-session-{0}.stdout.log" -f ([guid]::NewGuid().ToString()))
    $stderrCapturePath = Join-Path $paths.StateRoot ("weixin-setup-session-{0}.stderr.log" -f ([guid]::NewGuid().ToString()))
    $windowLogPathB64 = Convert-ToBase64 -Value $rawLogPath
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
printf '\nHermes 微信绑定即将开始。\n脚本会自动选择 Weixin。\n检测到腾讯 iLink 登录链接后，Windows 安装器会自动在默认浏览器中打开登录页面。\n请直接扫描浏览器里的二维码完成登录。\n绑定完成前不要关闭当前安装器。\n\n'
{
  printf '14\ny\n2\n1\n\n\n' | ~/.local/bin/hermes gateway setup
} 2>&1 | while IFS= read -r line; do
  printf '%s\n' "$line"
done
status=${PIPESTATUS[0]}
exit "$status"
'@
    $bashScript = $bashScript.Replace('__WINDOW_LOG_B64__', $windowLogPathB64)
    $bashScriptContent = ($bashScript -replace "`r`n", "`n") -replace "`r", ''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempBashPath, $bashScriptContent, $utf8NoBom)
    $tempBashPathInWsl = Convert-WindowsPathToWslMountPath -Path $tempBashPath

    try {
        $process = Start-Process `
            -FilePath 'wsl.exe' `
            -ArgumentList @('-d', $ResolvedConfig.DistroName, '-u', $ResolvedConfig.Username, '--', 'bash', $tempBashPathInWsl) `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutCapturePath `
            -RedirectStandardError $stderrCapturePath
        $bindingSnapshot = $null
        $bindingDetected = $false
        $sessionReportedSuccess = $false
        $browserUrl = ''
        $browserOpened = $false
        $browserOpenError = ''
        $nextProgressAt = Get-Date

        while ($true) {
            $process.Refresh()
            $sessionLogText = Get-TextFileContent -Path $rawLogPath
            if (-not $sessionReportedSuccess -and (Test-WeixinSetupSessionSuccessText -Text $sessionLogText)) {
                $sessionReportedSuccess = $true
                Write-Step 'Hermes 已报告 Weixin 绑定成功，正在等待账号凭据写入稳定。'
            }

            $bindingSnapshot = Get-WeixinBindingSnapshot -DistroName $ResolvedConfig.DistroName -Username $ResolvedConfig.Username
            if ($bindingSnapshot.IsConfigured) {
                $bindingDetected = $true
                break
            }

            if ([string]::IsNullOrWhiteSpace($browserUrl)) {
                $browserUrl = Get-WeixinLoginUrlFromText -Text $sessionLogText
                if (-not [string]::IsNullOrWhiteSpace($browserUrl)) {
                    try {
                        Start-Process $browserUrl | Out-Null
                        $browserOpened = $true
                        Write-Step '已在 Windows 默认浏览器中打开微信登录页面，请直接扫描浏览器里的二维码。'
                    }
                    catch {
                        $browserOpenError = $_.Exception.Message
                        Write-Step ("打开微信登录页面失败：{0}" -f $browserOpenError)
                        if (-not $process.HasExited) {
                            Stop-ProcessTree -ProcessId $process.Id
                            Start-Sleep -Seconds 2
                            $process.Refresh()
                        }
                        break
                    }
                }
            }

            if ($process.HasExited) {
                break
            }

            if ((Get-Date) -ge $nextProgressAt) {
                if ([string]::IsNullOrWhiteSpace($browserUrl)) {
                    Write-Step '正在等待 Hermes 生成 Weixin 浏览器登录链接。'
                }
                else {
                    Write-Step '正在等待用户在浏览器完成 Weixin 登录。'
                }
                $nextProgressAt = (Get-Date).AddSeconds(15)
            }

            Start-Sleep -Seconds 5
        }

        if ([string]::IsNullOrWhiteSpace($browserUrl)) {
            $browserUrl = Get-WeixinLoginUrlFromText -Text (Get-TextFileContent -Path $rawLogPath)
        }

        if (-not $sessionReportedSuccess) {
            $sessionReportedSuccess = Test-WeixinSetupSessionSuccessText -Text (Get-TextFileContent -Path $rawLogPath)
        }

        $processExitCode = $(if ($process.HasExited) { $process.ExitCode } else { -1 })

        if (-not $bindingDetected) {
            $bindingSnapshot = Get-WeixinBindingSnapshot -DistroName $ResolvedConfig.DistroName -Username $ResolvedConfig.Username
            $bindingDetected = $bindingSnapshot.IsConfigured
        }

        $shouldStabilizeBinding = (-not $bindingDetected) -and ($sessionReportedSuccess -or $processExitCode -eq 0)
        if ($shouldStabilizeBinding) {
            Write-Step '正在等待 Weixin 账号凭据写入稳定。'
            $stabilizeDeadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $stabilizeDeadline) {
                Start-Sleep -Seconds 5
                $bindingSnapshot = Get-WeixinBindingSnapshot -DistroName $ResolvedConfig.DistroName -Username $ResolvedConfig.Username
                if ($bindingSnapshot.IsConfigured) {
                    $bindingDetected = $true
                    break
                }
            }
        }

        if ($bindingDetected) {
            Write-Step '已检测到 Weixin 账号凭据写入，正在结束后台绑定会话并继续主流程。'
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

        $processExitCode = $(if ($process.HasExited) { $process.ExitCode } else { -1 })

        $sanitizedLog = Write-WeixinSessionLog `
            -OutputPath $windowLogPath `
            -RawLogPath $rawLogPath `
            -StdOutCapturePath $stdoutCapturePath `
            -StdErrCapturePath $stderrCapturePath `
            -BrowserUrl $browserUrl `
            -BrowserOpened:$browserOpened `
            -BrowserOpenError $browserOpenError
        $windowLogTail = Get-TextTail -Text $sanitizedLog -MaxChars 5000
        $verificationMode = Get-WeixinVerificationMode -BindingSnapshot $bindingSnapshot -SessionReportedSuccess:$sessionReportedSuccess
        return [PSCustomObject]@{
            ExitCode              = $processExitCode
            BindingDetected       = $bindingDetected
            SessionReportedSuccess = $sessionReportedSuccess
            VerificationMode      = $verificationMode
            AccountCount          = $(if ($null -ne $bindingSnapshot) { $bindingSnapshot.AccountCount } else { 0 })
            HasAccountId          = $(if ($null -ne $bindingSnapshot) { $bindingSnapshot.HasAccountId } else { $false })
            HasToken              = $(if ($null -ne $bindingSnapshot) { $bindingSnapshot.HasToken } else { $false })
            BrowserUrl            = $browserUrl
            BrowserOpened         = $browserOpened
            BrowserOpenError = $browserOpenError
            WindowLogPath         = $(if (Test-Path -LiteralPath $windowLogPath) { $windowLogPath } else { '' })
            WindowLogTail         = $windowLogTail
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempBashPath) {
            Remove-Item -LiteralPath $tempBashPath -Force
        }
        foreach ($path in @($rawLogPath, $stdoutCapturePath, $stderrCapturePath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
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
        $bindingSnapshot = Get-WeixinBindingSnapshot -DistroName $config.DistroName -Username $config.Username
        $accountCount = $bindingSnapshot.AccountCount
        $verificationMode = Get-WeixinVerificationMode -BindingSnapshot $bindingSnapshot
        Ensure-WeixinPostBindDefaults -ResolvedConfig $config
        Save-HermesState -Stage 'wechat-bound' -Config $config -Notes ("account_count={0}" -f $accountCount) -LastResult 'already-bound'
        if ($verificationMode -eq 'env-only') {
            $completed.Add('Detected an existing Weixin binding via ~/.hermes/.env credentials.')
        }
        else {
            $completed.Add(("Detected an existing Weixin binding with {0} stored account file(s)." -f $accountCount))
        }
        $completed.Add('Normalized the Weixin post-bind defaults so Hermes allows private messages and keeps group chats disabled.')

        return [PSCustomObject]@{
            Status           = 'already-bound'
            DistroName       = $config.DistroName
            Username         = $config.Username
            VerificationMode = $verificationMode
            AccountCount     = $accountCount
            HasAccountId     = $bindingSnapshot.HasAccountId
            HasToken         = $bindingSnapshot.HasToken
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
    $verificationMode = [string]$setupResult.VerificationMode
    $bindingSucceeded = @('persisted', 'env-only', 'session-success-only') -contains $verificationMode

    if ($bindingSucceeded) {
        Ensure-WeixinPostBindDefaults -ResolvedConfig $config
        $stateLastResult = if ($verificationMode -eq 'session-success-only') { 'wechat-session-success-only' } else { 'wechat-bound' }
        Save-HermesState -Stage 'wechat-bound' -Config $config -Notes ("account_count={0}" -f $accountCount) -LastResult $stateLastResult
        if ($verificationMode -eq 'session-success-only') {
            $completed.Add('Hermes 已报告原生 Weixin 扫码绑定成功，正在通过后续 gateway 启动继续确认凭据状态。')
        }
        elseif ($verificationMode -eq 'env-only') {
            $completed.Add('已完成原生 Weixin 扫码绑定，并检测到账号凭据已写入 ~/.hermes/.env。')
        }
        else {
            $completed.Add(("Stored {0} Weixin account file(s) under ~/.hermes/weixin/accounts." -f $accountCount))
        }
        $completed.Add('Normalized the Weixin post-bind defaults so Hermes allows private messages and keeps group chats disabled.')

        return [PSCustomObject]@{
            Status           = 'success'
            DistroName       = $config.DistroName
            Username         = $config.Username
            VerificationMode = $verificationMode
            SessionReportedSuccess = $setupResult.SessionReportedSuccess
            AccountCount     = $accountCount
            HasAccountId     = $setupResult.HasAccountId
            HasToken         = $setupResult.HasToken
            WindowLogPath = $setupResult.WindowLogPath
        }
    }

    $setupFailure = if ($setupResult.BrowserOpenError) {
        "The Weixin setup session could not continue because the browser login page failed to open. Exit code: $($setupResult.ExitCode)"
    }
    elseif ($setupResult.ExitCode -eq 0) {
        "The Weixin setup session exited without confirming that the binding completed. Exit code: $($setupResult.ExitCode)"
    }
    else {
        "The Weixin setup session failed before Hermes confirmed that the binding completed. Exit code: $($setupResult.ExitCode)"
    }
    if ($setupResult.BrowserOpenError) {
        $setupFailure = "$setupFailure`nBrowser open error: $($setupResult.BrowserOpenError)"
    }
    elseif ($setupResult.BrowserUrl) {
        $setupFailure = "$setupFailure`nWeixin browser login URL: $($setupResult.BrowserUrl)"
    }
    if ($setupResult.WindowLogTail) {
        $setupFailure = "$setupFailure`nWeixin setup session log tail:`n$($setupResult.WindowLogTail)"
    }
    $failureResult = if ($setupResult.BrowserOpenError) {
        'wechat-browser-open-failed'
    }
    elseif ($setupResult.ExitCode -eq 0) {
        'wechat-session-exit-without-confirmation'
    }
    else {
        "wechat-setup-exit=$($setupResult.ExitCode)"
    }
    Save-HermesState -Stage 'wechat-setup-failed' -Config $config -LastResult $failureResult
    return [PSCustomObject]@{
        Status        = 'failed'
        DistroName    = $config.DistroName
        Username      = $config.Username
        ExitCode      = $setupResult.ExitCode
        FailureSummary = $setupFailure
        BrowserUrl    = $setupResult.BrowserUrl
        BrowserOpened = $setupResult.BrowserOpened
        BrowserOpenError = $setupResult.BrowserOpenError
        LogTail       = $setupResult.WindowLogTail
        WindowLogPath = $setupResult.WindowLogPath
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'wechat-setup-failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
