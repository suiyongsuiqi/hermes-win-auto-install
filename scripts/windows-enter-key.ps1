[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$completed = New-Object System.Collections.Generic.List[string]

function Show-KeyPrompt {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $formTitle = Convert-FromUtf8Base64 'SGVybWVzIOWuieijhSAtIOi+k+WFpSBBUEkgS2V5'
    $labelText = Convert-FromUtf8Base64 '6K+36L6T5YWl5LiA5qyhIEhlcm1lcyBBUEkgS2V544CC5a6D5Y+q5Lya6KKr5rOo5YWlIFdTTO+8jOS4jeS8muWGmeWFpeiBiuWkqeOAgeS7u+WKoei/m+W6puaIluS7k+W6k+aWh+S7tuOAgg=='
    $emptyMessage = Convert-FromUtf8Base64 'QVBJIEtleSDkuI3og73kuLrnqbrjgII='
    $dialogTitle = Convert-FromUtf8Base64 'SGVybWVzIOWuieijhQ=='
    $okText = Convert-FromUtf8Base64 '56Gu5a6a'
    $cancelText = Convert-FromUtf8Base64 '5Y+W5raI'

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $formTitle
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(520, 220)
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $label.Size = New-Object System.Drawing.Size(470, 40)
    $label.Text = $labelText
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(20, 80)
    $textBox.Size = New-Object System.Drawing.Size(470, 24)
    $textBox.UseSystemPasswordChar = $true
    $form.Controls.Add($textBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(290, 130)
    $okButton.Size = New-Object System.Drawing.Size(90, 30)
    $okButton.Text = $okText
    $okButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($textBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show($emptyMessage, $dialogTitle, 'OK', 'Warning') | Out-Null
            return
        }
        $form.Tag = $textBox.Text
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(400, 130)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 30)
    $cancelButton.Text = $cancelText
    $cancelButton.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $null = $textBox.Focus()

    $dialog = $form.ShowDialog()
    if ($dialog -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return [string]$form.Tag
}

function Invoke-KeyInjection {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$ApiKey
    )
    $result = Invoke-WslProcess `
        -Arguments @('-d', $DistroName, '-u', 'root', '--', 'bash', '-lc', '/usr/local/bin/hermes-inject-key.sh') `
        -StandardInput ($ApiKey + [Environment]::NewLine) `
        -TimeoutSeconds 60 `
        -RequireSuccess

    if ($result.ExitCode -ne 0) {
        throw "Key injection failed. $($result.Text)"
    }
}

try {
    $config = Get-ResolvedInstallConfig
    Write-Step '开始执行本地 key 注入。'

    if (-not (Test-WslDistributionHealthy -Name $config.DistroName)) {
        throw "Distribution $($config.DistroName) is not healthy yet."
    }

    $helperProbe = Invoke-WslBash -Distro $config.DistroName -User 'root' -Command 'test -x /usr/local/bin/hermes-inject-key.sh && echo ok' -TimeoutSeconds 15
    if ($helperProbe -ne 'ok') {
        throw 'Missing /usr/local/bin/hermes-inject-key.sh inside WSL.'
    }

    $completed.Add('Confirmed the target distribution is healthy.')
    $completed.Add('Confirmed the helper script exists inside WSL.')

    $apiKey = Show-KeyPrompt
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return [PSCustomObject]@{
            Status     = 'cancelled'
            DistroName = $config.DistroName
            Username   = $config.Username
        }
    }

    Invoke-KeyInjection -DistroName $config.DistroName -ApiKey $apiKey
    $apiKey = ''
    Save-HermesState -Stage 'key-injected' -Config $config -LastResult 'key-injected'
    $completed.Add('Injected the user-provided API key into WSL through stdin.')
    $completed.Add('Updated the WSL-side Hermes .env and config.yaml files.')

    return [PSCustomObject]@{
        Status     = 'success'
        DistroName = $config.DistroName
        Username   = $config.Username
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'key-injection-failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
