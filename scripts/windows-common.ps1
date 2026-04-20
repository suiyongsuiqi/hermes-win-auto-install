Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HermesPaths {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $stateRoot = Join-Path $env:LOCALAPPDATA 'HermesBootstrap'
    [PSCustomObject]@{
        RepoRoot        = $repoRoot
        Downloads       = Join-Path $repoRoot 'downloads'
        InstallEnv      = Join-Path $repoRoot 'install.env'
        CloudInitDir    = Join-Path $env:USERPROFILE '.cloud-init'
        StateRoot       = $stateRoot
        StateFile       = Join-Path $stateRoot 'state.json'
        DistroRoot      = Join-Path $stateRoot 'distros'
        InstallerPs     = Join-Path $repoRoot 'scripts\windows-install-hermes.ps1'
        ReusePs         = Join-Path $repoRoot 'scripts\windows-reuse-existing.ps1'
        WebUiPs         = Join-Path $repoRoot 'scripts\windows-webui.ps1'
        LauncherBat     = Join-Path $repoRoot 'start-install.bat'
        PrefetchPs      = Join-Path $repoRoot 'scripts\windows-prefetch-assets.ps1'
        GatewayStartPs  = Join-Path $repoRoot 'scripts\windows-start-gateway.ps1'
        WeChatSetupPs   = Join-Path $repoRoot 'scripts\windows-configure-wechat.ps1'
        ResumeTaskName  = 'HermesBootstrapResume'
        ResumeValueName = 'HermesBootstrapResume'
        GatewayStartupValueName = 'HermesGatewayAutoStart'
    }
}

function Get-HermesDefaults {
    [PSCustomObject]@{
        DistroName         = 'Hermes-Ubuntu-24.04'
        Username           = 'hermes'
        PackageUrl         = 'https://releases.ubuntu.com/24.04/ubuntu-24.04.4-wsl-amd64.wsl'
        PackageName        = 'ubuntu-24.04.4-wsl-amd64.wsl'
        BaseImageName      = 'hermes-ubuntu-24.04-hermes-base.tar.xz'
        BaseImageAltName   = 'hermes-ubuntu-24.04-hermes-base.tar.gz'
        BaseImageMode      = 'prebuilt-base-image'
        InstallScriptUrl   = 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh'
        InstallScriptName  = 'hermes-install-main.sh'
        SourceArchiveUrl   = 'https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/heads/main'
        SourceArchiveName  = 'hermes-agent-main.tar.gz'
        AptPrimaryUrl      = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu'
        AptSecurityUrl     = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu'
        NodeMajorVersion   = '22'
        NodeDistMirrorUrl  = 'https://npmmirror.com/mirrors/node'
        NodeArchiveName    = 'node-v22-linux-x64.tar.xz'
        NpmRegistryUrl     = 'https://registry.npmmirror.com'
        BaseUrl            = 'https://api.qiuqiutoken.com/v1'
        Model              = 'gpt-5.4'
        ApiMode            = 'codex_responses'
        InstallMode        = 'dedicated'
        ProviderMode       = 'qiuqiu'
        MessagingMode      = 'wechat'
        WebUiVersion       = 'v0.50.76'
        WebUiArchiveName   = 'hermes-webui-v0.50.76.zip'
        WebUiUrl           = 'https://github.com/nesquena/hermes-webui/archive/refs/tags/v0.50.76.zip'
        WebUiPort          = 8788
    }
}

function Get-PreferredPowerShellExecutable {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh -and $pwsh.Version -and $pwsh.Version.Major -ge 7) {
        return $pwsh.Source
    }

    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($windowsPowerShell) {
        return $windowsPowerShell.Source
    }

    return $null
}

function Test-HermesAbsolutePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return [System.IO.Path]::IsPathRooted($Path)
}

function Get-CurrentInstallSessionLogPath {
    $path = [string]$env:HERMES_INSTALL_LOG_PATH
    if (Test-HermesAbsolutePath -Path $path) {
        return $path
    }

    return $null
}

function Get-CurrentInstallSessionId {
    $sessionId = [string]$env:HERMES_INSTALL_LOG_SESSION_ID
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        return $null
    }

    return $sessionId.Trim()
}

function New-HermesInstallLogSession {
    param(
        [string]$RequestedPath = '',
        [string]$RequestedSessionId = ''
    )

    $paths = Get-HermesPaths
    Ensure-Directory -Path $paths.StateRoot

    $finalLogPath = ''
    if (Test-HermesAbsolutePath -Path $RequestedPath) {
        $finalLogPath = $RequestedPath
    }
    else {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $baseName = "install-log-$timestamp"
        $finalLogPath = Join-Path $paths.RepoRoot "$baseName.log"
        $suffix = 1
        while (Test-Path -LiteralPath $finalLogPath) {
            $finalLogPath = Join-Path $paths.RepoRoot ("{0}-{1}.log" -f $baseName, $suffix)
            $suffix += 1
        }
    }

    $sessionId = if ([string]::IsNullOrWhiteSpace($RequestedSessionId)) {
        [guid]::NewGuid().ToString('N')
    }
    else {
        $RequestedSessionId.Trim()
    }

    return [PSCustomObject]@{
        SessionId    = $sessionId
        FinalLogPath = $finalLogPath
    }
}

function ConvertTo-HermesText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -eq $item) {
                continue
            }

            $parts.Add([string]$item) | Out-Null
        }

        if ($parts.Count -gt 0) {
            return ($parts -join [Environment]::NewLine)
        }
    }

    return [string]$Value
}

function ConvertTo-HermesTrimmedText {
    param([AllowNull()]$Value)
    return (ConvertTo-HermesText -Value $Value).Trim()
}

function Finalize-HermesInstallLogSession {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [string[]]$SupplementalLogPaths = @()
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $sections = New-Object System.Collections.Generic.List[string]

    foreach ($path in ($SupplementalLogPaths | Where-Object { Test-HermesAbsolutePath -Path $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $content = [System.IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($content)) {
            continue
        }

        $sections.Add(@(
            '',
            ('===== Supplemental Log: {0} =====' -f $path),
            $content.TrimEnd(),
            ('===== End Supplemental Log: {0} =====' -f $path)
        ) -join [Environment]::NewLine)
    }

    if ($sections.Count -eq 0) {
        return
    }

    $prefix = if (Test-Path -LiteralPath $Session.FinalLogPath) {
        [Environment]::NewLine + [Environment]::NewLine
    }
    else {
        ''
    }

    $finalContent = $prefix + ($sections -join ([Environment]::NewLine + [Environment]::NewLine)) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($Session.FinalLogPath, $finalContent, $utf8NoBom)
}

function Write-Step {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

function Write-Phase {
    param(
        [int]$Index,
        [int]$Total,
        [string]$Message
    )
    Write-Step ("[{0}/{1}] {2}" -f $Index, $Total, $Message)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-HermesBaseImageCandidates {
    $paths = Get-HermesPaths
    $defaults = Get-HermesDefaults
    return @(
        (Join-Path $paths.Downloads $defaults.BaseImageName),
        (Join-Path $paths.Downloads $defaults.BaseImageAltName)
    )
}

function Get-ExistingHermesBaseImagePath {
    foreach ($candidate in (Get-HermesBaseImageCandidates)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-HermesDistroInstallLocation {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $paths = Get-HermesPaths
    Ensure-Directory -Path $paths.DistroRoot
    return (Join-Path $paths.DistroRoot $DistroName)
}

function Convert-WindowsPathToWslMountPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^(?<drive>[A-Za-z]):\\') {
        throw "Cannot convert path to a WSL mount path: $Path"
    }

    $drive = $Matches['drive'].ToLowerInvariant()
    $suffix = $Path.Substring(3).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        return "/mnt/$drive"
    }

    return "/mnt/$drive/$suffix"
}

function Test-RebootPending {
    [PSCustomObject]@{
        CBSRebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WURebootRequired = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
}

function Ensure-WindowsFormsLoaded {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function Show-HermesResumeNotice {
    $state = Get-HermesState
    if ($null -eq $state) {
        return
    }

    if ([string]$state.stage -ne 'reboot-required') {
        return
    }

    Ensure-WindowsFormsLoaded

    $message = @(
        'Hermes 正在继续上次中断的安装流程。',
        '',
        '这是上次 Windows 重启后的自动恢复，不需要重新开始。',
        '安装器会从已保存的进度继续执行。'
    ) -join [Environment]::NewLine

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Hermes 正在继续安装',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-HermesRebootRequiredDialog {
    param(
        [string]$ResumeMethod = 'RunOnce'
    )

    Ensure-WindowsFormsLoaded

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '需要重启以继续安装'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(560, 290)
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.Size = New-Object System.Drawing.Size(500, 150)
    $label.Text = @(
        'Hermes 已完成 WSL 功能启用，Windows 现在必须重启后才能继续安装。',
        '',
        ("安装器已经注册一次性恢复入口（{0}）。" -f $ResumeMethod),
        '你重新登录 Windows 后，安装器会自动再次启动，并从当前进度继续执行。'
    ) -join [Environment]::NewLine
    $form.Controls.Add($label)

    $restartNowButton = New-Object System.Windows.Forms.Button
    $restartNowButton.Text = '立即重启'
    $restartNowButton.Location = New-Object System.Drawing.Point(290, 200)
    $restartNowButton.Size = New-Object System.Drawing.Size(100, 30)
    $form.Controls.Add($restartNowButton)

    $restartLaterButton = New-Object System.Windows.Forms.Button
    $restartLaterButton.Text = '稍后重启'
    $restartLaterButton.Location = New-Object System.Drawing.Point(405, 200)
    $restartLaterButton.Size = New-Object System.Drawing.Size(100, 30)
    $form.Controls.Add($restartLaterButton)

    $form.Tag = 'restart-later'

    $restartNowButton.Add_Click({
        $form.Tag = 'restart-now'
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $form.Close()
    })

    $restartLaterButton.Add_Click({
        $form.Tag = 'restart-later'
        $form.DialogResult = [System.Windows.Forms.DialogResult]::No
        $form.Close()
    })

    $form.AcceptButton = $restartLaterButton
    $form.CancelButton = $restartLaterButton
    $null = $form.ShowDialog()
    return [string]$form.Tag
}

function Invoke-WslUnicodeText {
    param([string]$Arguments)
    $tempPath = Join-Path $env:TEMP ("hermes-wsl-{0}.txt" -f ([guid]::NewGuid().ToString()))
    try {
        cmd /u /c "wsl $Arguments > `"$tempPath`" 2>&1" | Out-Null
        if (Test-Path -LiteralPath $tempPath) {
            $content = Get-Content -Raw -LiteralPath $tempPath -Encoding Unicode
            $normalized = (ConvertTo-HermesText -Value $content) -replace "`0", ''
            return (ConvertTo-HermesTrimmedText -Value $normalized)
        }
        return ''
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Get-WslStatusText {
    return Invoke-WslUnicodeText '--status'
}

function Get-WslHelpText {
    return Invoke-WslUnicodeText '--help'
}

function Get-WslQuietListText {
    return Invoke-WslUnicodeText '-l -q'
}

function Get-WslDistributions {
    try {
        return @(
            (Get-WslQuietListText -split "(`r`n|`n|`r)") |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )
    }
    catch {
        return @()
    }
}

function Get-WslVerboseListText {
    return Invoke-WslUnicodeText '-l -v'
}

function Get-WslVerboseEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    $lines = (ConvertTo-HermesText -Value (Get-WslVerboseListText)) -split "(`r`n|`n|`r)"

    foreach ($line in $lines) {
        $trimmed = (ConvertTo-HermesTrimmedText -Value $line)
        if (-not $trimmed) { continue }
        if ($trimmed -match '^NAME\s+STATE\s+VERSION$') { continue }

        $match = [regex]::Match($line, '^\s*(?<default>\*)?\s*(?<name>.+?)\s{2,}(?<state>\S+)\s+(?<version>\d+)\s*$')
        if (-not $match.Success) { continue }

        $entries.Add([PSCustomObject]@{
            IsDefault = $match.Groups['default'].Success
            Name      = $match.Groups['name'].Value.Trim()
            State     = $match.Groups['state'].Value.Trim()
            Version   = [int]$match.Groups['version'].Value
        })
    }

    return $entries.ToArray()
}

function Test-WslDistributionExists {
    param([string]$Name)
    return (Get-WslDistributions) -contains $Name
}

function Convert-ToCommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument -eq '') {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-CommandLineArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { Convert-ToCommandLineArgument -Argument $_ }) -join ' ')
}

function Invoke-WslProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$StandardInput = '',
        [int]$TimeoutSeconds = 30,
        [string]$ProgressMessage = '',
        [int]$ProgressIntervalSeconds = 15,
        [switch]$RequireSuccess
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = Join-CommandLineArguments -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $stdoutTask = $null
    $stderrTask = $null

    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if ($PSBoundParameters.ContainsKey('StandardInput') -and $StandardInput) {
            $process.StandardInput.Write($StandardInput)
        }
        $process.StandardInput.Close()

        $startedAt = Get-Date
        $nextProgressAt = $startedAt.AddSeconds($ProgressIntervalSeconds)

        while (-not $process.HasExited) {
            if ($process.WaitForExit(1000)) {
                break
            }

            if (((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                try {
                    $process.Kill()
                }
                catch {
                }

                try {
                    $process.WaitForExit()
                }
                catch {
                }

                if ($null -ne $stdoutTask) {
                    try {
                        $stdoutTask.Wait(5000) | Out-Null
                    }
                    catch {
                    }
                }
                if ($null -ne $stderrTask) {
                    try {
                        $stderrTask.Wait(5000) | Out-Null
                    }
                    catch {
                    }
                }

                $partialStdOut = if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) { ConvertTo-HermesTrimmedText -Value $stdoutTask.Result } else { '' }
                $partialStdErr = if ($null -ne $stderrTask -and $stderrTask.IsCompleted) { ConvertTo-HermesTrimmedText -Value $stderrTask.Result } else { '' }

                $partialText = @($partialStdOut, $partialStdErr) | Where-Object { $_ } | Out-String
                $partialText = (ConvertTo-HermesTrimmedText -Value $partialText)
                if ($partialText.Length -gt 2000) {
                    $partialText = $partialText.Substring([Math]::Max(0, $partialText.Length - 2000))
                }

                if ($partialText) {
                    throw "WSL command timed out after $TimeoutSeconds seconds: wsl.exe $($psi.Arguments)`nPartial output:`n$partialText"
                }

                throw "WSL command timed out after $TimeoutSeconds seconds: wsl.exe $($psi.Arguments)"
            }

            if ($ProgressMessage -and (Get-Date) -ge $nextProgressAt) {
                Write-Step $ProgressMessage
                $nextProgressAt = (Get-Date).AddSeconds($ProgressIntervalSeconds)
            }
        }

        $process.WaitForExit()
        $stdout = if ($null -ne $stdoutTask) { ConvertTo-HermesTrimmedText -Value ($stdoutTask.GetAwaiter().GetResult()) } else { '' }
        $stderr = if ($null -ne $stderrTask) { ConvertTo-HermesTrimmedText -Value ($stderrTask.GetAwaiter().GetResult()) } else { '' }
        $combined = @($stdout, $stderr) | Where-Object { $_ } | Out-String
        $text = (ConvertTo-HermesTrimmedText -Value $combined)

        if ($RequireSuccess -and $process.ExitCode -ne 0) {
            throw "WSL command failed with exit code $($process.ExitCode): wsl.exe $($psi.Arguments)`n$text"
        }

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Text     = $text
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-WslBash {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$User = 'root',
        [int]$TimeoutSeconds = 30,
        [string]$ProgressMessage = '',
        [int]$ProgressIntervalSeconds = 15,
        [switch]$RequireSuccess
    )

    $normalizedCommand = $Command -replace "`r`n", "`n"
    $normalizedCommand = $normalizedCommand -replace "`r", ''

    $result = Invoke-WslProcess `
        -Arguments @('-d', $Distro, '-u', $User, '--', 'bash', '-lc', $normalizedCommand) `
        -TimeoutSeconds $TimeoutSeconds `
        -ProgressMessage $ProgressMessage `
        -ProgressIntervalSeconds $ProgressIntervalSeconds `
        -RequireSuccess:$RequireSuccess

    return $result.Text
}

function Invoke-WslDirectCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [string[]]$Arguments = @(),
        [string]$User = 'root',
        [int]$TimeoutSeconds = 15,
        [string]$ProgressMessage = '',
        [int]$ProgressIntervalSeconds = 15,
        [switch]$RequireSuccess
    )

    $commandLine = @('-d', $Distro, '-u', $User, '--', $CommandPath) + $Arguments
    return Invoke-WslProcess `
        -Arguments $commandLine `
        -TimeoutSeconds $TimeoutSeconds `
        -ProgressMessage $ProgressMessage `
        -ProgressIntervalSeconds $ProgressIntervalSeconds `
        -RequireSuccess:$RequireSuccess
}

function Test-WslDistributionHealthy {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-WslDistributionExists -Name $Name)) {
        return $false
    }

    try {
        $probe = Invoke-WslDirectCommand -Distro $Name -User 'root' -CommandPath '/bin/echo' -Arguments @('ready') -TimeoutSeconds 15
        return $probe.StdOut -eq 'ready'
    }
    catch {
        return $false
    }
}

function Test-HermesManagedDistributionMarker {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [int]$TimeoutSeconds = 15
    )

    try {
        $probe = Invoke-WslDirectCommand `
            -Distro $DistroName `
            -User 'root' `
            -CommandPath '/usr/bin/test' `
            -Arguments @('-f', '/var/lib/hermes-bootstrap/config.env') `
            -TimeoutSeconds $TimeoutSeconds

        return $probe.ExitCode -eq 0
    }
    catch {
        return $false
    }
}

function Invoke-WslDefaultUserBash {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TimeoutSeconds = 30,
        [string]$ProgressMessage = '',
        [int]$ProgressIntervalSeconds = 15,
        [switch]$RequireSuccess
    )

    $normalizedCommand = $Command -replace "`r`n", "`n"
    $normalizedCommand = $normalizedCommand -replace "`r", ''

    $result = Invoke-WslProcess `
        -Arguments @('-d', $Distro, '--', 'bash', '-lc', $normalizedCommand) `
        -TimeoutSeconds $TimeoutSeconds `
        -ProgressMessage $ProgressMessage `
        -ProgressIntervalSeconds $ProgressIntervalSeconds `
        -RequireSuccess:$RequireSuccess

    return $result.Text
}

function Get-WslDefaultUserName {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    try {
        $text = Invoke-WslDefaultUserBash -Distro $DistroName -Command 'id -un' -TimeoutSeconds 20 -RequireSuccess
        return $text.Trim()
    }
    catch {
        return ''
    }
}

function Get-WslOsReleaseInfo {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $command = @'
set -euo pipefail
if [ ! -f /etc/os-release ]; then
  exit 1
fi
. /etc/os-release
printf 'id=%s\n' "${ID:-}"
printf 'pretty_name=%s\n' "${PRETTY_NAME:-}"
printf 'version_id=%s\n' "${VERSION_ID:-}"
if command -v apt-get >/dev/null 2>&1; then
  printf 'apt=true\n'
else
  printf 'apt=false\n'
fi
'@

    try {
        $text = Invoke-WslBash -Distro $DistroName -User 'root' -Command $command -TimeoutSeconds 20 -RequireSuccess
        $pairs = Read-KeyValueText -Text $text
        return [PSCustomObject]@{
            Id         = if ($pairs.Contains('id')) { [string]$pairs['id'] } else { '' }
            PrettyName = if ($pairs.Contains('pretty_name')) { [string]$pairs['pretty_name'] } else { '' }
            VersionId  = if ($pairs.Contains('version_id')) { [string]$pairs['version_id'] } else { '' }
            HasApt     = if ($pairs.Contains('apt')) { ([string]$pairs['apt']) -eq 'true' } else { $false }
        }
    }
    catch {
        return [PSCustomObject]@{
            Id         = ''
            PrettyName = ''
            VersionId  = ''
            HasApt     = $false
        }
    }
}

function Get-WslReuseCandidates {
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($entry in (Get-WslVerboseEntries)) {
        if ($entry.Version -ne 2) {
            continue
        }

        $osInfo = Get-WslOsReleaseInfo -DistroName $entry.Name
        if (-not $osInfo.HasApt) {
            continue
        }

        if ($osInfo.Id -notin @('ubuntu', 'debian')) {
            continue
        }

        $defaultUser = Get-WslDefaultUserName -DistroName $entry.Name
        if ([string]::IsNullOrWhiteSpace($defaultUser) -or $defaultUser -eq 'root') {
            continue
        }

        $candidates.Add([PSCustomObject]@{
            DistroName  = $entry.Name
            State       = $entry.State
            Version     = $entry.Version
            OsId        = $osInfo.Id
            PrettyName  = $osInfo.PrettyName
            VersionId   = $osInfo.VersionId
            DefaultUser = $defaultUser
        })
    }

    return $candidates.ToArray()
}

function Read-KeyValueText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $result = [ordered]@{}
    foreach ($line in ($Text -split "(`r`n|`n|`r)")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $pair = $trimmed -split '=', 2
        if ($pair.Count -ne 2) { continue }
        $result[$pair[0].Trim()] = $pair[1].Trim()
    }

    return $result
}

function Get-HermesWebUiInstallRoot {
    $paths = Get-HermesPaths
    return (Join-Path $paths.StateRoot 'webui')
}

function Get-HermesWebUiArchivePath {
    param([Parameter(Mandatory = $true)]$Config)
    return (Join-Path (Get-HermesPaths).Downloads $Config.WebUiArchiveName)
}

function Get-HermesWebUiInstallPath {
    param([Parameter(Mandatory = $true)]$Config)
    return (Join-Path (Get-HermesWebUiInstallRoot) $Config.WebUiVersion)
}

function Read-KeyValueFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $pair = $trimmed -split '=', 2
        if ($pair.Count -ne 2) {
            throw "Unable to parse config line: $line"
        }
        $key = $pair[0].Trim()
        $value = $pair[1].Trim()
        $result[$key] = $value
    }
    return $result
}

function Test-AbsoluteHttpUrl {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if (-not [Uri]::IsWellFormedUriString($Value, [UriKind]::Absolute)) { return $false }
    $uri = [Uri]$Value
    return $uri.Scheme -in @('http', 'https')
}

function Normalize-AbsoluteHttpUrl {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed.Length -gt 1) {
        return $trimmed.TrimEnd('/')
    }

    return $trimmed
}

function Get-NodeLinuxAssetSpec {
    param([Parameter(Mandatory = $true)]$Config)

    $mirrorRoot = $Config.NodeDistMirrorUrl.TrimEnd('/')
    $majorVersion = [string]$Config.NodeMajorVersion
    $manifestUrl = ('{0}/latest-v{1}.x/SHASUMS256.txt' -f $mirrorRoot, $majorVersion)
    $manifestResponse = Invoke-WebRequest -UseBasicParsing -Uri $manifestUrl
    $manifestText = [string]$manifestResponse.Content

    $xzMatch = [regex]::Match($manifestText, ('node-v{0}\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz' -f [regex]::Escape($majorVersion)))
    $archiveName = if ($xzMatch.Success) {
        $xzMatch.Value
    }
    else {
        $gzMatch = [regex]::Match($manifestText, ('node-v{0}\.[0-9]+\.[0-9]+-linux-x64\.tar\.gz' -f [regex]::Escape($majorVersion)))
        if (-not $gzMatch.Success) {
            throw "Could not resolve a Linux x64 Node.js v$majorVersion archive from $manifestUrl"
        }

        $gzMatch.Value
    }

    return [PSCustomObject]@{
        ManifestUrl = $manifestUrl
        ArchiveName = $archiveName
        Url         = ('{0}/latest-v{1}.x/{2}' -f $mirrorRoot, $majorVersion, $archiveName)
        LocalName   = $Config.NodeArchiveName
        LocalPath   = Join-Path (Get-HermesPaths).Downloads $Config.NodeArchiveName
    }
}

function Get-ResolvedInstallConfig {
    $defaults = Get-HermesDefaults
    $paths = Get-HermesPaths
    $state = Get-HermesState
    $stateMatchesRepo = ($null -ne $state -and [string]$state.repo_root -eq $paths.RepoRoot)
    $raw = [ordered]@{}
    $ignored = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $paths.InstallEnv) {
        $raw = Read-KeyValueFile -Path $paths.InstallEnv
        foreach ($key in @('WSL_PASSWORD', 'LLM_API_KEY')) {
            if ($raw.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$raw[$key])) {
                $ignored.Add($key)
            }
        }
    }

    $installMode = if ($stateMatchesRepo -and $state.install_mode) {
        ([string]$state.install_mode).Trim().ToLowerInvariant()
    }
    else {
        $defaults.InstallMode
    }
    if ($installMode -notin @('dedicated', 'reuse-existing')) {
        $installMode = $defaults.InstallMode
    }

    $providerMode = if ($stateMatchesRepo -and $state.provider_mode) {
        ([string]$state.provider_mode).Trim().ToLowerInvariant()
    }
    else {
        $defaults.ProviderMode
    }
    if ($providerMode -notin @('qiuqiu', 'custom-openai')) {
        $providerMode = $defaults.ProviderMode
    }

    $selectedDistro = if ($stateMatchesRepo -and $state.selected_distro) {
        [string]$state.selected_distro
    }
    else {
        ''
    }

    $selectedUser = if ($stateMatchesRepo -and $state.selected_user) {
        [string]$state.selected_user
    }
    else {
        ''
    }

    $distroName = if (-not [string]::IsNullOrWhiteSpace($selectedDistro)) {
        $selectedDistro
    }
    elseif ($raw.Contains('WSL_DISTRO_NAME') -and -not [string]::IsNullOrWhiteSpace([string]$raw['WSL_DISTRO_NAME'])) {
        [string]$raw['WSL_DISTRO_NAME']
    }
    else {
        $defaults.DistroName
    }

    $username = if (-not [string]::IsNullOrWhiteSpace($selectedUser)) {
        $selectedUser
    }
    elseif ($raw.Contains('WSL_USERNAME') -and -not [string]::IsNullOrWhiteSpace([string]$raw['WSL_USERNAME'])) {
        [string]$raw['WSL_USERNAME']
    }
    else {
        $defaults.Username
    }

    $baseUrl = if ($stateMatchesRepo -and $state.base_url) {
        [string]$state.base_url
    }
    elseif ($raw.Contains('LLM_BASE_URL') -and -not [string]::IsNullOrWhiteSpace([string]$raw['LLM_BASE_URL'])) {
        [string]$raw['LLM_BASE_URL']
    }
    else {
        $defaults.BaseUrl
    }

    $model = if ($stateMatchesRepo -and $state.model) {
        [string]$state.model
    }
    elseif ($raw.Contains('LLM_MODEL') -and -not [string]::IsNullOrWhiteSpace([string]$raw['LLM_MODEL'])) {
        [string]$raw['LLM_MODEL']
    }
    else {
        $defaults.Model
    }

    $apiMode = if ($stateMatchesRepo -and $state.api_mode) {
        ([string]$state.api_mode).Trim().ToLowerInvariant()
    }
    elseif ($raw.Contains('LLM_API_MODE') -and -not [string]::IsNullOrWhiteSpace([string]$raw['LLM_API_MODE'])) {
        ([string]$raw['LLM_API_MODE']).Trim().ToLowerInvariant()
    }
    else {
        $defaults.ApiMode
    }

    $aptPrimaryUrl = if ($raw.Contains('UBUNTU_APT_PRIMARY_URL') -and -not [string]::IsNullOrWhiteSpace([string]$raw['UBUNTU_APT_PRIMARY_URL'])) {
        [string]$raw['UBUNTU_APT_PRIMARY_URL']
    }
    else {
        $defaults.AptPrimaryUrl
    }

    $aptSecurityUrl = if ($raw.Contains('UBUNTU_APT_SECURITY_URL') -and -not [string]::IsNullOrWhiteSpace([string]$raw['UBUNTU_APT_SECURITY_URL'])) {
        [string]$raw['UBUNTU_APT_SECURITY_URL']
    }
    else {
        $defaults.AptSecurityUrl
    }

    $nodeDistMirrorUrl = if ($raw.Contains('NODE_DIST_MIRROR_URL') -and -not [string]::IsNullOrWhiteSpace([string]$raw['NODE_DIST_MIRROR_URL'])) {
        [string]$raw['NODE_DIST_MIRROR_URL']
    }
    else {
        $defaults.NodeDistMirrorUrl
    }

    $npmRegistryUrl = if ($raw.Contains('NPM_REGISTRY_URL') -and -not [string]::IsNullOrWhiteSpace([string]$raw['NPM_REGISTRY_URL'])) {
        [string]$raw['NPM_REGISTRY_URL']
    }
    else {
        $defaults.NpmRegistryUrl
    }

    if ($username -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw 'WSL username must start with a lowercase letter or underscore and only contain lowercase letters, digits, underscores, or dashes.'
    }

    if (-not (Test-AbsoluteHttpUrl -Value $baseUrl)) {
        throw 'LLM_BASE_URL must be a full http/https URL.'
    }

    if ([string]::IsNullOrWhiteSpace($model)) {
        throw 'LLM_MODEL cannot be empty.'
    }

    $validApiModes = @('chat_completions', 'codex_responses', 'anthropic_messages', 'bedrock_converse')
    if ($validApiModes -notcontains $apiMode) {
        throw ("LLM_API_MODE must be one of: {0}." -f ($validApiModes -join ', '))
    }

    if (-not (Test-AbsoluteHttpUrl -Value $aptPrimaryUrl)) {
        throw 'UBUNTU_APT_PRIMARY_URL must be a full http/https URL.'
    }

    if (-not (Test-AbsoluteHttpUrl -Value $aptSecurityUrl)) {
        throw 'UBUNTU_APT_SECURITY_URL must be a full http/https URL.'
    }

    if (-not (Test-AbsoluteHttpUrl -Value $nodeDistMirrorUrl)) {
        throw 'NODE_DIST_MIRROR_URL must be a full http/https URL.'
    }

    if (-not (Test-AbsoluteHttpUrl -Value $npmRegistryUrl)) {
        throw 'NPM_REGISTRY_URL must be a full http/https URL.'
    }

    $aptPrimaryUrl = Normalize-AbsoluteHttpUrl -Value $aptPrimaryUrl
    $aptSecurityUrl = Normalize-AbsoluteHttpUrl -Value $aptSecurityUrl
    $nodeDistMirrorUrl = Normalize-AbsoluteHttpUrl -Value $nodeDistMirrorUrl
    $npmRegistryUrl = Normalize-AbsoluteHttpUrl -Value $npmRegistryUrl

    $targetKind = if ($installMode -eq 'reuse-existing') { 'existing-distro' } else { 'managed-distro' }
    $messagingMode = if ($stateMatchesRepo -and $state.messaging_mode) {
        ([string]$state.messaging_mode).Trim().ToLowerInvariant()
    }
    else {
        $defaults.MessagingMode
    }
    $reuseSourceDistro = if ($stateMatchesRepo -and $state.reuse_source_distro) {
        [string]$state.reuse_source_distro
    }
    elseif ($installMode -eq 'reuse-existing') {
        $distroName
    }
    else {
        ''
    }

    return [PSCustomObject]@{
        DistroName        = $distroName
        Username          = $username
        BaseUrl           = $baseUrl
        Model             = $model
        ApiMode           = $apiMode
        InstallMode       = $installMode
        TargetKind        = $targetKind
        ProviderMode      = $providerMode
        MessagingMode     = $messagingMode
        SelectedDistro    = $distroName
        SelectedUser      = $username
        ReuseSourceDistro = $reuseSourceDistro
        AptPrimaryUrl     = $aptPrimaryUrl
        AptSecurityUrl    = $aptSecurityUrl
        NodeMajorVersion  = $defaults.NodeMajorVersion
        NodeDistMirrorUrl = $nodeDistMirrorUrl
        NodeArchiveName   = $defaults.NodeArchiveName
        NpmRegistryUrl    = $npmRegistryUrl
        WebUiVersion      = $defaults.WebUiVersion
        WebUiArchiveName  = $defaults.WebUiArchiveName
        WebUiUrl          = $defaults.WebUiUrl
        WebUiPort         = $defaults.WebUiPort
        PackageUrl        = $defaults.PackageUrl
        PackageName       = $defaults.PackageName
        BaseImageName     = $defaults.BaseImageName
        BaseImageAltName  = $defaults.BaseImageAltName
        BaseImageMode     = $defaults.BaseImageMode
        InstallScriptUrl  = $defaults.InstallScriptUrl
        InstallScriptName = $defaults.InstallScriptName
        SourceArchiveUrl  = $defaults.SourceArchiveUrl
        SourceArchiveName = $defaults.SourceArchiveName
        InstallEnvPresent = (Test-Path -LiteralPath $paths.InstallEnv)
        IgnoredKeys       = $ignored.ToArray()
    }
}

function Get-FileSha256OrNull {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $getFileHash = Get-Command Get-FileHash -ErrorAction SilentlyContinue
    if ($getFileHash) {
        try {
            return (Microsoft.PowerShell.Utility\Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        }
        catch {
        }
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-RemoteFileMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutMilliseconds = 20000
    )

    $methods = @('HEAD', 'GET')
    $lastError = $null

    foreach ($method in $methods) {
        $request = $null
        $response = $null

        try {
            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.Method = $method
            $request.Timeout = $TimeoutMilliseconds
            $request.ReadWriteTimeout = $TimeoutMilliseconds
            $request.AllowAutoRedirect = $true
            $request.AutomaticDecompression = [System.Net.DecompressionMethods]::None

            if ($method -eq 'GET') {
                $request.AddRange(0, 0)
            }

            $response = [System.Net.HttpWebResponse]$request.GetResponse()
            $contentLength = [int64]$response.ContentLength
            if ($contentLength -lt 0) {
                $contentRange = [string]$response.Headers['Content-Range']
                if ($contentRange -match '/(?<total>\d+)$') {
                    $contentLength = [int64]$Matches['total']
                }
                else {
                    $headerLength = [string]$response.Headers['Content-Length']
                    if ($headerLength -match '^\d+$') {
                        $contentLength = [int64]$headerLength
                    }
                }
            }

            return [PSCustomObject]@{
                StatusCode    = [int]$response.StatusCode
                ContentLength = $contentLength
                LastModified  = [string]$response.Headers['Last-Modified']
            }
        }
        catch {
            $lastError = $_
        }
        finally {
            if ($response) {
                $response.Dispose()
            }
        }
    }

    throw $lastError
}

function Try-GetRemoteFileMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutMilliseconds = 20000
    )

    try {
        return [PSCustomObject]@{
            Success  = $true
            Metadata = (Get-RemoteFileMetadata -Uri $Uri -TimeoutMilliseconds $TimeoutMilliseconds)
            Error    = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            Success  = $false
            Metadata = $null
            Error    = $_.Exception.Message
        }
    }
}

function Format-ByteSize {
    param([double]$Bytes)

    if ($Bytes -lt 0) {
        return 'unknown'
    }

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $size = [double]$Bytes
    $unitIndex = 0

    while ($size -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $size = $size / 1024
        $unitIndex += 1
    }

    if ($unitIndex -eq 0) {
        return ('{0:N0} {1}' -f $size, $units[$unitIndex])
    }

    return ('{0:N1} {1}' -f $size, $units[$unitIndex])
}

function Format-Duration {
    param([double]$TotalSeconds)

    if ([double]::IsNaN($TotalSeconds) -or [double]::IsInfinity($TotalSeconds) -or $TotalSeconds -lt 0) {
        return '未知'
    }

    $span = [TimeSpan]::FromSeconds([Math]::Round($TotalSeconds))
    if ($span.TotalHours -ge 1) {
        return ('{0}小时 {1}分 {2}秒' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
    }

    if ($span.TotalMinutes -ge 1) {
        return ('{0}分 {1}秒' -f $span.Minutes, $span.Seconds)
    }

    return ('{0}秒' -f [Math]::Max($span.Seconds, 0))
}

function Get-DownloadProgressText {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int64]$DownloadedBytes,
        [Parameter(Mandatory = $true)][double]$BytesPerSecond,
        [int64]$TotalBytes = 0
    )

    $speedText = if ($BytesPerSecond -gt 0) {
        '{0}/s' -f (Format-ByteSize -Bytes $BytesPerSecond)
    }
    else {
        '计算中'
    }

    if ($TotalBytes -gt 0) {
        $percentComplete = [Math]::Min(100.0, (($DownloadedBytes * 100.0) / $TotalBytes))
        $remainingBytes = [Math]::Max(($TotalBytes - $DownloadedBytes), 0)
        $etaSeconds = if ($BytesPerSecond -gt 0) { $remainingBytes / $BytesPerSecond } else { -1 }

        return ('{0}：已下载 {1} / {2}（{3:N1}%）。速度 {4}。预计剩余 {5}。' -f `
            $Label,
            (Format-ByteSize -Bytes $DownloadedBytes),
            (Format-ByteSize -Bytes $TotalBytes),
            $percentComplete,
            $speedText,
            (Format-Duration -TotalSeconds $etaSeconds))
    }

    return ('{0}：已下载 {1}。速度 {2}。' -f `
        $Label,
        (Format-ByteSize -Bytes $DownloadedBytes),
        $speedText)
}

function Download-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$Activity = 'Downloading file',
        [string]$StatusLabel = 'Download',
        [int64]$TotalBytesHint = 0,
        [scriptblock]$Heartbeat
    )

    $buffer = New-Object byte[] (1024 * 1024)
    $progressId = [Math]::Abs($OutputPath.GetHashCode())
    $request = $null
    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        Ensure-Directory -Path (Split-Path -Parent $OutputPath)
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = 300000
        $request.ReadWriteTimeout = 300000
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::None
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)

        $totalBytes = if ($TotalBytesHint -gt 0) {
            $TotalBytesHint
        }
        elseif ($response.ContentLength -gt 0) {
            [int64]$response.ContentLength
        }
        else {
            0
        }

        [int64]$downloadedBytes = 0
        $startedAt = Get-Date
        $lastUiUpdate = [datetime]::MinValue
        $lastHeartbeat = $startedAt

        Write-Step ("开始流式下载：{0}" -f $Uri)

        while ($true) {
            $read = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }

            $outputStream.Write($buffer, 0, $read)
            $outputStream.Flush()
            $downloadedBytes += [int64]$read

            $now = Get-Date
            $elapsedSeconds = [Math]::Max((($now - $startedAt).TotalSeconds), 0.001)
            $bytesPerSecond = $downloadedBytes / $elapsedSeconds
            $statusText = Get-DownloadProgressText -Label $StatusLabel -DownloadedBytes $downloadedBytes -TotalBytes $totalBytes -BytesPerSecond $bytesPerSecond

            if (($now - $lastUiUpdate).TotalSeconds -ge 1) {
                $percentForBar = if ($totalBytes -gt 0) {
                    [int][Math]::Min(100, [Math]::Floor(($downloadedBytes * 100.0) / $totalBytes))
                }
                else {
                    0
                }

                Write-Progress -Id $progressId -Activity $Activity -Status $statusText -PercentComplete $percentForBar
                $lastUiUpdate = $now
            }

            if (($now - $lastHeartbeat).TotalSeconds -ge 15) {
                Write-Step $statusText
                if ($Heartbeat) {
                    & $Heartbeat $downloadedBytes $totalBytes $bytesPerSecond $statusText
                }
                $lastHeartbeat = $now
            }
        }

        $outputStream.Flush()
        $completedAt = Get-Date
        $totalElapsedSeconds = [Math]::Max((($completedAt - $startedAt).TotalSeconds), 0.001)
        $finalBytesPerSecond = $downloadedBytes / $totalElapsedSeconds
        $finalStatusText = Get-DownloadProgressText -Label $StatusLabel -DownloadedBytes $downloadedBytes -TotalBytes $totalBytes -BytesPerSecond $finalBytesPerSecond

        Write-Progress -Id $progressId -Activity $Activity -Status $finalStatusText -Completed
        Write-Step $finalStatusText

        if ($Heartbeat) {
            & $Heartbeat $downloadedBytes $totalBytes $finalBytesPerSecond $finalStatusText
        }
    }
    catch {
        Write-Progress -Id $progressId -Activity $Activity -Completed
        throw
    }
    finally {
        if ($outputStream) {
            $outputStream.Dispose()
        }
        if ($responseStream) {
            $responseStream.Dispose()
        }
        if ($response) {
            $response.Dispose()
        }
        Write-Progress -Id $progressId -Activity $Activity -Completed
    }
}

function Convert-ToBase64 {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Convert-FromUtf8Base64 {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Get-HermesState {
    $paths = Get-HermesPaths
    if (-not (Test-Path -LiteralPath $paths.StateFile)) {
        return $null
    }

    return Get-Content -LiteralPath $paths.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-HermesStateMatchesConfig {
    param(
        $State,
        [Parameter(Mandatory = $true)]$Config
    )

    if ($null -eq $State) { return $false }
    if (-not $State.distro_name -or -not $State.repo_root) { return $false }
    if ([string]$State.distro_name -ne $Config.DistroName) { return $false }
    if ([string]$State.repo_root -ne (Get-HermesPaths).RepoRoot) { return $false }
    return $true
}

function Get-WslEnvironmentClassification {
    param([Parameter(Mandatory = $true)]$Config)

    $paths = Get-HermesPaths
    $state = Get-HermesState
    $entries = @(Get-WslVerboseEntries)
    $distros = @($entries | ForEach-Object { $_.Name })
    $targetEntries = @($entries | Where-Object { $_.Name -eq $Config.DistroName })
    $stateMatches = Test-HermesStateMatchesConfig -State $state -Config $Config
    $stateStage = if ($null -ne $state -and $state.stage) { [string]$state.stage } else { 'none' }
    $hasVersionOne = @($entries | Where-Object { $_.Version -eq 1 }).Count -gt 0
    $statusText = Get-WslStatusText
    $wslFeatureEnabled = if ($statusText) { 'likely' } else { 'unknown' }
    $vmpFeatureEnabled = if ($statusText) { 'likely' } else { 'unknown' }
    $installMode = if ($Config.PSObject.Properties.Name -contains 'InstallMode' -and $Config.InstallMode) {
        [string]$Config.InstallMode
    }
    else {
        'dedicated'
    }
    $managedMarkerPresent = $false
    if ($targetEntries.Count -eq 1) {
        $managedMarkerPresent = Test-HermesManagedDistributionMarker -DistroName $Config.DistroName
    }

    if ($installMode -eq 'reuse-existing') {
        if ($entries.Count -eq 0) {
            $classification = 'no-existing-distro'
            $summary = 'No existing WSL distribution is available for reuse.'
        }
        elseif ($targetEntries.Count -eq 0) {
            $classification = 'selected-distro-missing'
            $summary = "The selected distribution $($Config.DistroName) was not found."
        }
        elseif ($targetEntries[0].Version -ne 2) {
            $classification = 'selected-distro-wsl1'
            $summary = "The selected distribution $($Config.DistroName) is not using WSL 2."
        }
        elseif ($stateMatches -and $managedMarkerPresent -and $stateStage -eq 'success') {
            $classification = 'managed-installed'
            $summary = "The selected distribution $($Config.DistroName) already contains a completed Hermes-managed installation."
        }
        elseif ($managedMarkerPresent) {
            $classification = 'resume-hermes'
            $summary = "The selected distribution $($Config.DistroName) already contains Hermes markers and can be resumed or repaired."
        }
        else {
            $classification = 'selected-existing-distro'
            $summary = "The selected distribution $($Config.DistroName) is available for reuse."
        }
    }
    elseif ($entries.Count -eq 0) {
        $classification = if ($statusText) { 'platform-only' } else { 'fresh' }
        $summary = if ($classification -eq 'platform-only') {
            'WSL platform components are present, but there are no registered distributions.'
        }
        else {
            'No registered WSL distributions were found.'
        }
    }
    elseif ($managedMarkerPresent -and $stateStage -eq 'success') {
        $classification = 'managed-installed'
        $summary = "The dedicated Hermes distribution $($Config.DistroName) is already present and marked successful."
    }
    elseif ($managedMarkerPresent) {
        $classification = 'resume-hermes'
        $summary = "The dedicated Hermes distribution $($Config.DistroName) is already present and can be resumed or repaired."
    }
    elseif ($targetEntries.Count -gt 0) {
        $classification = 'target-name-conflict'
        $summary = "A distribution named $($Config.DistroName) already exists, but it is not marked as Hermes-managed."
    }
    elseif ($hasVersionOne) {
        $classification = 'foreign-compatible'
        $summary = 'Existing WSL distributions are present, including WSL 1 entries. The installer will ignore them and create or reuse the dedicated Hermes distribution.'
    }
    else {
        $classification = 'foreign-compatible'
        $summary = 'One or more existing WSL distributions are already registered on this machine. The installer will ignore them and create or reuse the dedicated Hermes distribution.'
    }

    return [PSCustomObject]@{
        Classification      = $classification
        Summary             = $summary
        Entries             = $entries
        DistributionNames   = $distros
        StateStage          = $stateStage
        StateMatchesConfig  = $stateMatches
        ManagedMarkerPresent = $managedMarkerPresent
        HasVersionOne       = $hasVersionOne
        WslFeatureEnabled   = $wslFeatureEnabled
        VmpFeatureEnabled   = $vmpFeatureEnabled
        StateFilePresent    = Test-Path -LiteralPath $paths.StateFile
    }
}

function Save-HermesState {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)]$Config,
        [string]$ResumeMethod = '',
        [string]$Notes = '',
        [string]$LastResult = ''
    )

    $paths = Get-HermesPaths
    Ensure-Directory -Path $paths.StateRoot

    $payload = [ordered]@{
        stage         = $Stage
        updated_at    = (Get-Date).ToString('o')
        repo_root     = $paths.RepoRoot
        distro_name   = $Config.DistroName
        username      = $Config.Username
        install_mode  = $(if ($Config.PSObject.Properties.Name -contains 'InstallMode') { $Config.InstallMode } else { '' })
        target_kind   = $(if ($Config.PSObject.Properties.Name -contains 'TargetKind') { $Config.TargetKind } else { '' })
        selected_distro = $(if ($Config.PSObject.Properties.Name -contains 'SelectedDistro') { $Config.SelectedDistro } else { $Config.DistroName })
        selected_user = $(if ($Config.PSObject.Properties.Name -contains 'SelectedUser') { $Config.SelectedUser } else { $Config.Username })
        reuse_source_distro = $(if ($Config.PSObject.Properties.Name -contains 'ReuseSourceDistro') { $Config.ReuseSourceDistro } else { '' })
        provider_mode = $(if ($Config.PSObject.Properties.Name -contains 'ProviderMode') { $Config.ProviderMode } else { '' })
        messaging_mode = $(if ($Config.PSObject.Properties.Name -contains 'MessagingMode') { $Config.MessagingMode } else { '' })
        base_url      = $Config.BaseUrl
        model         = $Config.Model
        api_mode      = $(if ($Config.PSObject.Properties.Name -contains 'ApiMode') { $Config.ApiMode } else { '' })
        package_name  = $Config.PackageName
        package_url   = $Config.PackageUrl
        base_image_name = $(if ($Config.PSObject.Properties.Name -contains 'BaseImageName') { $Config.BaseImageName } else { '' })
        install_script_name = $(if ($Config.PSObject.Properties.Name -contains 'InstallScriptName') { $Config.InstallScriptName } else { '' })
        source_archive_name = $(if ($Config.PSObject.Properties.Name -contains 'SourceArchiveName') { $Config.SourceArchiveName } else { '' })
        apt_primary_url = $(if ($Config.PSObject.Properties.Name -contains 'AptPrimaryUrl') { $Config.AptPrimaryUrl } else { '' })
        apt_security_url = $(if ($Config.PSObject.Properties.Name -contains 'AptSecurityUrl') { $Config.AptSecurityUrl } else { '' })
        node_dist_mirror_url = $(if ($Config.PSObject.Properties.Name -contains 'NodeDistMirrorUrl') { $Config.NodeDistMirrorUrl } else { '' })
        node_archive_name = $(if ($Config.PSObject.Properties.Name -contains 'NodeArchiveName') { $Config.NodeArchiveName } else { '' })
        npm_registry_url = $(if ($Config.PSObject.Properties.Name -contains 'NpmRegistryUrl') { $Config.NpmRegistryUrl } else { '' })
        webui_version = $(if ($Config.PSObject.Properties.Name -contains 'WebUiVersion') { $Config.WebUiVersion } else { '' })
        webui_port    = $(if ($Config.PSObject.Properties.Name -contains 'WebUiPort') { $Config.WebUiPort } else { '' })
        resume_method = $ResumeMethod
        install_log_path = $(Get-CurrentInstallSessionLogPath)
        install_log_session_id = $(Get-CurrentInstallSessionId)
        notes         = $Notes
        last_result   = $LastResult
    }

    $json = $payload | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $paths.StateFile -Value $json -Encoding UTF8
}

function Clear-HermesState {
    $paths = Get-HermesPaths
    if (Test-Path -LiteralPath $paths.StateFile) {
        Remove-Item -LiteralPath $paths.StateFile -Force
    }
}

function Get-ResumeCommandLine {
    $paths = Get-HermesPaths
    $shellPath = Get-PreferredPowerShellExecutable
    if (-not $shellPath) {
        throw '找不到可用于恢复安装的 pwsh.exe 或 powershell.exe。'
    }

    $arguments = @(
        '-NoLogo',
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $paths.InstallerPs,
        '-Resume'
    )

    $logPath = Get-CurrentInstallSessionLogPath
    if (Test-HermesAbsolutePath -Path $logPath) {
        $arguments += @('-InstallLogPath', $logPath)
    }

    $sessionId = Get-CurrentInstallSessionId
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        $arguments += @('-InstallLogSessionId', $sessionId)
    }

    return ('"{0}" {1}' -f $shellPath, (Join-CommandLineArguments -Arguments $arguments))
}

function Register-HermesResume {
    $paths = Get-HermesPaths
    $command = Get-ResumeCommandLine

    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOncePath -Force | Out-Null
    Set-ItemProperty -Path $runOncePath -Name $paths.ResumeValueName -Value $command
    return 'runonce'
}

function Get-HermesGatewayStartupCommandLine {
    $paths = Get-HermesPaths
    $shellPath = Get-PreferredPowerShellExecutable
    if (-not $shellPath) {
        throw '找不到可用于 gateway 自启动的 pwsh.exe 或 powershell.exe。'
    }

    return ('"{0}" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -FromStartup' -f $shellPath, $paths.GatewayStartPs)
}

function Register-HermesGatewayAutostart {
    $paths = Get-HermesPaths
    $command = Get-HermesGatewayStartupCommandLine
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runPath -Force | Out-Null
    Set-ItemProperty -Path $runPath -Name $paths.GatewayStartupValueName -Value $command
    return 'run'
}

function Unregister-HermesGatewayAutostart {
    $paths = Get-HermesPaths
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if (Get-ItemProperty -Path $runPath -Name $paths.GatewayStartupValueName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runPath -Name $paths.GatewayStartupValueName -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Test-HermesGatewayAutostartRegistered {
    $paths = Get-HermesPaths
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        $value = Get-ItemProperty -Path $runPath -Name $paths.GatewayStartupValueName -ErrorAction SilentlyContinue
        return $null -ne $value
    }
    catch {
        return $false
    }
}

function Get-WeixinAccountCount {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username
    )

    $command = @'
if [ -d ~/.hermes/weixin/accounts ]; then
  find ~/.hermes/weixin/accounts -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]'
else
  printf '0'
fi
'@

    try {
        $text = Invoke-WslBash -Distro $DistroName -User $Username -Command $command -TimeoutSeconds 20
        $parsed = 0
        if ([int]::TryParse($text.Trim(), [ref]$parsed)) {
            return $parsed
        }
        return 0
    }
    catch {
        return 0
    }
}

function Test-WeixinConfigured {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username
    )

    return (Get-WeixinAccountCount -DistroName $DistroName -Username $Username) -gt 0
}

function Test-HermesGatewayRunning {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username
    )

    $command = @'
if ps -eo args= | grep -F "hermes gateway run" | grep -v "grep" >/dev/null; then
  echo running
else
  echo stopped
fi
'@

    try {
        $status = Invoke-WslBash -Distro $DistroName -User $Username -Command $command -TimeoutSeconds 20
        $lines = @(
            $status -split "(`r`n|`n|`r)" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )
        return $lines -contains 'running'
    }
    catch {
        return $false
    }
}

function Get-HermesGatewayLogTail {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username,
        [int]$Lines = 60
    )

    $command = "tail -n $Lines ~/.hermes/logs/gateway.log 2>/dev/null || true"
    try {
        return Invoke-WslBash -Distro $DistroName -User $Username -Command $command -TimeoutSeconds 20
    }
    catch {
        return ''
    }
}

function Unregister-HermesResume {
    $paths = Get-HermesPaths
    try {
        & schtasks.exe /Delete /TN $paths.ResumeTaskName /F 2>$null | Out-Null
    }
    catch {
    }

    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    try {
        if (Get-ItemProperty -Path $runOncePath -Name $paths.ResumeValueName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runOncePath -Name $paths.ResumeValueName -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}
