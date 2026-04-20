[CmdletBinding()]
param(
    [switch]$Resume,
    [string]$InstallLogPath = '',
    [string]$InstallLogSessionId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$paths = Get-HermesPaths
$totalPhases = 8
$completed = New-Object System.Collections.Generic.List[string]
$installLogSession = $null
$transcriptStarted = $false
$supplementalLogPaths = New-Object System.Collections.Generic.List[string]

function Register-SupplementalInstallLogPath {
    param([string]$Path)

    if (-not (Test-HermesAbsolutePath -Path $Path)) {
        return
    }

    if (-not $supplementalLogPaths.Contains($Path)) {
        $supplementalLogPaths.Add($Path) | Out-Null
    }
}

function Resolve-InstallLogSession {
    $state = Get-HermesState
    $stateMatchesRepo = ($null -ne $state -and [string]$state.repo_root -eq $paths.RepoRoot)

    $requestedPath = ''
    if (Test-HermesAbsolutePath -Path $InstallLogPath) {
        $requestedPath = $InstallLogPath
    }
    elseif ($Resume -and $stateMatchesRepo -and (Test-HermesAbsolutePath -Path ([string]$state.install_log_path))) {
        $requestedPath = [string]$state.install_log_path
    }
    elseif (Test-HermesAbsolutePath -Path (Get-CurrentInstallSessionLogPath)) {
        $requestedPath = Get-CurrentInstallSessionLogPath
    }

    $requestedSessionId = ''
    if (-not [string]::IsNullOrWhiteSpace($InstallLogSessionId)) {
        $requestedSessionId = $InstallLogSessionId
    }
    elseif ($Resume -and $stateMatchesRepo -and -not [string]::IsNullOrWhiteSpace([string]$state.install_log_session_id)) {
        $requestedSessionId = [string]$state.install_log_session_id
    }
    elseif (-not [string]::IsNullOrWhiteSpace((Get-CurrentInstallSessionId))) {
        $requestedSessionId = Get-CurrentInstallSessionId
    }

    return (New-HermesInstallLogSession -RequestedPath $requestedPath -RequestedSessionId $requestedSessionId)
}

function Write-ExceptionDiagnostics {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$Record)

    Write-Step ("安装失败：{0}" -f $Record.Exception.Message)

    if ($Record.InvocationInfo -and $Record.InvocationInfo.PositionMessage) {
        Write-Host $Record.InvocationInfo.PositionMessage
    }

    if ($Record.ScriptStackTrace) {
        Write-Host "Script stack:`n$($Record.ScriptStackTrace)"
    }

    $inner = $Record.Exception.InnerException
    $depth = 0
    while ($null -ne $inner -and $depth -lt 8) {
        Write-Host ("Inner[{0}] {1}: {2}" -f $depth, $inner.GetType().FullName, $inner.Message)
        $inner = $inner.InnerException
        $depth += 1
    }
}

function Ensure-ElevatedSession {
    if (Test-IsAdministrator) {
        return
    }

    $shellPath = Get-PreferredPowerShellExecutable
    if (-not $shellPath) {
        throw 'Could not find pwsh.exe or powershell.exe.'
    }

    $argumentList = @(
        '-NoLogo',
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath
    )
    if ($Resume) {
        $argumentList += '-Resume'
    }

    $currentInstallLogPath = Get-CurrentInstallSessionLogPath
    if (Test-HermesAbsolutePath -Path $currentInstallLogPath) {
        $argumentList += @('-InstallLogPath', $currentInstallLogPath)
    }

    $currentInstallLogSessionId = Get-CurrentInstallSessionId
    if (-not [string]::IsNullOrWhiteSpace($currentInstallLogSessionId)) {
        $argumentList += @('-InstallLogSessionId', $currentInstallLogSessionId)
    }

    if (Test-HermesAbsolutePath -Path $currentInstallLogPath) {
        Write-Step ("正在请求管理员权限，将继续写入当前日志：{0}" -f $currentInstallLogPath)
    }
    else {
        Write-Step '正在请求管理员权限。'
    }

    Start-Process -FilePath $shellPath -Verb RunAs -ArgumentList (Join-CommandLineArguments -Arguments $argumentList) | Out-Null
    exit 0
}

function Test-SelectionStateComplete {
    $state = Get-HermesState
    if ($null -eq $state) { return $false }
    if ([string]$state.repo_root -ne $paths.RepoRoot) { return $false }
    if (-not $state.install_mode -or -not $state.provider_mode) { return $false }
    if (-not $state.selected_distro -or -not $state.selected_user) { return $false }
    if (-not $state.base_url -or -not $state.model -or -not $state.api_mode) { return $false }
    return $true
}

function Show-InstallWizard {
    param([Parameter(Mandatory = $true)]$CurrentConfig)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $defaults = Get-HermesDefaults
    $reuseCandidates = @(Get-WslReuseCandidates)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Hermes Windows 安装设置'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(760, 610)
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $groupMode = New-Object System.Windows.Forms.GroupBox
    $groupMode.Text = '1. WSL 安装方式'
    $groupMode.Location = New-Object System.Drawing.Point(16, 16)
    $groupMode.Size = New-Object System.Drawing.Size(712, 170)
    $form.Controls.Add($groupMode)

    $radioDedicated = New-Object System.Windows.Forms.RadioButton
    $radioDedicated.Text = '新建 Hermes 专用发行版'
    $radioDedicated.Location = New-Object System.Drawing.Point(16, 28)
    $radioDedicated.Size = New-Object System.Drawing.Size(220, 24)
    $radioDedicated.Checked = ($CurrentConfig.InstallMode -ne 'reuse-existing' -or $reuseCandidates.Count -eq 0)
    $groupMode.Controls.Add($radioDedicated)

    $labelDedicated = New-Object System.Windows.Forms.Label
    $labelDedicated.Text = '专用发行版名称'
    $labelDedicated.Location = New-Object System.Drawing.Point(40, 60)
    $labelDedicated.Size = New-Object System.Drawing.Size(120, 20)
    $groupMode.Controls.Add($labelDedicated)

    $textDedicated = New-Object System.Windows.Forms.TextBox
    $textDedicated.Location = New-Object System.Drawing.Point(170, 56)
    $textDedicated.Size = New-Object System.Drawing.Size(250, 24)
    $textDedicated.ReadOnly = $true
    $textDedicated.Text = $defaults.DistroName
    $groupMode.Controls.Add($textDedicated)

    $labelDedicatedDesc = New-Object System.Windows.Forms.Label
    $labelDedicatedDesc.Text = '会忽略用户现有的其它 WSL 发行版，只管理 Hermes 自己的专用环境。'
    $labelDedicatedDesc.Location = New-Object System.Drawing.Point(40, 88)
    $labelDedicatedDesc.Size = New-Object System.Drawing.Size(620, 20)
    $groupMode.Controls.Add($labelDedicatedDesc)

    $radioReuse = New-Object System.Windows.Forms.RadioButton
    $radioReuse.Text = '复用现有 Ubuntu / Debian WSL2'
    $radioReuse.Location = New-Object System.Drawing.Point(16, 118)
    $radioReuse.Size = New-Object System.Drawing.Size(280, 24)
    $radioReuse.Enabled = $reuseCandidates.Count -gt 0
    $radioReuse.Checked = ($CurrentConfig.InstallMode -eq 'reuse-existing' -and $reuseCandidates.Count -gt 0)
    $groupMode.Controls.Add($radioReuse)

    $comboReuse = New-Object System.Windows.Forms.ComboBox
    $comboReuse.Location = New-Object System.Drawing.Point(300, 118)
    $comboReuse.Size = New-Object System.Drawing.Size(390, 24)
    $comboReuse.DropDownStyle = 'DropDownList'
    foreach ($candidate in $reuseCandidates) {
        $comboReuse.Items.Add(('{0}  |  {1}  |  默认用户 {2}' -f $candidate.DistroName, $candidate.PrettyName, $candidate.DefaultUser)) | Out-Null
    }
    if ($comboReuse.Items.Count -gt 0) {
        $preferredIndex = 0
        for ($index = 0; $index -lt $reuseCandidates.Count; $index++) {
            if ($reuseCandidates[$index].DistroName -eq $CurrentConfig.DistroName) {
                $preferredIndex = $index
                break
            }
        }
        $comboReuse.SelectedIndex = $preferredIndex
    }
    $comboReuse.Enabled = $radioReuse.Checked
    $groupMode.Controls.Add($comboReuse)

    $labelReuseEmpty = New-Object System.Windows.Forms.Label
    $labelReuseEmpty.Text = if ($reuseCandidates.Count -gt 0) { '' } else { '当前没有可正式复用的 Ubuntu / Debian WSL2 发行版，安装器将改走专用发行版路径。' }
    $labelReuseEmpty.Location = New-Object System.Drawing.Point(40, 144)
    $labelReuseEmpty.Size = New-Object System.Drawing.Size(650, 20)
    $groupMode.Controls.Add($labelReuseEmpty)

    $groupProvider = New-Object System.Windows.Forms.GroupBox
    $groupProvider.Text = '2. Provider'
    $groupProvider.Location = New-Object System.Drawing.Point(16, 202)
    $groupProvider.Size = New-Object System.Drawing.Size(712, 220)
    $form.Controls.Add($groupProvider)

    $radioQiuQiu = New-Object System.Windows.Forms.RadioButton
    $radioQiuQiu.Text = '默认球球 token 路线'
    $radioQiuQiu.Location = New-Object System.Drawing.Point(16, 28)
    $radioQiuQiu.Size = New-Object System.Drawing.Size(220, 24)
    $radioQiuQiu.Checked = ($CurrentConfig.ProviderMode -ne 'custom-openai')
    $groupProvider.Controls.Add($radioQiuQiu)

    $radioCustom = New-Object System.Windows.Forms.RadioButton
    $radioCustom.Text = '自定义 OpenAI 兼容接口'
    $radioCustom.Location = New-Object System.Drawing.Point(16, 58)
    $radioCustom.Size = New-Object System.Drawing.Size(240, 24)
    $radioCustom.Checked = ($CurrentConfig.ProviderMode -eq 'custom-openai')
    $groupProvider.Controls.Add($radioCustom)

    $labelBaseUrl = New-Object System.Windows.Forms.Label
    $labelBaseUrl.Text = 'Base URL'
    $labelBaseUrl.Location = New-Object System.Drawing.Point(40, 96)
    $labelBaseUrl.Size = New-Object System.Drawing.Size(110, 20)
    $groupProvider.Controls.Add($labelBaseUrl)

    $textBaseUrl = New-Object System.Windows.Forms.TextBox
    $textBaseUrl.Location = New-Object System.Drawing.Point(156, 92)
    $textBaseUrl.Size = New-Object System.Drawing.Size(520, 24)
    $textBaseUrl.Text = $CurrentConfig.BaseUrl
    $groupProvider.Controls.Add($textBaseUrl)

    $labelModel = New-Object System.Windows.Forms.Label
    $labelModel.Text = 'Model'
    $labelModel.Location = New-Object System.Drawing.Point(40, 132)
    $labelModel.Size = New-Object System.Drawing.Size(110, 20)
    $groupProvider.Controls.Add($labelModel)

    $textModel = New-Object System.Windows.Forms.TextBox
    $textModel.Location = New-Object System.Drawing.Point(156, 128)
    $textModel.Size = New-Object System.Drawing.Size(520, 24)
    $textModel.Text = $CurrentConfig.Model
    $groupProvider.Controls.Add($textModel)

    $labelApiMode = New-Object System.Windows.Forms.Label
    $labelApiMode.Text = 'API Mode'
    $labelApiMode.Location = New-Object System.Drawing.Point(40, 168)
    $labelApiMode.Size = New-Object System.Drawing.Size(110, 20)
    $groupProvider.Controls.Add($labelApiMode)

    $comboApiMode = New-Object System.Windows.Forms.ComboBox
    $comboApiMode.Location = New-Object System.Drawing.Point(156, 164)
    $comboApiMode.Size = New-Object System.Drawing.Size(240, 24)
    $comboApiMode.DropDownStyle = 'DropDownList'
    foreach ($item in @('codex_responses', 'chat_completions', 'anthropic_messages', 'bedrock_converse')) {
        $comboApiMode.Items.Add($item) | Out-Null
    }
    $preferredApiModeIndex = [Math]::Max($comboApiMode.Items.IndexOf($CurrentConfig.ApiMode), 0)
    $comboApiMode.SelectedIndex = $preferredApiModeIndex
    $groupProvider.Controls.Add($comboApiMode)

    $labelProviderDesc = New-Object System.Windows.Forms.Label
    $labelProviderDesc.Text = '说明：密钥不会在这里输入，稍后会通过本地安全弹窗单独收集。'
    $labelProviderDesc.Location = New-Object System.Drawing.Point(40, 196)
    $labelProviderDesc.Size = New-Object System.Drawing.Size(560, 20)
    $groupProvider.Controls.Add($labelProviderDesc)

    $groupIntegrations = New-Object System.Windows.Forms.GroupBox
    $groupIntegrations.Text = '3. 通讯与面板'
    $groupIntegrations.Location = New-Object System.Drawing.Point(16, 438)
    $groupIntegrations.Size = New-Object System.Drawing.Size(712, 86)
    $form.Controls.Add($groupIntegrations)

    $labelMessaging = New-Object System.Windows.Forms.Label
    $labelMessaging.Text = '通讯工具：微信（本轮正式支持）'
    $labelMessaging.Location = New-Object System.Drawing.Point(16, 28)
    $labelMessaging.Size = New-Object System.Drawing.Size(300, 20)
    $groupIntegrations.Controls.Add($labelMessaging)

    $labelWebUi = New-Object System.Windows.Forms.Label
    $labelWebUi.Text = '管理面板：安装完成后自动打开一次，后续按需启动'
    $labelWebUi.Location = New-Object System.Drawing.Point(16, 52)
    $labelWebUi.Size = New-Object System.Drawing.Size(420, 20)
    $groupIntegrations.Controls.Add($labelWebUi)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '开始安装'
    $okButton.Location = New-Object System.Drawing.Point(532, 534)
    $okButton.Size = New-Object System.Drawing.Size(90, 30)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(638, 534)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 30)
    $form.Controls.Add($cancelButton)

    $setProviderFields = {
        $useCustom = $radioCustom.Checked
        $textBaseUrl.Enabled = $useCustom
        $textModel.Enabled = $useCustom
        $comboApiMode.Enabled = $useCustom
    }
    $setReuseFields = {
        $comboReuse.Enabled = $radioReuse.Checked
    }

    $radioCustom.Add_CheckedChanged($setProviderFields)
    $radioQiuQiu.Add_CheckedChanged($setProviderFields)
    $radioReuse.Add_CheckedChanged($setReuseFields)
    $radioDedicated.Add_CheckedChanged($setReuseFields)

    & $setProviderFields
    & $setReuseFields

    $okButton.Add_Click({
        if ($radioReuse.Checked -and $comboReuse.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show('请选择一个可复用的 Ubuntu / Debian WSL2 发行版。', 'Hermes 安装', 'OK', 'Warning') | Out-Null
            return
        }

        if ($radioCustom.Checked) {
            if ([string]::IsNullOrWhiteSpace($textBaseUrl.Text) -or [string]::IsNullOrWhiteSpace($textModel.Text) -or $comboApiMode.SelectedIndex -lt 0) {
                [System.Windows.Forms.MessageBox]::Show('请补全自定义 provider 的 Base URL、Model 和 API Mode。', 'Hermes 安装', 'OK', 'Warning') | Out-Null
                return
            }
        }

        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $cancelButton.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $dialogResult = $form.ShowDialog()
    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $selectedCandidate = $null
    if ($radioReuse.Checked -and $comboReuse.SelectedIndex -ge 0) {
        $selectedCandidate = $reuseCandidates[$comboReuse.SelectedIndex]
    }

    $installMode = if ($radioReuse.Checked -and $null -ne $selectedCandidate) { 'reuse-existing' } else { 'dedicated' }
    $providerMode = if ($radioCustom.Checked) { 'custom-openai' } else { 'qiuqiu' }
    $baseUrl = if ($providerMode -eq 'custom-openai') { $textBaseUrl.Text.Trim() } else { $defaults.BaseUrl }
    $model = if ($providerMode -eq 'custom-openai') { $textModel.Text.Trim() } else { $defaults.Model }
    $apiMode = if ($providerMode -eq 'custom-openai') { [string]$comboApiMode.SelectedItem } else { $defaults.ApiMode }
    $distroName = if ($installMode -eq 'reuse-existing') { $selectedCandidate.DistroName } else { $defaults.DistroName }
    $username = if ($installMode -eq 'reuse-existing') { $selectedCandidate.DefaultUser } else { $defaults.Username }

    return [PSCustomObject]@{
        DistroName        = $distroName
        Username          = $username
        BaseUrl           = $baseUrl
        Model             = $model
        ApiMode           = $apiMode
        InstallMode       = $installMode
        TargetKind        = $(if ($installMode -eq 'reuse-existing') { 'existing-distro' } else { 'managed-distro' })
        ProviderMode      = $providerMode
        MessagingMode     = 'wechat'
        SelectedDistro    = $distroName
        SelectedUser      = $username
        ReuseSourceDistro = $(if ($installMode -eq 'reuse-existing') { $selectedCandidate.DistroName } else { '' })
        AptPrimaryUrl     = $CurrentConfig.AptPrimaryUrl
        AptSecurityUrl    = $CurrentConfig.AptSecurityUrl
        NodeMajorVersion  = $CurrentConfig.NodeMajorVersion
        NodeDistMirrorUrl = $CurrentConfig.NodeDistMirrorUrl
        NodeArchiveName   = $CurrentConfig.NodeArchiveName
        NpmRegistryUrl    = $CurrentConfig.NpmRegistryUrl
        WebUiVersion      = $CurrentConfig.WebUiVersion
        WebUiArchiveName  = $CurrentConfig.WebUiArchiveName
        WebUiUrl          = $CurrentConfig.WebUiUrl
        WebUiPort         = $CurrentConfig.WebUiPort
        PackageUrl        = $CurrentConfig.PackageUrl
        PackageName       = $CurrentConfig.PackageName
        BaseImageName     = $CurrentConfig.BaseImageName
        BaseImageAltName  = $CurrentConfig.BaseImageAltName
        BaseImageMode     = $CurrentConfig.BaseImageMode
        InstallScriptUrl  = $CurrentConfig.InstallScriptUrl
        InstallScriptName = $CurrentConfig.InstallScriptName
        SourceArchiveUrl  = $CurrentConfig.SourceArchiveUrl
        SourceArchiveName = $CurrentConfig.SourceArchiveName
        InstallEnvPresent = $CurrentConfig.InstallEnvPresent
        IgnoredKeys       = $CurrentConfig.IgnoredKeys
    }
}

function Ensure-InstallSelection {
    if ($Resume -and (Test-SelectionStateComplete)) {
        return Get-ResolvedInstallConfig
    }

    if (Test-SelectionStateComplete) {
        return Get-ResolvedInstallConfig
    }

    $currentConfig = Get-ResolvedInstallConfig
    $selection = Show-InstallWizard -CurrentConfig $currentConfig
    if ($null -eq $selection) {
        exit 3
    }

    Save-HermesState -Stage 'selection-complete' -Config $selection -LastResult 'selection-complete'
    $completed.Add(("Selected install mode: {0}" -f $selection.InstallMode))
    $completed.Add(("Selected distro target: {0}" -f $selection.DistroName))
    $completed.Add(("Selected provider mode: {0}" -f $selection.ProviderMode))
    return Get-ResolvedInstallConfig
}

function Invoke-Prefetch {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $result = & $paths.PrefetchPs
    if ($null -eq $result -or $result.Status -ne 'ready') {
        throw 'windows-prefetch-assets.ps1 did not return a ready status.'
    }
    $completed.Add('Prepared the Windows-side installer assets in downloads.')
}

function Invoke-PrepareTarget {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    if ($ResolvedConfig.InstallMode -eq 'reuse-existing') {
        return (& $paths.ReusePs)
    }

    return (& "$PSScriptRoot\windows-bootstrap.ps1")
}

function Verify-InstalledTarget {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $whoami = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command 'whoami' -TimeoutSeconds 30 -RequireSuccess
    if ($whoami.Trim() -ne $ResolvedConfig.Username) {
        throw "Default user verification failed. whoami returned: $whoami"
    }

    $bootstrapMode = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User 'root' -Command 'cat /var/lib/hermes-bootstrap/bootstrap_mode 2>/dev/null || true'
    if ($bootstrapMode.Trim() -in @('prebuilt-base-image', 'reuse-existing-distro')) {
        $helperProbe = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User 'root' -Command 'test -x /usr/local/bin/hermes-inject-key.sh && echo ok' -TimeoutSeconds 30 -RequireSuccess
        if ($helperProbe.Trim() -ne 'ok') {
            throw 'The local key injection helper is missing inside WSL.'
        }
    }
    else {
        $schema = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User 'root' -Command 'cloud-init schema --system' -TimeoutSeconds 60 -RequireSuccess
        if ($schema -notmatch 'Valid schema user-data') {
            throw "cloud-init schema validation failed: $schema"
        }
    }

    $version = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command '~/.local/bin/hermes version' -TimeoutSeconds 60 -RequireSuccess
    $doctor = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command '~/.local/bin/hermes doctor' -TimeoutSeconds 180 -RequireSuccess
    $status = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command '~/.local/bin/hermes status' -TimeoutSeconds 120 -RequireSuccess
    $smoke = Invoke-WslBash `
        -Distro $ResolvedConfig.DistroName `
        -User $ResolvedConfig.Username `
        -Command "~/.local/bin/hermes chat -q 'Reply with exactly OK and nothing else.'" `
        -TimeoutSeconds 300 `
        -ProgressMessage 'Hermes chat 冒烟测试仍在等待模型响应。' `
        -ProgressIntervalSeconds 30 `
        -RequireSuccess

    if (-not $version) { throw 'hermes version returned no output.' }
    if (-not $doctor) { throw 'hermes doctor returned no output.' }
    if (-not $status) { throw 'hermes status returned no output.' }
    if ($smoke -notmatch '(^|[^A-Z])OK([^A-Z]|$)') {
        throw "Chat smoke result was unexpected: $smoke"
    }

    return [PSCustomObject]@{
        BootstrapMode = $bootstrapMode.Trim()
    }
}

function Test-HermesKeyAlreadyInjected {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $command = @'
if [ -f /var/lib/hermes-bootstrap/key_status ] && [ "$(cat /var/lib/hermes-bootstrap/key_status 2>/dev/null)" = "success" ] && [ -f "$HOME/.hermes/.env" ]; then
  echo ready
else
  echo missing
fi
'@

    try {
        $probe = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command $command -TimeoutSeconds 20
        return $probe.Trim() -eq 'ready'
    }
    catch {
        return $false
    }
}

function Show-WeChatRoundTripPrompt {
    Add-Type -AssemblyName System.Windows.Forms

    $message = @(
        'Hermes 已经完成 WSL 安装、微信绑定、gateway 启动和 WebUI 初始化。',
        '',
        '现在请在微信里给 Hermes 发送一条测试消息，例如：',
        'ping',
        '',
        '如果已经收到正常回复，点击“是”。',
        '如果还没有收到回复，点击“否”；当前环境会保留，之后重新运行安装器即可继续排查。'
    ) -join [Environment]::NewLine

    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Hermes 微信可用性确认',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

try {
    $installLogSession = Resolve-InstallLogSession
    $env:HERMES_INSTALL_LOG_PATH = $installLogSession.FinalLogPath
    $env:HERMES_INSTALL_LOG_SESSION_ID = $installLogSession.SessionId
    Start-Transcript -Path $installLogSession.FinalLogPath -Append -Force | Out-Null
    $transcriptStarted = $true
    Write-Step ("本次安装日志：{0}" -f $installLogSession.FinalLogPath)
    Write-Step ("安装日志会话 ID：{0}" -f $installLogSession.SessionId)
    if ($Resume) {
        Write-Step ("已从上次进度恢复，继续写入同一日志。当前进程 PID={0}" -f $PID)
    }
    elseif ((Test-HermesAbsolutePath -Path $InstallLogPath) -or (-not [string]::IsNullOrWhiteSpace($InstallLogSessionId))) {
        Write-Step ("已接续现有安装日志会话。当前进程 PID={0}" -f $PID)
    }
    else {
        Write-Step ("安装日志已开始实时写入。当前进程 PID={0}" -f $PID)
    }

    try {
        Ensure-ElevatedSession
        Ensure-Directory -Path $paths.Downloads
        Ensure-Directory -Path $paths.StateRoot
        if ($Resume) {
            Show-HermesResumeNotice
        }

        Write-Phase -Index 1 -Total $totalPhases -Message '收集本机安装选项并保存恢复状态'
        $config = Ensure-InstallSelection
        Write-Phase -Index 2 -Total $totalPhases -Message '在接触 WSL 之前准备 Windows 侧缓存资源'
        Invoke-Prefetch -ResolvedConfig $config
        Save-HermesState -Stage 'assets-ready' -Config $config -LastResult 'assets-ready'

        Write-Phase -Index 3 -Total $totalPhases -Message '准备所选的 WSL 目标环境'
        $prepareResult = Invoke-PrepareTarget -ResolvedConfig $config
        if ($prepareResult.Status -eq 'blocked-reboot') {
            $completed.Add(("已注册重启恢复入口：{0}" -f $prepareResult.ResumeMethod))
            exit 2
        }

        if ($prepareResult.Status -eq 'already-installed') {
            $completed.Add('检测到已有 Hermes 托管安装，已跳过 WSL 重装。')
        }
        elseif ($prepareResult.Status -eq 'ready-for-key') {
            $completed.Add('已准备好目标 WSL 环境，并进入本地 key 输入阶段。')
        }
        else {
            throw "Target preparation returned an unknown status: $($prepareResult.Status)"
        }

        Write-Phase -Index 4 -Total $totalPhases -Message '按需触发本地 provider key 输入'
        if (Test-HermesKeyAlreadyInjected -ResolvedConfig $config) {
            $completed.Add('检测到已有成功的 key 注入记录，已跳过重复输入。')
            Save-HermesState -Stage 'key-injected' -Config $config -LastResult 'key-injected'
        }
        else {
            $keyResult = & "$PSScriptRoot\windows-enter-key.ps1"
            if ($keyResult.Status -eq 'cancelled') {
                exit 4
            }

            if ($keyResult.Status -ne 'success') {
                throw "Key injection returned an unknown status: $($keyResult.Status)"
            }

            $completed.Add('已完成本地 provider key 输入和 WSL 内 key 注入。')
        }

        Write-Phase -Index 5 -Total $totalPhases -Message '验证目标环境并执行 Hermes 冒烟检查'
        $verifyResult = Verify-InstalledTarget -ResolvedConfig $config
        Save-HermesState -Stage 'hermes-verified' -Config $config -LastResult 'hermes-verified'
        $completed.Add(("已验证默认用户：whoami={0}" -f $config.Username))
        if ($verifyResult.BootstrapMode -eq 'reuse-existing-distro') {
            $completed.Add('已验证复用的发行版仍保留本地 key 注入辅助脚本。')
        }
        elseif ($verifyResult.BootstrapMode -eq 'prebuilt-base-image') {
            $completed.Add('已验证导入的预构建基础镜像仍保留本地 key 注入辅助脚本。')
        }
        else {
            $completed.Add('已验证 cloud-init schema --system 返回 Valid schema user-data。')
        }
        $completed.Add('已验证 hermes version、doctor、status 和聊天冒烟测试。')

        Write-Phase -Index 6 -Total $totalPhases -Message '引导用户完成原生 Weixin 绑定并启动 gateway'
        $wechatResult = & "$PSScriptRoot\windows-configure-wechat.ps1"
        Register-SupplementalInstallLogPath -Path $wechatResult.WindowLogPath
        if ($wechatResult.Status -eq 'cancelled') {
            exit 5
        }

        if ($wechatResult.Status -eq 'failed') {
            $wechatFailure = "Weixin setup failed before Hermes stored any credentials. Exit code: $($wechatResult.ExitCode)"
            if ($wechatResult.LogTail) {
                $wechatFailure = "$wechatFailure`nVisible setup window tail:`n$($wechatResult.LogTail)"
            }
            throw $wechatFailure
        }

        if ($wechatResult.Status -eq 'already-bound') {
            $completed.Add('检测到已有 Weixin 绑定，已跳过重新扫码登录。')
        }
        elseif ($wechatResult.Status -eq 'success') {
            $completed.Add('已完成原生 Weixin 扫码绑定，并保存账号凭据。')
        }
        else {
            throw "Weixin setup returned an unknown status: $($wechatResult.Status)"
        }

        $gatewayResult = & "$PSScriptRoot\windows-start-gateway.ps1"
        if ($gatewayResult.Status -eq 'not-configured' -or $gatewayResult.Status -eq 'reauth-required') {
            exit 6
        }

        if ($gatewayResult.Status -eq 'already-running') {
            $completed.Add('检测到 hermes gateway run 已在运行。')
        }
        elseif ($gatewayResult.Status -eq 'success') {
            $completed.Add('已在 WSL 内启动 hermes gateway run。')
        }
        else {
            throw "Gateway startup returned an unknown status: $($gatewayResult.Status)"
        }

        if (-not (Test-HermesGatewayAutostartRegistered)) {
            $registrationMethod = Register-HermesGatewayAutostart
            $completed.Add(("已注册 Windows 登录自启动（HKCU Run）：{0}" -f $registrationMethod))
        }
        else {
            $completed.Add('保留了现有的 gateway Windows 登录自启动注册项。')
        }

        Save-HermesState -Stage 'gateway-running' -Config $config -LastResult 'gateway-running'

        Write-Phase -Index 7 -Total $totalPhases -Message '安装并打开 Hermes WebUI 管理面板'
        $webUiInstallResult = & $paths.WebUiPs -Action Install
        if ($webUiInstallResult.Status -ne 'installed') {
            throw "WebUI install returned an unknown status: $($webUiInstallResult.Status)"
        }

        $webUiStartResult = & $paths.WebUiPs -Action Start
        if ($webUiStartResult.Status -notin @('started', 'already-running')) {
            throw "WebUI start returned an unknown status: $($webUiStartResult.Status)"
        }

        $webUiOpenResult = & $paths.WebUiPs -Action Open
        if ($webUiOpenResult.Status -ne 'opened') {
            throw "WebUI open returned an unknown status: $($webUiOpenResult.Status)"
        }

        $completed.Add('已安装 Hermes WebUI 本地管理文件。')
        if ($webUiStartResult.Status -eq 'already-running') {
            $completed.Add('检测到 Hermes WebUI 已在运行。')
        }
        else {
            $completed.Add('已启动 Hermes WebUI 进程。')
        }
        $completed.Add('已在默认浏览器中打开 Hermes WebUI。')
        Save-HermesState -Stage 'webui-running' -Config $config -LastResult 'webui-running'

        Write-Phase -Index 8 -Total $totalPhases -Message '请用户确认一次真实的微信往返消息'
        if (-not (Show-WeChatRoundTripPrompt)) {
            Save-HermesState -Stage 'webui-running' -Config $config -LastResult 'awaiting-wechat-roundtrip'
            exit 7
        }

        Save-HermesState -Stage 'success' -Config $config -LastResult 'success'
        Unregister-HermesResume
        $completed.Add('已记录用户确认的真实微信往返成功。')
        Write-Step '安装完成：WSL、Hermes、Weixin 绑定、gateway 启动、WebUI 设置和微信往返确认均已通过。'
        return [PSCustomObject]@{
            Status     = 'success'
            DistroName = $config.DistroName
            Username   = $config.Username
        }
    }
    catch {
        $failureRecord = $_
        Write-ExceptionDiagnostics -Record $failureRecord

        $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
        try {
            Save-HermesState -Stage 'failed' -Config $configForFailure -LastResult $failureRecord.Exception.Message
        }
        catch {
            Write-Step ("保存失败状态时再次报错：{0}" -f $_.Exception.Message)
        }

        throw
    }
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }

    if ($null -ne $installLogSession) {
        try {
            Finalize-HermesInstallLogSession -Session $installLogSession -SupplementalLogPaths $supplementalLogPaths.ToArray()
        }
        catch {
            Write-Step ("追加补充日志失败：{0}" -f $_.Exception.Message)
        }
    }

    Remove-Item Env:HERMES_INSTALL_LOG_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:HERMES_INSTALL_LOG_SESSION_ID -ErrorAction SilentlyContinue
}
