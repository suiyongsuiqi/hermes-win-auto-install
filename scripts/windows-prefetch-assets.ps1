[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$paths = Get-HermesPaths
$completed = New-Object System.Collections.Generic.List[string]

try {
    $config = Get-ResolvedInstallConfig
    $nodeSpec = Get-NodeLinuxAssetSpec -Config $config
    Ensure-Directory -Path $paths.Downloads
    Ensure-Directory -Path $paths.StateRoot

    Write-Step '开始执行 Windows 侧安装资源预取阶段。'
    $completed.Add('已确认 downloads 目录存在，然后开始本地预取阶段。')

    $baseImagePath = Get-ExistingHermesBaseImagePath
    if (-not [string]::IsNullOrWhiteSpace($baseImagePath)) {
        $completed.Add(("检测到预构建 Hermes 基础镜像：{0}" -f $baseImagePath))
    }

    $assets = New-Object System.Collections.Generic.List[object]
    if ($config.InstallMode -eq 'dedicated' -and [string]::IsNullOrWhiteSpace($baseImagePath)) {
        $assets.Add([PSCustomObject]@{
            Name        = 'Ubuntu WSL 安装包'
            Path        = Join-Path $paths.Downloads $config.PackageName
            Url         = $config.PackageUrl
            Activity    = '正在下载 Ubuntu WSL 安装包'
            StatusLabel = 'Ubuntu WSL 安装包下载'
        })
    }

    @(
        [PSCustomObject]@{
            Name        = 'Hermes 安装脚本'
            Path        = Join-Path $paths.Downloads $config.InstallScriptName
            Url         = $config.InstallScriptUrl
            Activity    = '正在下载 Hermes 安装脚本'
            StatusLabel = 'Hermes 安装脚本下载'
        },
        [PSCustomObject]@{
            Name        = 'Hermes 源码压缩包'
            Path        = Join-Path $paths.Downloads $config.SourceArchiveName
            Url         = $config.SourceArchiveUrl
            Activity    = '正在下载 Hermes 源码压缩包'
            StatusLabel = 'Hermes 源码压缩包下载'
        },
        [PSCustomObject]@{
            Name        = 'Node.js Linux x64 压缩包'
            Path        = Join-Path $paths.Downloads $config.NodeArchiveName
            Url         = $nodeSpec.Url
            Activity    = '正在下载 Node.js Linux x64 压缩包'
            StatusLabel = 'Node.js Linux x64 压缩包下载'
        },
        [PSCustomObject]@{
            Name        = 'Hermes WebUI 压缩包'
            Path        = Join-Path $paths.Downloads $config.WebUiArchiveName
            Url         = $config.WebUiUrl
            Activity    = '正在下载 Hermes WebUI 压缩包'
            StatusLabel = 'Hermes WebUI 压缩包下载'
        }
    ) | ForEach-Object {
        $assets.Add($_)
    }

    foreach ($asset in $assets) {
        Write-Step ("检查本地缓存：{0}。" -f $asset.Name)
        $metadataProbe = Try-GetRemoteFileMetadata -Uri $asset.Url
        $meta = if ($metadataProbe.Success) { $metadataProbe.Metadata } else { $null }
        $reuse = $false

        if (-not $metadataProbe.Success) {
            Write-Step ("远程元数据获取失败，将按本地缓存优先继续处理 {0}：{1}" -f $asset.Name, $metadataProbe.Error)
            $completed.Add(("远程元数据获取失败，但仍继续处理 {0}：{1}" -f $asset.Name, $metadataProbe.Error))
        }

        if (Test-Path -LiteralPath $asset.Path) {
            $existingLength = (Get-Item -LiteralPath $asset.Path).Length
            if ($existingLength -gt 0 -and ($null -eq $meta -or $meta.ContentLength -le 0 -or $existingLength -eq $meta.ContentLength)) {
                $reuse = $true
                $completed.Add(("已复用现有 {0}：{1}" -f $asset.Name, $asset.Path))
                Write-Step ("复用已有 {0}：{1}" -f $asset.Name, $asset.Path)
            }
            elseif ($existingLength -le 0) {
                Write-Step ("现有 {0} 为空文件，先删除再重新下载。" -f $asset.Name)
                Remove-Item -LiteralPath $asset.Path -Force
                $completed.Add(("已删除空的缓存副本，然后重新下载 {0}。" -f $asset.Name))
            }
            else {
                Write-Step ("现有 {0} 大小不匹配，先删除再重新下载。" -f $asset.Name)
                Remove-Item -LiteralPath $asset.Path -Force
                $completed.Add(("已删除过期缓存副本，然后重新下载 {0}。" -f $asset.Name))
            }
        }

        if (-not $reuse) {
            Download-FileWithProgress `
                -Uri $asset.Url `
                -OutputPath $asset.Path `
                -Activity $asset.Activity `
                -StatusLabel $asset.StatusLabel `
                -TotalBytesHint $(if ($null -ne $meta) { $meta.ContentLength } else { 0 })

            $downloadedLength = (Get-Item -LiteralPath $asset.Path).Length
            if ($null -ne $meta -and $meta.ContentLength -gt 0 -and $downloadedLength -ne $meta.ContentLength) {
                throw ("Downloaded {0} size mismatch. Expected {1} bytes, got {2} bytes." -f $asset.Name, $meta.ContentLength, $downloadedLength)
            }

            $completed.Add(("已将 {0} 下载到 {1}" -f $asset.Name, $asset.Path))
            $completed.Add(("已记录 {0} 大小：{1} 字节" -f $asset.Name, $downloadedLength))
        }
    }

    return [PSCustomObject]@{
        Status = 'ready'
        Mode   = $(if ($config.InstallMode -eq 'dedicated' -and -not [string]::IsNullOrWhiteSpace($baseImagePath)) { 'prebuilt-base-image' } else { 'prefetched-online-assets' })
    }
}
catch {
    throw
}
