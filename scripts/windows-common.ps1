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
        ResumeLauncherPs = Join-Path $stateRoot 'resume-install.ps1'
        LegacyResumeLauncherCmd = Join-Path $stateRoot 'resume-install.cmd'
        DistroRoot      = Join-Path $stateRoot 'distros'
        InstallerPs     = Join-Path $repoRoot 'scripts\windows-install-hermes.ps1'
        ReusePs         = Join-Path $repoRoot 'scripts\windows-reuse-existing.ps1'
        WebUiPs         = Join-Path $repoRoot 'scripts\windows-webui.ps1'
        StatusPs        = Join-Path $repoRoot 'scripts\windows-check-status.ps1'
        LauncherBat     = Join-Path $repoRoot 'start-install.bat'
        StatusBat       = Join-Path $repoRoot 'check-status.bat'
        PrefetchPs      = Join-Path $repoRoot 'scripts\windows-prefetch-assets.ps1'
        GatewayStartPs  = Join-Path $repoRoot 'scripts\windows-start-gateway.ps1'
        WeChatSetupPs   = Join-Path $repoRoot 'scripts\windows-configure-wechat.ps1'
        ResumeValueName = '!HermesBootstrapResume'
        LegacyResumeValueName = 'HermesBootstrapResume'
        LegacyResumeTaskName = 'HermesBootstrapResume'
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

function Get-HermesLatestInstallLogPath {
    $paths = Get-HermesPaths
    $state = Get-HermesState

    if ($null -ne $state -and (Test-HermesAbsolutePath -Path ([string]$state.install_log_path)) -and (Test-Path -LiteralPath ([string]$state.install_log_path))) {
        return [string]$state.install_log_path
    }

    $latestLog = Get-ChildItem -LiteralPath $paths.RepoRoot -Filter 'install-log-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $latestLog) {
        return $latestLog.FullName
    }

    return ''
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

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$StandardInput = '',
        [int]$TimeoutSeconds = 60,
        [string]$ProgressMessage = '',
        [int]$ProgressIntervalSeconds = 15,
        [switch]$RequireSuccess
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
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
                $partialText = ConvertTo-HermesTrimmedText -Value $partialText
                if ($partialText.Length -gt 2000) {
                    $partialText = $partialText.Substring([Math]::Max(0, $partialText.Length - 2000))
                }

                if ($partialText) {
                    throw "Native command timed out after $TimeoutSeconds seconds: $FilePath $($psi.Arguments)`nPartial output:`n$partialText"
                }

                throw "Native command timed out after $TimeoutSeconds seconds: $FilePath $($psi.Arguments)"
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
        $text = ConvertTo-HermesTrimmedText -Value $combined
        $commandLine = if ($psi.Arguments) { "$FilePath $($psi.Arguments)" } else { $FilePath }

        if ($RequireSuccess -and $process.ExitCode -ne 0) {
            throw "Native command failed with exit code $($process.ExitCode): $commandLine`n$text"
        }

        return [PSCustomObject]@{
            ExitCode    = $process.ExitCode
            StdOut      = $stdout
            StdErr      = $stderr
            Text        = $text
            FilePath    = $FilePath
            Arguments   = $Arguments
            CommandLine = $commandLine
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-TextTail {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxChars = 1200
    )

    $normalized = ConvertTo-HermesTrimmedText -Value $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    if ($normalized.Length -le $MaxChars) {
        return $normalized
    }

    return $normalized.Substring($normalized.Length - $MaxChars)
}

function Invoke-WslCliInfo {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $tempPath = Join-Path $env:TEMP ("hermes-wsl-{0}.txt" -f ([guid]::NewGuid().ToString()))
    $argumentText = Join-CommandLineArguments -Arguments $Arguments
    $commandLine = "wsl.exe $argumentText"

    try {
        cmd.exe /d /u /c "wsl.exe $argumentText > `"$tempPath`" 2>&1" | Out-Null
        $exitCode = $LASTEXITCODE
        $content = ''
        if (Test-Path -LiteralPath $tempPath) {
            $content = Get-Content -Raw -LiteralPath $tempPath -Encoding Unicode
        }

        $normalized = (ConvertTo-HermesText -Value $content) -replace "`0", ''
        $text = ConvertTo-HermesTrimmedText -Value $normalized

        return [PSCustomObject]@{
            ExitCode    = $exitCode
            Text        = $text
            StdOut      = $text
            StdErr      = ''
            Arguments   = $Arguments
            CommandLine = $commandLine
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Invoke-WslUnicodeText {
    param([string]$Arguments)
    return (Invoke-WslCliInfo -Arguments @($Arguments)).Text
}

function Get-WslStatusInfo {
    return Invoke-WslCliInfo -Arguments @('--status')
}

function Get-WslStatusText {
    return (Get-WslStatusInfo).Text
}

function Get-WslHelpInfo {
    return Invoke-WslCliInfo -Arguments @('--help')
}

function Get-WslHelpText {
    return (Get-WslHelpInfo).Text
}

function Get-WslQuietListInfo {
    return Invoke-WslCliInfo -Arguments @('-l', '-q')
}

function Get-WslQuietListText {
    return (Get-WslQuietListInfo).Text
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

function Get-WslVerboseListInfo {
    return Invoke-WslCliInfo -Arguments @('-l', '-v')
}

function Get-WslVerboseListText {
    return (Get-WslVerboseListInfo).Text
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

function Get-WindowsOptionalFeatureStateInfo {
    param([Parameter(Mandatory = $true)][string]$FeatureName)

    $result = Invoke-NativeProcess -FilePath 'dism.exe' -Arguments @('/online', '/Get-FeatureInfo', "/FeatureName:$FeatureName", '/English') -TimeoutSeconds 120
    $state = 'unknown'
    foreach ($pattern in @('状态\s*:\s*(?<state>.+)', 'State\s*:\s*(?<state>.+)')) {
        $match = [regex]::Match($result.Text, $pattern)
        if ($match.Success) {
            $state = $match.Groups['state'].Value.Trim()
            break
        }
    }

    $normalizedState = $state.ToLowerInvariant()
    return [PSCustomObject]@{
        FeatureName = $FeatureName
        State       = $state
        IsEnabled   = ($normalizedState -match '已启用|enabled')
        IsDisabled  = ($normalizedState -match '已禁用|disabled')
        Result      = $result
    }
}

function Get-WslCliCapabilities {
    param([Parameter(Mandatory = $true)]$HelpInfo)

    $helpText = ConvertTo-HermesTrimmedText -Value $HelpInfo.Text
    $supportsInstall = $helpText -match '(?m)^\s*--install\b'
    $supportsImport = $helpText -match '(?m)^\s*--import\b'
    $supportsList = $helpText -match '(?m)^\s*--list\b'
    $supportsUpdate = $helpText -match '(?m)^\s*--update\b'
    $supportsInstallFromFile = $helpText -match '--from-file\b'
    $supportsInstallName = $helpText -match '--name\b'
    $supportsInstallLocation = $helpText -match '--location\b'
    $supportsNoLaunch = $helpText -match '--no-launch\b'
    $supportsNoDistribution = $helpText -match '--no-distribution\b'
    $supportsWebDownload = $helpText -match '--web-download\b'
    $supportsVersionCommand = $helpText -match '(?m)^\s*--version\b'

    return [PSCustomObject]@{
        HasRecognizedCoreCommands = ($supportsInstall -or $supportsImport -or $supportsList)
        SupportsInstallCommand    = $supportsInstall
        SupportsImport            = $supportsImport
        SupportsList              = $supportsList
        SupportsUpdate            = $supportsUpdate
        SupportsInstallFromFile   = $supportsInstallFromFile
        SupportsInstallName       = $supportsInstallName
        SupportsInstallLocation   = $supportsInstallLocation
        SupportsNoLaunch          = $supportsNoLaunch
        SupportsNoDistribution    = $supportsNoDistribution
        SupportsWebDownload       = $supportsWebDownload
        SupportsVersionCommand    = $supportsVersionCommand
        CanUseDedicatedInstallPath = ($supportsInstall -and $supportsInstallFromFile -and $supportsInstallName -and $supportsInstallLocation -and $supportsNoLaunch)
        CanUseImportPath          = $supportsImport
    }
}

function Get-WslRequiredCapabilitySummary {
    param([Parameter(Mandatory = $true)][bool]$UsingPrebuiltBaseImage)

    if ($UsingPrebuiltBaseImage) {
        return 'requires wsl.exe --import for the prebuilt base-image path'
    }

    return 'requires wsl.exe --install --from-file --name --location --no-launch for the dedicated package path'
}

function Get-WslRepairActionLabel {
    param([Parameter(Mandatory = $true)][string]$ActionId)

    switch ($ActionId) {
        'enable-features' { return '启用 WSL 和虚拟机平台' }
        'wsl-install-no-distribution' { return '执行 wsl --install --no-distribution' }
        'set-default-version-2' { return '执行 wsl --set-default-version 2' }
        'wsl-update' { return '执行 wsl --update' }
        'wsl-update-web-download' { return '执行 wsl --update --web-download' }
        'reboot' { return '重启 Windows 后继续安装' }
        'manual-upgrade-wsl' { return '手动升级到较新的 WSL 版本' }
        default { return $ActionId }
    }
}

function Classify-WslProbeResult {
    param(
        [Parameter(Mandatory = $true)]$StatusInfo,
        [Parameter(Mandatory = $true)]$HelpInfo,
        [Parameter(Mandatory = $true)]$CliCapabilities,
        [Parameter(Mandatory = $true)]$WslFeatureState,
        [Parameter(Mandatory = $true)]$VmpFeatureState,
        [Parameter(Mandatory = $true)]$PendingReboot,
        [Parameter(Mandatory = $true)][bool]$UsingPrebuiltBaseImage
    )

    $statusText = ConvertTo-HermesTrimmedText -Value $StatusInfo.Text
    $helpText = ConvertTo-HermesTrimmedText -Value $HelpInfo.Text
    $requiredPathSupported = if ($UsingPrebuiltBaseImage) { $CliCapabilities.CanUseImportPath } else { $CliCapabilities.CanUseDedicatedInstallPath }
    $suggestedRepairs = New-Object System.Collections.Generic.List[string]
    $failureClass = 'manual-repair-required'
    $summary = 'WSL preflight could not confirm that the host is ready.'
    $allowUnsafeContinue = $false

    if ($WslFeatureState.IsDisabled -or $VmpFeatureState.IsDisabled) {
        $failureClass = 'wsl-feature-disabled'
        $summary = 'WSL optional features are not fully enabled on this machine.'
        $suggestedRepairs.Add('enable-features') | Out-Null
        $suggestedRepairs.Add('wsl-install-no-distribution') | Out-Null
        $suggestedRepairs.Add('set-default-version-2') | Out-Null
        $suggestedRepairs.Add('reboot') | Out-Null
    }
    elseif ($PendingReboot.CBSRebootPending -or $PendingReboot.WURebootRequired -or $statusText -match '需要重启|restart|reboot') {
        $failureClass = 'reboot-required'
        $summary = 'Windows reports a pending reboot before WSL can be used reliably.'
        $suggestedRepairs.Add('reboot') | Out-Null
    }
    elseif ($statusText -match '未找到 WSL 2 内核文件|WSL 2 内核文件|wsl 2 kernel file|kernel file') {
        $failureClass = 'missing-kernel'
        $summary = 'The WSL 2 kernel is missing or not fully installed.'
        $suggestedRepairs.Add('wsl-update') | Out-Null
        if ($CliCapabilities.SupportsWebDownload) {
            $suggestedRepairs.Add('wsl-update-web-download') | Out-Null
        }
        $suggestedRepairs.Add('set-default-version-2') | Out-Null
    }
    elseif ([string]::IsNullOrWhiteSpace($helpText) -and [string]::IsNullOrWhiteSpace($statusText)) {
        $failureClass = 'probe-unreadable-output'
        $summary = 'WSL commands returned no readable output, so the host could not be classified safely.'
        $suggestedRepairs.Add('wsl-update') | Out-Null
        $suggestedRepairs.Add('reboot') | Out-Null
        $allowUnsafeContinue = $requiredPathSupported
    }
    elseif (-not $CliCapabilities.HasRecognizedCoreCommands) {
        $failureClass = 'probe-unreadable-output'
        $summary = 'The current wsl.exe help output could not be parsed into a known capability set.'
        $suggestedRepairs.Add('wsl-update') | Out-Null
        if ($CliCapabilities.SupportsWebDownload) {
            $suggestedRepairs.Add('wsl-update-web-download') | Out-Null
        }
        $suggestedRepairs.Add('manual-upgrade-wsl') | Out-Null
        $allowUnsafeContinue = $requiredPathSupported
    }
    elseif (-not $requiredPathSupported) {
        $failureClass = 'legacy-wsl-cli'
        $requiredLabel = Get-WslRequiredCapabilitySummary -UsingPrebuiltBaseImage:$UsingPrebuiltBaseImage
        $summary = "The current wsl.exe command set is too old for the selected install path; it $requiredLabel."
        $suggestedRepairs.Add('wsl-update') | Out-Null
        if ($CliCapabilities.SupportsWebDownload) {
            $suggestedRepairs.Add('wsl-update-web-download') | Out-Null
        }
        $suggestedRepairs.Add('manual-upgrade-wsl') | Out-Null
    }
    elseif ($StatusInfo.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($statusText)) {
        $failureClass = 'probe-unreadable-output'
        $summary = 'wsl --status failed without readable output, so the installer cannot prove the host is healthy.'
        $suggestedRepairs.Add('wsl-update') | Out-Null
        $suggestedRepairs.Add('reboot') | Out-Null
        $allowUnsafeContinue = $requiredPathSupported
    }
    elseif ($StatusInfo.ExitCode -eq 0 -or $statusText -match '默认版本|Default Version|没有已安装的分发版|There is no distribution|Windows Subsystem for Linux has no installed distributions') {
        $failureClass = 'healthy'
        $summary = 'WSL probe completed successfully.'
    }
    else {
        $failureClass = 'manual-repair-required'
        $summary = 'WSL replied, but the installer still cannot prove the host is healthy enough to continue automatically.'
        $suggestedRepairs.Add('wsl-update') | Out-Null
        if ($CliCapabilities.SupportsWebDownload) {
            $suggestedRepairs.Add('wsl-update-web-download') | Out-Null
        }
        $suggestedRepairs.Add('reboot') | Out-Null
        $allowUnsafeContinue = $requiredPathSupported
    }

    if ($failureClass -notin @('legacy-wsl-cli', 'probe-unreadable-output', 'manual-repair-required')) {
        $allowUnsafeContinue = $false
    }

    return [PSCustomObject]@{
        FailureClass        = $failureClass
        Summary             = $summary
        SuggestedRepairs    = @($suggestedRepairs | Select-Object -Unique)
        AllowUnsafeContinue = $allowUnsafeContinue
    }
}

function Invoke-WslCapabilityProbe {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][bool]$UsingPrebuiltBaseImage
    )

    $statusInfo = Get-WslStatusInfo
    $helpInfo = Get-WslHelpInfo
    $quietListInfo = Get-WslQuietListInfo
    $verboseListInfo = Get-WslVerboseListInfo
    $cliCapabilities = Get-WslCliCapabilities -HelpInfo $helpInfo
    $wslFeatureState = Get-WindowsOptionalFeatureStateInfo -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    $vmpFeatureState = Get-WindowsOptionalFeatureStateInfo -FeatureName 'VirtualMachinePlatform'
    $pendingReboot = Test-RebootPending
    $classification = Classify-WslProbeResult `
        -StatusInfo $statusInfo `
        -HelpInfo $helpInfo `
        -CliCapabilities $cliCapabilities `
        -WslFeatureState $wslFeatureState `
        -VmpFeatureState $vmpFeatureState `
        -PendingReboot $pendingReboot `
        -UsingPrebuiltBaseImage:$UsingPrebuiltBaseImage

    $evidence = New-Object System.Collections.Generic.List[string]
    $evidence.Add((Get-WslRequiredCapabilitySummary -UsingPrebuiltBaseImage:$UsingPrebuiltBaseImage)) | Out-Null
    $evidence.Add(("wsl --status exit={0}; tail={1}" -f $statusInfo.ExitCode, (Get-TextTail -Text $statusInfo.Text))) | Out-Null
    $evidence.Add(("wsl --help exit={0}; import={1}; installFromFile={2}; location={3}; noLaunch={4}; webDownload={5}" -f `
        $helpInfo.ExitCode,
        $cliCapabilities.SupportsImport,
        $cliCapabilities.SupportsInstallFromFile,
        $cliCapabilities.SupportsInstallLocation,
        $cliCapabilities.SupportsNoLaunch,
        $cliCapabilities.SupportsWebDownload)) | Out-Null
    $evidence.Add(("wsl -l -v exit={0}; tail={1}" -f $verboseListInfo.ExitCode, (Get-TextTail -Text $verboseListInfo.Text))) | Out-Null
    $evidence.Add(("Windows feature states: WSL={0}; VirtualMachinePlatform={1}" -f $wslFeatureState.State, $vmpFeatureState.State)) | Out-Null
    $evidence.Add(("Pending reboot: CBS={0}; WindowsUpdate={1}" -f $pendingReboot.CBSRebootPending, $pendingReboot.WURebootRequired)) | Out-Null

    return [PSCustomObject]@{
        ProbeStatus         = $(if ($classification.FailureClass -eq 'healthy') { 'ready' } else { 'blocked' })
        FailureClass        = $classification.FailureClass
        Summary             = $classification.Summary
        Evidence            = $evidence.ToArray()
        CliCapabilities     = $cliCapabilities
        SuggestedRepairs    = $classification.SuggestedRepairs
        AllowUnsafeContinue = $classification.AllowUnsafeContinue
        StatusInfo          = $statusInfo
        HelpInfo            = $helpInfo
        QuietListInfo       = $quietListInfo
        VerboseListInfo     = $verboseListInfo
        WslFeatureState     = $wslFeatureState
        VmpFeatureState     = $vmpFeatureState
        PendingReboot       = $pendingReboot
        RequiredPath        = Get-WslRequiredCapabilitySummary -UsingPrebuiltBaseImage:$UsingPrebuiltBaseImage
        Config              = $Config
    }
}

function Write-WslProbeDiagnostics {
    param([Parameter(Mandatory = $true)]$ProbeResult)

    Write-Step ("WSL probe classification: {0}" -f $ProbeResult.FailureClass)
    Write-Step ("WSL probe summary: {0}" -f $ProbeResult.Summary)
    foreach ($line in @($ProbeResult.Evidence)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }

        Write-Step ("WSL probe evidence: {0}" -f $line)
    }
}

function Show-HermesWslRepairDialog {
    param(
        [Parameter(Mandatory = $true)]$ProbeResult,
        [bool]$AllowAdvancedContinue = $false,
        [bool]$ShowRepairButton = $true,
        [string]$RepairButtonText = '立即修复'
    )

    Ensure-WindowsFormsLoaded

    $repairLines = @($ProbeResult.SuggestedRepairs | ForEach-Object { ' - ' + (Get-WslRepairActionLabel -ActionId $_) })
    if ($repairLines.Count -eq 0) {
        $repairLines = @(' - 当前没有可自动执行的修复动作。')
    }

    $evidenceLines = @($ProbeResult.Evidence | ForEach-Object { ' - ' + $_ })
    if ($evidenceLines.Count -eq 0) {
        $evidenceLines = @(' - 没有额外的诊断证据。')
    }

    $message = @(
        'Hermes 在正式创建 WSL 发行版前停止了安装。',
        '',
        ("原因分类: {0}" -f $ProbeResult.FailureClass),
        ("摘要: {0}" -f $ProbeResult.Summary),
        '',
        '建议修复动作:',
        $repairLines,
        '',
        '诊断摘要:',
        $evidenceLines
    ) -join [Environment]::NewLine

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WSL 环境需要修复'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(760, 520)
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(20, 20)
    $textBox.Size = New-Object System.Drawing.Size(700, 390)
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = 'Vertical'
    $textBox.Text = $message
    $form.Controls.Add($textBox)

    $form.Tag = 'repair-later'

    if ($ShowRepairButton) {
        $repairButton = New-Object System.Windows.Forms.Button
        $repairButton.Text = $RepairButtonText
        $repairButton.Location = New-Object System.Drawing.Point(360, 430)
        $repairButton.Size = New-Object System.Drawing.Size(110, 30)
        $repairButton.Add_Click({
            $form.Tag = 'repair-now'
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
            $form.Close()
        })
        $form.Controls.Add($repairButton)
        $form.AcceptButton = $repairButton
    }

    if ($AllowAdvancedContinue) {
        $advancedButton = New-Object System.Windows.Forms.Button
        $advancedButton.Text = '高级继续'
        $advancedButton.Location = New-Object System.Drawing.Point(480, 430)
        $advancedButton.Size = New-Object System.Drawing.Size(110, 30)
        $advancedButton.Add_Click({
            $form.Tag = 'advanced-continue'
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
            $form.Close()
        })
        $form.Controls.Add($advancedButton)
    }

    $laterButton = New-Object System.Windows.Forms.Button
    $laterButton.Text = '稍后处理'
    $laterButton.Location = New-Object System.Drawing.Point(600, 430)
    $laterButton.Size = New-Object System.Drawing.Size(110, 30)
    $laterButton.Add_Click({
        $form.Tag = 'repair-later'
        $form.DialogResult = [System.Windows.Forms.DialogResult]::No
        $form.Close()
    })
    $form.Controls.Add($laterButton)
    $form.CancelButton = $laterButton

    $null = $form.ShowDialog()
    return [string]$form.Tag
}

function Get-WslRepairFailureClass {
    param(
        [AllowNull()][string]$Text,
        [string]$DefaultClass = 'manual-repair-required'
    )

    $normalized = ConvertTo-HermesTrimmedText -Value $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $DefaultClass
    }

    if ($normalized -match '未找到 WSL 2 内核文件|WSL 2 内核文件|wsl 2 kernel file|kernel file') {
        return 'missing-kernel'
    }
    if ($normalized -match 'Microsoft Store|Store|下载|download|Internet|网络|web-download') {
        return 'network-blocked'
    }
    if ($normalized -match 'invalid command line option|unknown option|无效|不支持|not supported|--from-file|--web-download') {
        return 'legacy-wsl-cli'
    }

    return $DefaultClass
}

function Invoke-WslRepairAction {
    param([Parameter(Mandatory = $true)][string]$ActionId)

    switch ($ActionId) {
        'enable-features' {
            Write-Step '修复动作：启用 Microsoft-Windows-Subsystem-Linux。'
            $wslFeature = Invoke-NativeProcess -FilePath 'dism.exe' -Arguments @('/online', '/Enable-Feature', '/FeatureName:Microsoft-Windows-Subsystem-Linux', '/All', '/NoRestart') -TimeoutSeconds 600
            Write-Step '修复动作：启用 VirtualMachinePlatform。'
            $vmpFeature = Invoke-NativeProcess -FilePath 'dism.exe' -Arguments @('/online', '/Enable-Feature', '/FeatureName:VirtualMachinePlatform', '/All', '/NoRestart') -TimeoutSeconds 600
            $success = ($wslFeature.ExitCode -eq 0 -and $vmpFeature.ExitCode -eq 0)
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = $success
                Result        = [PSCustomObject]@{ Text = @($wslFeature.Text, $vmpFeature.Text) -join [Environment]::NewLine }
                RequiresReboot = $false
                FailureClass  = if ($success) { '' } else { 'wsl-feature-disabled' }
            }
        }
        'wsl-install-no-distribution' {
            Write-Step '修复动作：执行 wsl --install --no-distribution。'
            $result = Invoke-WslProcess -Arguments @('--install', '--no-distribution') -TimeoutSeconds 900
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = ($result.ExitCode -eq 0)
                Result        = $result
                RequiresReboot = $false
                FailureClass  = if ($result.ExitCode -eq 0) { '' } else { Get-WslRepairFailureClass -Text $result.Text -DefaultClass 'manual-repair-required' }
            }
        }
        'set-default-version-2' {
            Write-Step '修复动作：执行 wsl --set-default-version 2。'
            $result = Invoke-WslProcess -Arguments @('--set-default-version', '2') -TimeoutSeconds 300
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = ($result.ExitCode -eq 0)
                Result        = $result
                RequiresReboot = $false
                FailureClass  = if ($result.ExitCode -eq 0) { '' } else { Get-WslRepairFailureClass -Text $result.Text -DefaultClass 'manual-repair-required' }
            }
        }
        'wsl-update' {
            Write-Step '修复动作：执行 wsl --update。'
            $result = Invoke-WslProcess -Arguments @('--update') -TimeoutSeconds 1800
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = ($result.ExitCode -eq 0)
                Result        = $result
                RequiresReboot = $false
                FailureClass  = if ($result.ExitCode -eq 0) { '' } else { Get-WslRepairFailureClass -Text $result.Text -DefaultClass 'manual-repair-required' }
            }
        }
        'wsl-update-web-download' {
            Write-Step '修复动作：执行 wsl --update --web-download。'
            $result = Invoke-WslProcess -Arguments @('--update', '--web-download') -TimeoutSeconds 1800
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = ($result.ExitCode -eq 0)
                Result        = $result
                RequiresReboot = $false
                FailureClass  = if ($result.ExitCode -eq 0) { '' } else { Get-WslRepairFailureClass -Text $result.Text -DefaultClass 'manual-repair-required' }
            }
        }
        'reboot' {
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = $true
                Result        = [PSCustomObject]@{ Text = 'Windows reboot required.' }
                RequiresReboot = $true
                FailureClass  = ''
            }
        }
        'manual-upgrade-wsl' {
            return [PSCustomObject]@{
                ActionId      = $ActionId
                Success       = $false
                Result        = [PSCustomObject]@{ Text = 'The current WSL CLI is missing required install-path options. Upgrade WSL manually before retrying.' }
                RequiresReboot = $false
                FailureClass  = 'legacy-wsl-cli'
            }
        }
        default {
            throw "Unknown WSL repair action: $ActionId"
        }
    }
}

function Invoke-WslRepairFlow {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$ProbeResult,
        [Parameter(Mandatory = $true)][bool]$UsingPrebuiltBaseImage,
        [bool]$AllowUnsafeContinue = $false
    )

    $showAdvancedContinue = ($AllowUnsafeContinue -and $ProbeResult.AllowUnsafeContinue)
    $choice = Show-HermesWslRepairDialog -ProbeResult $ProbeResult -AllowAdvancedContinue:$showAdvancedContinue
    if ($choice -eq 'advanced-continue') {
        return [PSCustomObject]@{
            Status       = 'unsafe-continue'
            ProbeResult   = $ProbeResult
            FailureClass = $ProbeResult.FailureClass
            Message      = 'The user explicitly chose the advanced continue path.'
            ActionResults = @()
        }
    }
    if ($choice -ne 'repair-now') {
        return [PSCustomObject]@{
            Status       = 'repair-required'
            ProbeResult   = $ProbeResult
            FailureClass = $ProbeResult.FailureClass
            Message      = 'The user deferred WSL repair.'
            ActionResults = @()
        }
    }

    $actionResults = New-Object System.Collections.Generic.List[object]
    foreach ($actionId in @($ProbeResult.SuggestedRepairs | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$actionId)) {
            continue
        }

        $actionResult = Invoke-WslRepairAction -ActionId $actionId
        $actionResults.Add($actionResult) | Out-Null

        if (-not $actionResult.Success) {
            $failureText = if ($null -ne $actionResult.Result) { [string]$actionResult.Result.Text } else { '' }
            $failureClass = if ([string]::IsNullOrWhiteSpace([string]$actionResult.FailureClass)) {
                Get-WslRepairFailureClass -Text $failureText -DefaultClass $ProbeResult.FailureClass
            }
            else {
                [string]$actionResult.FailureClass
            }

            return [PSCustomObject]@{
                Status        = 'repair-required'
                ProbeResult   = $ProbeResult
                FailureClass  = $failureClass
                Message       = ("WSL repair action failed: {0}`n{1}" -f (Get-WslRepairActionLabel -ActionId $actionId), (Get-TextTail -Text $failureText))
                ActionResults = $actionResults.ToArray()
            }
        }

        if ($actionResult.RequiresReboot) {
            return [PSCustomObject]@{
                Status        = 'blocked-reboot'
                ProbeResult   = $ProbeResult
                FailureClass  = 'reboot-required'
                Message       = 'WSL repair requires a Windows reboot before installation can continue.'
                ActionResults = $actionResults.ToArray()
            }
        }
    }

    $pendingReboot = Test-RebootPending
    if ($pendingReboot.CBSRebootPending -or $pendingReboot.WURebootRequired) {
        return [PSCustomObject]@{
            Status        = 'blocked-reboot'
            ProbeResult   = $ProbeResult
            FailureClass  = 'reboot-required'
            Message       = 'WSL repair completed, but Windows now requires a reboot.'
            ActionResults = $actionResults.ToArray()
        }
    }

    $followUpProbe = Invoke-WslCapabilityProbe -Config $Config -UsingPrebuiltBaseImage:$UsingPrebuiltBaseImage
    Write-WslProbeDiagnostics -ProbeResult $followUpProbe
    if ($followUpProbe.FailureClass -eq 'healthy') {
        return [PSCustomObject]@{
            Status        = 'ready'
            ProbeResult   = $followUpProbe
            FailureClass  = 'healthy'
            Message       = 'WSL repair finished and the follow-up probe passed.'
            ActionResults = $actionResults.ToArray()
        }
    }

    if ($AllowUnsafeContinue -and $followUpProbe.AllowUnsafeContinue) {
        $overrideChoice = Show-HermesWslRepairDialog `
            -ProbeResult $followUpProbe `
            -AllowAdvancedContinue:$true `
            -ShowRepairButton:$false

        if ($overrideChoice -eq 'advanced-continue') {
            return [PSCustomObject]@{
                Status        = 'unsafe-continue'
                ProbeResult   = $followUpProbe
                FailureClass  = $followUpProbe.FailureClass
                Message       = 'The user explicitly chose the advanced continue path after repair did not fully clear the probe.'
                ActionResults = $actionResults.ToArray()
            }
        }
    }

    return [PSCustomObject]@{
        Status        = 'repair-required'
        ProbeResult   = $followUpProbe
        FailureClass  = $followUpProbe.FailureClass
        Message       = $followUpProbe.Summary
        ActionResults = $actionResults.ToArray()
    }
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
        $probe = Invoke-WslDirectCommand -Distro $Name -User 'root' -CommandPath '/bin/echo' -Arguments @('ready') -TimeoutSeconds 30
        return $probe.StdOut -eq 'ready'
    }
    catch {
        return $false
    }
}

function Test-HermesManagedDistributionMarker {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [int]$TimeoutSeconds = 45
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
    $allowUnsafeContinue = if ($stateMatchesRepo -and $state.PSObject.Properties.Name -contains 'allow_unsafe_continue' -and $null -ne $state.allow_unsafe_continue) {
        [bool]$state.allow_unsafe_continue
    }
    else {
        $false
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
        AllowUnsafeContinue = $allowUnsafeContinue
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

function Resolve-RemoteContentLengthInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [int64]$ResponseContentLength = -1,
        [string]$ContentRangeHeader = '',
        [string]$HeaderContentLength = ''
    )

    $normalizedMethod = $Method.Trim().ToUpperInvariant()
    $methodPrefix = $normalizedMethod.ToLowerInvariant()
    $contentLength = 0L
    $source = 'unavailable'
    $isTrusted = $false

    if ($ContentRangeHeader -match '/(?<total>\d+)$') {
        $contentLength = [int64]$Matches['total']
        if ($contentLength -gt 0) {
            $source = ("{0}-content-range-total" -f $methodPrefix)
            $isTrusted = $true
        }
    }

    if (-not $isTrusted -and $StatusCode -ne 206) {
        if ($ResponseContentLength -gt 0) {
            $contentLength = [int64]$ResponseContentLength
            $source = ("{0}-response-content-length" -f $methodPrefix)
            $isTrusted = $true
        }
        elseif ($HeaderContentLength -match '^\d+$') {
            $contentLength = [int64]$HeaderContentLength
            if ($contentLength -gt 0) {
                $source = ("{0}-header-content-length" -f $methodPrefix)
                $isTrusted = $true
            }
        }
    }

    return [PSCustomObject]@{
        ContentLength = $contentLength
        Source        = $source
        IsTrusted     = $isTrusted
    }
}

function Get-TrustedRemoteContentLength {
    param($Metadata)

    if ($null -eq $Metadata) {
        return 0L
    }
    if ($Metadata.PSObject.Properties.Name -notcontains 'IsTrustedLength' -or -not [bool]$Metadata.IsTrustedLength) {
        return 0L
    }
    if ($Metadata.PSObject.Properties.Name -notcontains 'ContentLength') {
        return 0L
    }

    $contentLength = [int64]$Metadata.ContentLength
    if ($contentLength -gt 0) {
        return $contentLength
    }

    return 0L
}

function Get-RemoteFileMetadataSummary {
    param($Metadata)

    if ($null -eq $Metadata) {
        return '无可用远程元数据'
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($Metadata.PSObject.Properties.Name -contains 'ProbeMethod' -and -not [string]::IsNullOrWhiteSpace([string]$Metadata.ProbeMethod)) {
        $parts.Add(("method={0}" -f [string]$Metadata.ProbeMethod))
    }
    if ($Metadata.PSObject.Properties.Name -contains 'StatusCode' -and $null -ne $Metadata.StatusCode) {
        $parts.Add(("status={0}" -f [int]$Metadata.StatusCode))
    }
    if ($Metadata.PSObject.Properties.Name -contains 'ContentLengthSource' -and -not [string]::IsNullOrWhiteSpace([string]$Metadata.ContentLengthSource)) {
        $parts.Add(("source={0}" -f [string]$Metadata.ContentLengthSource))
    }

    $trustedLength = Get-TrustedRemoteContentLength -Metadata $Metadata
    if ($trustedLength -gt 0) {
        $parts.Add(("length={0}" -f $trustedLength))
    }
    elseif ($Metadata.PSObject.Properties.Name -contains 'ContentLength' -and [int64]$Metadata.ContentLength -gt 0) {
        $parts.Add(("untrusted-length={0}" -f [int64]$Metadata.ContentLength))
    }
    else {
        $parts.Add('length=unknown')
    }

    return ($parts -join ', ')
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
            $contentRange = [string]$response.Headers['Content-Range']
            $headerLength = [string]$response.Headers['Content-Length']
            $contentLengthInfo = Resolve-RemoteContentLengthInfo `
                -Method $method `
                -StatusCode ([int]$response.StatusCode) `
                -ResponseContentLength ([int64]$response.ContentLength) `
                -ContentRangeHeader $contentRange `
                -HeaderContentLength $headerLength

            return [PSCustomObject]@{
                StatusCode          = [int]$response.StatusCode
                ContentLength       = $contentLengthInfo.ContentLength
                LastModified        = [string]$response.Headers['Last-Modified']
                ProbeMethod         = $method
                ContentLengthSource = $contentLengthInfo.Source
                IsTrustedLength     = $contentLengthInfo.IsTrusted
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

function Convert-HermesKeyValueTextToMap {
    param([string]$Text)

    $map = [ordered]@{}
    foreach ($line in ($Text -split "(`r`n|`n|`r)")) {
        if ($line -match '^(?<key>[A-Za-z0-9_]+)=(?<value>.*)$') {
            $map[$matches['key']] = $matches['value']
        }
    }

    return $map
}

function Get-HermesInstallStageRank {
    param([string]$Stage)

    switch -Regex ([string]$Stage) {
        '^failed$' { return -50 }
        '^selection-complete$' { return 10 }
        '^assets-ready$' { return 20 }
        '^bootstrap-started$' { return 30 }
        '^wsl-ready$' { return 35 }
        '^package-ready$' { return 40 }
        '^cloud-init-ready$' { return 45 }
        '^distro-ready$' { return 50 }
        '^bootstrap-recovering$' { return 55 }
        '^install-hermes$' { return 56 }
        '^ready-for-key$' { return 60 }
        '^key-injected$' { return 70 }
        '^hermes-verified$' { return 80 }
        '^preparing-wechat$' { return 85 }
        '^ready-for-wechat$' { return 90 }
        '^wechat-bound$' { return 100 }
        '^starting-gateway$' { return 105 }
        '^gateway-running$' { return 110 }
        '^webui-installed$' { return 115 }
        '^webui-running$' { return 120 }
        '^success$' { return 130 }
        default { return 0 }
    }
}

function Resolve-HermesManagedCanonicalState {
    param([Parameter(Mandatory = $true)]$Snapshot)

    $canonicalStage = ''
    $canonicalLastResult = ''
    $recommendedAction = ''

    $stateStage = [string]$Snapshot.StateStage
    $stateLastResult = [string]$Snapshot.StateLastResult
    $bootstrapStage = [string]$Snapshot.BootstrapStage
    $bootstrapResult = [string]$Snapshot.BootstrapResult
    $cloudInitState = [string]$Snapshot.CloudInitStatusState

    if (-not $Snapshot.DistroExists) {
        $canonicalStage = $(if ($stateStage) { $stateStage } else { 'selection-complete' })
        $canonicalLastResult = $(if ($stateLastResult) { $stateLastResult } else { 'target-missing' })
        $recommendedAction = 'Run start-install.bat to create the dedicated Hermes WSL distro.'
    }
    elseif (-not $Snapshot.ManagedMarkerPresent) {
        $canonicalStage = $(if ($stateStage) { $stateStage } else { 'selection-complete' })
        $canonicalLastResult = $(if ($stateLastResult) { $stateLastResult } else { 'target-not-managed' })
        $recommendedAction = 'The target distro exists but is not marked as Hermes-managed. Use the dedicated install path or resolve the naming conflict first.'
    }
    elseif (-not $Snapshot.DistroHealthy) {
        $canonicalStage = $(if ($stateStage) { $stateStage } else { 'install-hermes' })
        $canonicalLastResult = 'distro-unhealthy'
        $recommendedAction = 'Rerun the installer so it can repair or reconcile the managed distro.'
    }
    elseif ($bootstrapResult -eq 'ready_for_key' -and -not $Snapshot.KeyInjected) {
        $canonicalStage = 'ready-for-key'
        $canonicalLastResult = 'ready-for-key'
        $recommendedAction = 'Collect the provider key locally and inject it into WSL.'
    }
    elseif ($Snapshot.KeyInjected -and -not $Snapshot.WeixinConfigured) {
        $canonicalStage = 'key-injected'
        $canonicalLastResult = 'key-injected'
        $recommendedAction = 'Continue with Hermes verification and the Weixin binding flow.'
    }
    elseif ($Snapshot.WeixinConfigured -and -not $Snapshot.GatewayRunning) {
        $canonicalStage = 'wechat-bound'
        $canonicalLastResult = 'wechat-bound'
        $recommendedAction = 'Start hermes gateway run or rerun the installer to continue automatically.'
    }
    elseif ($Snapshot.GatewayRunning -and -not $Snapshot.WebUiInstalled) {
        $canonicalStage = 'gateway-running'
        $canonicalLastResult = 'gateway-running'
        $recommendedAction = 'Install or open the Hermes WebUI, then complete a real WeChat round-trip test.'
    }
    elseif ($Snapshot.WebUiInstalled -and -not $Snapshot.WebUiRunning) {
        $canonicalStage = 'webui-installed'
        $canonicalLastResult = 'webui-installed'
        $recommendedAction = 'Start the Hermes WebUI, then complete a real WeChat round-trip test.'
    }
    elseif ($Snapshot.WebUiRunning) {
        if ($stateStage -eq 'success' -and $stateLastResult -eq 'success') {
            $canonicalStage = 'success'
            $canonicalLastResult = 'success'
            $recommendedAction = 'Hermes is already fully available.'
        }
        elseif ($stateLastResult -eq 'awaiting-wechat-roundtrip') {
            $canonicalStage = 'webui-running'
            $canonicalLastResult = 'awaiting-wechat-roundtrip'
            $recommendedAction = 'Send a real WeChat message to Hermes and confirm the end-to-end reply.'
        }
        else {
            $canonicalStage = 'webui-running'
            $canonicalLastResult = 'webui-running'
            $recommendedAction = 'Open the WebUI or send a real WeChat test message to confirm end-to-end delivery.'
        }
    }
    elseif ($bootstrapResult -like 'failed:*' -or $Snapshot.BootstrapFailedStage) {
        $canonicalStage = 'failed'
        $canonicalLastResult = $(if ($bootstrapResult) { $bootstrapResult } else { "failed:$($Snapshot.BootstrapFailedStage)" })
        $recommendedAction = 'Inspect the bootstrap diagnostics and rerun the installer to repair the managed distro.'
    }
    elseif ($bootstrapStage) {
        $canonicalStage = $bootstrapStage
        if ($stateLastResult -eq 'bootstrap-stale-running') {
            $canonicalLastResult = 'bootstrap-stale-running'
            $recommendedAction = 'The bootstrap progress appears stale. Rerun the installer so it can reconcile and repair the managed distro.'
        }
        elseif ($cloudInitState -eq 'running') {
            $canonicalLastResult = 'bootstrap-running'
            $recommendedAction = 'The Linux-side bootstrap is still running. Wait for progress or rerun the installer to reconcile it.'
        }
        else {
            $canonicalLastResult = 'bootstrap-recovering'
            $recommendedAction = 'The managed distro is between bootstrap stages. Rerun the installer to continue from the saved checkpoint.'
        }
    }
    else {
        $canonicalStage = $(if ($stateStage) { $stateStage } else { 'selection-complete' })
        $canonicalLastResult = $(if ($stateLastResult) { $stateLastResult } else { 'state-only' })
        $recommendedAction = 'Rerun the installer to continue the automatic setup flow.'
    }

    return [PSCustomObject]@{
        CanonicalStage      = $canonicalStage
        CanonicalLastResult = $canonicalLastResult
        RecommendedAction   = $recommendedAction
    }
}

function Get-HermesManagedInstallSnapshot {
    param([Parameter(Mandatory = $true)]$Config)

    $state = Get-HermesState
    $stateMatches = Test-HermesStateMatchesConfig -State $state -Config $Config
    $stateStage = if ($stateMatches -and $state.PSObject.Properties.Name -contains 'stage') { [string]$state.stage } else { '' }
    $stateLastResult = if ($stateMatches -and $state.PSObject.Properties.Name -contains 'last_result') { [string]$state.last_result } else { '' }
    $stateUpdatedAt = if ($stateMatches -and $state.PSObject.Properties.Name -contains 'updated_at') { [string]$state.updated_at } else { '' }
    $stateLogPath = if ($stateMatches -and $state.PSObject.Properties.Name -contains 'install_log_path') { [string]$state.install_log_path } else { '' }

    $distroExists = Test-WslDistributionExists -Name $Config.DistroName
    $distroHealthy = $false
    $managedMarkerPresent = $false
    $userHealthy = $false

    $bootstrapStage = ''
    $bootstrapResult = ''
    $bootstrapFailedStage = ''
    $cloudInitStatusState = ''
    $cloudInitExtendedStatus = ''
    $keyStatus = ''
    $weixinAccountCount = 0
    $weixinHasAccountId = $false
    $weixinHasToken = $false
    $keyInjected = $false
    $weixinConfigured = $false
    $gatewayRunning = $false
    $bootstrapProbeError = ''
    $userProbeError = ''

    if ($distroExists) {
        $distroHealthy = Test-WslDistributionHealthy -Name $Config.DistroName
        $managedMarkerPresent = Test-HermesManagedDistributionMarker -DistroName $Config.DistroName
    }

    if ($distroHealthy) {
        $rootCommand = @'
stage="$(cat /var/lib/hermes-bootstrap/stage.txt 2>/dev/null || true)"
result="$(cat /var/lib/hermes-bootstrap/result 2>/dev/null || true)"
failed_stage="$(cat /var/lib/hermes-bootstrap/failed_stage.txt 2>/dev/null || true)"
key_status="$(cat /var/lib/hermes-bootstrap/key_status 2>/dev/null || true)"
cloud_status="$(cloud-init status --long 2>/dev/null || true)"
cloud_state="$(printf '%s\n' "$cloud_status" | awk -F': ' '/^status:/ {print $2; exit}')"
cloud_extended="$(printf '%s\n' "$cloud_status" | awk -F': ' '/^extended_status:/ {print $2; exit}')"
printf 'stage=%s\n' "$stage"
printf 'result=%s\n' "$result"
printf 'failed_stage=%s\n' "$failed_stage"
printf 'key_status=%s\n' "$key_status"
printf 'cloud_state=%s\n' "$cloud_state"
printf 'cloud_extended=%s\n' "$cloud_extended"
'@

        try {
            $rootProbe = Invoke-WslBash -Distro $Config.DistroName -User 'root' -Command $rootCommand -TimeoutSeconds 30
            $rootMap = Convert-HermesKeyValueTextToMap -Text $rootProbe
            $bootstrapStage = [string]$rootMap['stage']
            $bootstrapResult = [string]$rootMap['result']
            $bootstrapFailedStage = [string]$rootMap['failed_stage']
            $cloudInitStatusState = [string]$rootMap['cloud_state']
            $cloudInitExtendedStatus = [string]$rootMap['cloud_extended']
            $keyStatus = [string]$rootMap['key_status']
        }
        catch {
            $bootstrapProbeError = $_.Exception.Message
        }

        $userCommand = @'
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
KEY_INJECTED="false"
if [ -f /var/lib/hermes-bootstrap/key_status ] && [ "$(cat /var/lib/hermes-bootstrap/key_status 2>/dev/null)" = "success" ] && [ -f "$HOME_DIR/.hermes/.env" ]; then
  KEY_INJECTED="true"
fi
WEIXIN_CONFIGURED="false"
if [ "${ACCOUNT_COUNT:-0}" -gt 0 ] || { [ -n "$ACCOUNT_ID" ] && [ -n "$TOKEN" ]; }; then
  WEIXIN_CONFIGURED="true"
fi
GATEWAY_RUNNING="false"
if ps -eo args= | grep -F "hermes gateway run" | grep -v grep >/dev/null; then
  GATEWAY_RUNNING="true"
fi
printf 'user_name=%s\n' "$USER_NAME"
printf 'key_injected=%s\n' "$KEY_INJECTED"
printf 'weixin_account_count=%s\n' "$ACCOUNT_COUNT"
printf 'weixin_has_account_id=%s\n' "$(if [ -n "$ACCOUNT_ID" ]; then printf 'true'; else printf 'false'; fi)"
printf 'weixin_has_token=%s\n' "$(if [ -n "$TOKEN" ]; then printf 'true'; else printf 'false'; fi)"
printf 'weixin_configured=%s\n' "$WEIXIN_CONFIGURED"
printf 'gateway_running=%s\n' "$GATEWAY_RUNNING"
'@

        try {
            $userProbe = Invoke-WslBash -Distro $Config.DistroName -User $Config.Username -Command $userCommand -TimeoutSeconds 30
            $userMap = Convert-HermesKeyValueTextToMap -Text $userProbe
            $userHealthy = [string]$userMap['user_name'] -eq $Config.Username
            $keyInjected = ([string]$userMap['key_injected']).Trim().ToLowerInvariant() -eq 'true'
            [int]::TryParse([string]$userMap['weixin_account_count'], [ref]$weixinAccountCount) | Out-Null
            $weixinHasAccountId = ([string]$userMap['weixin_has_account_id']).Trim().ToLowerInvariant() -eq 'true'
            $weixinHasToken = ([string]$userMap['weixin_has_token']).Trim().ToLowerInvariant() -eq 'true'
            $weixinConfigured = ([string]$userMap['weixin_configured']).Trim().ToLowerInvariant() -eq 'true'
            $gatewayRunning = ([string]$userMap['gateway_running']).Trim().ToLowerInvariant() -eq 'true'
        }
        catch {
            $userProbeError = $_.Exception.Message
        }
    }

    $webUiInstalled = Test-HermesWebUiFilesPresent -Config $Config
    $webUiRunning = if ($distroHealthy -and $userHealthy -and $webUiInstalled) { Test-HermesWebUiRuntimeRunning -Config $Config } else { $false }
    $autostartRegistered = Test-HermesGatewayAutostartRegistered

    $snapshot = [PSCustomObject]@{
        Config                = $Config
        StateObject           = $state
        StateMatchesConfig    = $stateMatches
        StateStage            = $stateStage
        StateLastResult       = $stateLastResult
        StateUpdatedAt        = $stateUpdatedAt
        StateInstallLogPath   = $stateLogPath
        DistroExists          = $distroExists
        DistroHealthy         = $distroHealthy
        ManagedMarkerPresent  = $managedMarkerPresent
        UserHealthy           = $userHealthy
        BootstrapStage        = $bootstrapStage
        BootstrapResult       = $bootstrapResult
        BootstrapFailedStage  = $bootstrapFailedStage
        CloudInitStatusState  = $cloudInitStatusState
        CloudInitExtendedStatus = $cloudInitExtendedStatus
        KeyStatus             = $keyStatus
        KeyInjected           = $keyInjected
        WeixinAccountCount    = $weixinAccountCount
        WeixinHasAccountId    = $weixinHasAccountId
        WeixinHasToken        = $weixinHasToken
        WeixinConfigured      = $weixinConfigured
        GatewayRunning        = $gatewayRunning
        WebUiInstalled        = $webUiInstalled
        WebUiRunning          = $webUiRunning
        AutostartRegistered   = $autostartRegistered
        BootstrapProbeError   = $bootstrapProbeError
        UserProbeError        = $userProbeError
        LatestInstallLogPath  = $(if ($stateLogPath) { $stateLogPath } else { Get-HermesLatestInstallLogPath })
    }

    $canonical = Resolve-HermesManagedCanonicalState -Snapshot $snapshot
    $snapshot | Add-Member -NotePropertyName CanonicalStage -NotePropertyValue $canonical.CanonicalStage
    $snapshot | Add-Member -NotePropertyName CanonicalLastResult -NotePropertyValue $canonical.CanonicalLastResult
    $snapshot | Add-Member -NotePropertyName RecommendedAction -NotePropertyValue $canonical.RecommendedAction
    return $snapshot
}

function Sync-HermesStateFromManagedSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$Force
    )

    $snapshot = Get-HermesManagedInstallSnapshot -Config $Config
    $canonicalStage = [string]$snapshot.CanonicalStage
    $canonicalLastResult = [string]$snapshot.CanonicalLastResult
    $currentStage = [string]$snapshot.StateStage
    $currentLastResult = [string]$snapshot.StateLastResult

    $snapshot | Add-Member -NotePropertyName StateUpdated -NotePropertyValue $false -Force
    $snapshot | Add-Member -NotePropertyName StateUpdateReason -NotePropertyValue '' -Force

    if (-not $snapshot.StateMatchesConfig) {
        return $snapshot
    }
    if (-not $snapshot.ManagedMarkerPresent) {
        return $snapshot
    }
    if (-not $snapshot.DistroHealthy) {
        return $snapshot
    }
    if ([string]::IsNullOrWhiteSpace($canonicalStage)) {
        return $snapshot
    }

    $currentRank = Get-HermesInstallStageRank -Stage $currentStage
    $canonicalRank = Get-HermesInstallStageRank -Stage $canonicalStage
    $shouldUpdate = $Force.IsPresent -or
        $canonicalRank -gt $currentRank -or
        ($canonicalStage -eq $currentStage -and $canonicalLastResult -and $canonicalLastResult -ne $currentLastResult)

    if ($shouldUpdate) {
        Save-HermesState -Stage $canonicalStage -Config $Config -Notes $snapshot.RecommendedAction -LastResult $canonicalLastResult
        $snapshot.StateUpdated = $true
        $snapshot.StateUpdateReason = ("State reconciled from {0}/{1} to {2}/{3}" -f $currentStage, $currentLastResult, $canonicalStage, $canonicalLastResult)
    }

    return $snapshot
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
        allow_unsafe_continue = $(if ($Config.PSObject.Properties.Name -contains 'AllowUnsafeContinue') { [bool]$Config.AllowUnsafeContinue } else { $false })
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

    foreach ($launcherPath in @($paths.ResumeLauncherPs, $paths.LegacyResumeLauncherCmd) | Select-Object -Unique) {
        if (Test-Path -LiteralPath $launcherPath) {
            Remove-Item -LiteralPath $launcherPath -Force
        }
    }
}

function Get-ResumeCommandLine {
    $paths = Get-HermesPaths
    $state = Get-HermesState
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
    if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'allow_unsafe_continue' -and $null -ne $state.allow_unsafe_continue -and [bool]$state.allow_unsafe_continue) {
        $arguments += '-AllowUnsafeContinue'
    }

    return ('"{0}" {1}' -f $shellPath, (Join-CommandLineArguments -Arguments $arguments))
}

function Get-HermesResumeLauncherContent {
    $paths = Get-HermesPaths
    $state = Get-HermesState
    $allowUnsafeContinue = (
        $null -ne $state -and
        $state.PSObject.Properties.Name -contains 'allow_unsafe_continue' -and
        $null -ne $state.allow_unsafe_continue -and
        [bool]$state.allow_unsafe_continue
    )

    $content = @'
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerPath = '__INSTALLER_PATH__'
$arguments = @(
    '-Resume'
)
if (__ALLOW_UNSAFE_CONTINUE__) {
    $arguments += '-AllowUnsafeContinue'
}

& $installerPath @arguments
if ($null -ne $LASTEXITCODE) {
    exit $LASTEXITCODE
}

exit 0
'@
    $content = $content.Replace('__INSTALLER_PATH__', $paths.InstallerPs.Replace("'", "''"))
    $content = $content.Replace('__ALLOW_UNSAFE_CONTINUE__', $(if ($allowUnsafeContinue) { '$true' } else { '$false' }))
    return $content
}

function Write-HermesResumeLauncher {
    $paths = Get-HermesPaths
    Ensure-Directory -Path $paths.StateRoot
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($paths.ResumeLauncherPs, (Get-HermesResumeLauncherContent), $utf8Bom)

    if (Test-Path -LiteralPath $paths.LegacyResumeLauncherCmd) {
        Remove-Item -LiteralPath $paths.LegacyResumeLauncherCmd -Force -ErrorAction SilentlyContinue
    }

    return $paths.ResumeLauncherPs
}

function Get-HermesResumeRegistrationCommandLine {
    $paths = Get-HermesPaths
    $arguments = @(
        '-NoLogo',
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $paths.ResumeLauncherPs
    )

    return ('powershell.exe {0}' -f (Join-CommandLineArguments -Arguments $arguments))
}

function Assert-HermesRunOnceCommandLength {
    param([Parameter(Mandatory = $true)][string]$Command)

    $maxLength = 260
    if ($Command.Length -gt $maxLength) {
        throw ("Hermes resume registration command is {0} characters, which exceeds the Windows RunOnce limit of {1}: {2}" -f $Command.Length, $maxLength, $Command)
    }
}

function Register-HermesResume {
    $paths = Get-HermesPaths
    Write-HermesResumeLauncher | Out-Null
    $command = Get-HermesResumeRegistrationCommandLine
    Assert-HermesRunOnceCommandLength -Command $command

    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOncePath -Force | Out-Null
    Remove-ItemProperty -Path $runOncePath -Name $paths.LegacyResumeValueName -ErrorAction SilentlyContinue
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

function Get-WeixinBindingSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username
    )

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
printf 'configured=%s\n' "$(if [ "${ACCOUNT_COUNT:-0}" -gt 0 ] || { [ -n "$ACCOUNT_ID" ] && [ -n "$TOKEN" ]; }; then printf 'true'; else printf 'false'; fi)"
'@

    $rawText = ''
    $details = @{
        account_count  = '0'
        has_account_id = 'false'
        has_token      = 'false'
        configured     = 'false'
    }

    try {
        $rawText = Invoke-WslBash -Distro $DistroName -User $Username -Command $command -TimeoutSeconds 20
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
        AccountCount = $accountCount
        HasAccountId = ([string]$details.has_account_id).Trim().ToLowerInvariant() -eq 'true'
        HasToken     = ([string]$details.has_token).Trim().ToLowerInvariant() -eq 'true'
        IsConfigured = ([string]$details.configured).Trim().ToLowerInvariant() -eq 'true'
        RawText      = $rawText
    }
}

function Get-WeixinAccountCount {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username
    )

    return (Get-WeixinBindingSnapshot -DistroName $DistroName -Username $Username).AccountCount
}

function Test-WeixinConfigured {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$Username
    )

    return (Get-WeixinBindingSnapshot -DistroName $DistroName -Username $Username).IsConfigured
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

function Test-HermesWebUiFilesPresent {
    param([Parameter(Mandatory = $true)]$Config)

    $installPath = Get-HermesWebUiInstallPath -Config $Config
    return (Test-Path -LiteralPath (Join-Path $installPath 'start.sh'))
}

function Test-HermesWebUiRuntimeRunning {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not (Test-HermesWebUiFilesPresent -Config $Config)) {
        return $false
    }
    if (-not (Test-WslDistributionHealthy -Name $Config.DistroName)) {
        return $false
    }

    $installPathInWsl = (Convert-WindowsPathToWslMountPath -Path (Get-HermesWebUiInstallPath -Config $Config)).Replace("'", "'\''")
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
        $status = Invoke-WslBash -Distro $Config.DistroName -User $Config.Username -Command $command -TimeoutSeconds 20
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

function Unregister-HermesResume {
    $paths = Get-HermesPaths
    try {
        & schtasks.exe /Delete /TN $paths.LegacyResumeTaskName /F 2>$null | Out-Null
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

    try {
        if (Get-ItemProperty -Path $runOncePath -Name $paths.LegacyResumeValueName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runOncePath -Name $paths.LegacyResumeValueName -ErrorAction SilentlyContinue
        }
    }
    catch {
    }

    foreach ($launcherPath in @($paths.ResumeLauncherPs, $paths.LegacyResumeLauncherCmd) | Select-Object -Unique) {
        try {
            if (Test-Path -LiteralPath $launcherPath) {
                Remove-Item -LiteralPath $launcherPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }
}
