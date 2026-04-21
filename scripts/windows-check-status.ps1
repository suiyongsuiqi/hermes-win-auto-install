[CmdletBinding()]
param(
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

try {
    $config = Get-ResolvedInstallConfig
    $snapshot = Get-HermesManagedInstallSnapshot -Config $config
    $latestLogPath = if ($snapshot.LatestInstallLogPath) { [string]$snapshot.LatestInstallLogPath } else { Get-HermesLatestInstallLogPath }

    $payload = [ordered]@{
        repo_root               = (Get-HermesPaths).RepoRoot
        distro_name             = $config.DistroName
        username                = $config.Username
        state_stage             = [string]$snapshot.StateStage
        state_last_result       = [string]$snapshot.StateLastResult
        state_updated_at        = [string]$snapshot.StateUpdatedAt
        canonical_stage         = [string]$snapshot.CanonicalStage
        canonical_last_result   = [string]$snapshot.CanonicalLastResult
        distro_exists           = [bool]$snapshot.DistroExists
        distro_healthy          = [bool]$snapshot.DistroHealthy
        managed_marker_present  = [bool]$snapshot.ManagedMarkerPresent
        user_healthy            = [bool]$snapshot.UserHealthy
        bootstrap_stage         = [string]$snapshot.BootstrapStage
        bootstrap_result        = [string]$snapshot.BootstrapResult
        bootstrap_failed_stage  = [string]$snapshot.BootstrapFailedStage
        cloud_init_status       = [string]$snapshot.CloudInitStatusState
        cloud_init_extended     = [string]$snapshot.CloudInitExtendedStatus
        key_status              = [string]$snapshot.KeyStatus
        key_injected            = [bool]$snapshot.KeyInjected
        weixin_configured       = [bool]$snapshot.WeixinConfigured
        weixin_account_count    = [int]$snapshot.WeixinAccountCount
        gateway_running         = [bool]$snapshot.GatewayRunning
        webui_installed         = [bool]$snapshot.WebUiInstalled
        webui_running           = [bool]$snapshot.WebUiRunning
        autostart_registered    = [bool]$snapshot.AutostartRegistered
        latest_install_log      = $latestLogPath
        bootstrap_probe_error   = [string]$snapshot.BootstrapProbeError
        user_probe_error        = [string]$snapshot.UserProbeError
        recommended_action      = [string]$snapshot.RecommendedAction
    }

    if ($Json) {
        $payload | ConvertTo-Json -Depth 6
        return
    }

    Write-Host 'Hermes Windows Status'
    Write-Host ('repo_root              : {0}' -f $payload.repo_root)
    Write-Host ('distro_name            : {0}' -f $payload.distro_name)
    Write-Host ('username               : {0}' -f $payload.username)
    Write-Host ('state_stage            : {0}' -f $payload.state_stage)
    Write-Host ('state_last_result      : {0}' -f $payload.state_last_result)
    Write-Host ('state_updated_at       : {0}' -f $payload.state_updated_at)
    Write-Host ('canonical_stage        : {0}' -f $payload.canonical_stage)
    Write-Host ('canonical_last_result  : {0}' -f $payload.canonical_last_result)
    Write-Host ('distro_exists          : {0}' -f $payload.distro_exists)
    Write-Host ('distro_healthy         : {0}' -f $payload.distro_healthy)
    Write-Host ('managed_marker_present : {0}' -f $payload.managed_marker_present)
    Write-Host ('user_healthy           : {0}' -f $payload.user_healthy)
    Write-Host ('bootstrap_stage        : {0}' -f $payload.bootstrap_stage)
    Write-Host ('bootstrap_result       : {0}' -f $payload.bootstrap_result)
    Write-Host ('bootstrap_failed_stage : {0}' -f $payload.bootstrap_failed_stage)
    Write-Host ('cloud_init_status      : {0}' -f $payload.cloud_init_status)
    Write-Host ('cloud_init_extended    : {0}' -f $payload.cloud_init_extended)
    Write-Host ('key_status             : {0}' -f $payload.key_status)
    Write-Host ('key_injected           : {0}' -f $payload.key_injected)
    Write-Host ('weixin_configured      : {0}' -f $payload.weixin_configured)
    Write-Host ('weixin_account_count   : {0}' -f $payload.weixin_account_count)
    Write-Host ('gateway_running        : {0}' -f $payload.gateway_running)
    Write-Host ('webui_installed        : {0}' -f $payload.webui_installed)
    Write-Host ('webui_running          : {0}' -f $payload.webui_running)
    Write-Host ('autostart_registered   : {0}' -f $payload.autostart_registered)
    Write-Host ('latest_install_log     : {0}' -f $payload.latest_install_log)
    if ($payload.bootstrap_probe_error) {
        Write-Host ('bootstrap_probe_error : {0}' -f $payload.bootstrap_probe_error)
    }
    if ($payload.user_probe_error) {
        Write-Host ('user_probe_error      : {0}' -f $payload.user_probe_error)
    }
    Write-Host ('recommended_action     : {0}' -f $payload.recommended_action)

    return [PSCustomObject]$payload
}
catch {
    Write-Error $_
    throw
}
