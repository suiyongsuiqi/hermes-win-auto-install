[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$paths = Get-HermesPaths
$totalPhases = 6
$completed = New-Object System.Collections.Generic.List[string]

function Start-WslInstallProcess {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$DistroName
    )

    $installLocation = Get-HermesDistroInstallLocation -DistroName $DistroName
    if (Test-Path -LiteralPath $installLocation) {
        Remove-Item -LiteralPath $installLocation -Recurse -Force
    }

    Ensure-Directory -Path (Split-Path -Parent $installLocation)

    return Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('--install', '--from-file', $PackagePath, '--name', $DistroName, '--location', $installLocation, '--no-launch') `
        -PassThru `
        -WindowStyle Hidden
}

function Start-WslImportProcess {
    param(
        [Parameter(Mandatory = $true)][string]$BaseImagePath,
        [Parameter(Mandatory = $true)][string]$DistroName
    )

    $installLocation = Get-HermesDistroInstallLocation -DistroName $DistroName
    if (Test-Path -LiteralPath $installLocation) {
        Remove-Item -LiteralPath $installLocation -Recurse -Force
    }

    Ensure-Directory -Path (Split-Path -Parent $installLocation)

    return Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('--import', $DistroName, $installLocation, $BaseImagePath, '--version', '2') `
        -PassThru `
        -WindowStyle Hidden
}

function Get-DriveFreeSpaceInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Could not resolve the drive root for path: $Path"
    }

    $drive = [System.IO.DriveInfo]::new($root)
    return [PSCustomObject]@{
        Root                = $drive.Name
        AvailableFreeSpace  = [int64]$drive.AvailableFreeSpace
        TotalSize           = [int64]$drive.TotalSize
    }
}

function Assert-SufficientDedicatedInstallDiskSpace {
    param(
        [Parameter(Mandatory = $true)]$ResolvedConfig,
        [Parameter(Mandatory = $true)][bool]$UsingPrebuiltBaseImage
    )

    $targetLocation = Get-HermesDistroInstallLocation -DistroName $ResolvedConfig.DistroName
    $driveInfo = Get-DriveFreeSpaceInfo -Path $targetLocation
    $minimumFreeBytes = 6GB
    $recommendedFreeBytes = 8GB

    if ($driveInfo.AvailableFreeSpace -lt $minimumFreeBytes) {
        $requiredLabel = Format-ByteSize -Bytes $minimumFreeBytes
        $freeLabel = Format-ByteSize -Bytes $driveInfo.AvailableFreeSpace
        $recommendedLabel = Format-ByteSize -Bytes $recommendedFreeBytes
        $modeLabel = if ($UsingPrebuiltBaseImage) { 'prebuilt-base-image import' } else { 'Ubuntu package install and bootstrap' }
        throw ("Not enough free disk space on {0} for the dedicated Hermes distro. {1} requires at least {2} free, but only {3} is available. Free up space and retry. Recommended free space: {4}." -f `
            $driveInfo.Root,
            $modeLabel,
            $requiredLabel,
            $freeLabel,
            $recommendedLabel)
    }
}

function Initialize-PrebuiltBaseDistro {
    param(
        [Parameter(Mandatory = $true)]$ResolvedConfig
    )

    $usernameB64 = Convert-ToBase64 -Value $ResolvedConfig.Username
    $baseUrlB64 = Convert-ToBase64 -Value $ResolvedConfig.BaseUrl
    $modelB64 = Convert-ToBase64 -Value $ResolvedConfig.Model
    $apiModeB64 = Convert-ToBase64 -Value $ResolvedConfig.ApiMode
    $installScriptPathInWsl = Convert-WindowsPathToWslMountPath -Path (Join-Path $paths.Downloads $ResolvedConfig.InstallScriptName)
    $sourceArchivePathInWsl = Convert-WindowsPathToWslMountPath -Path (Join-Path $paths.Downloads $ResolvedConfig.SourceArchiveName)
    $keyHelper = @'
#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR=/var/lib/hermes-bootstrap
CONFIG_FILE="$STAGE_DIR/config.env"
source "$CONFIG_FILE"

decode_b64() {
  printf '%s' "$1" | base64 --decode
}

escape_env() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_yaml() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

TARGET_USER="$(decode_b64 "$HERMES_BOOTSTRAP_USERNAME_B64")"
BASE_URL="$(decode_b64 "$HERMES_BOOTSTRAP_BASE_URL_B64")"
MODEL_NAME="$(decode_b64 "$HERMES_BOOTSTRAP_MODEL_B64")"
HOME_DIR="/home/$TARGET_USER"
HERMES_HOME="$HOME_DIR/.hermes"

read -r API_KEY
API_KEY="${API_KEY%$'\r'}"
if [ -z "$API_KEY" ]; then
  echo 'API key is empty.' >&2
  exit 1
fi

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$HERMES_HOME"

API_KEY_ESC="$(escape_env "$API_KEY")"
BASE_URL_ESC="$(escape_env "$BASE_URL")"
MODEL_ENV_ESC="$(escape_env "$MODEL_NAME")"
MODEL_YAML_ESC="$(escape_yaml "$MODEL_NAME")"
BASE_URL_YAML_ESC="$(escape_yaml "$BASE_URL")"
API_MODE_YAML_ESC="$(escape_yaml "$API_MODE")"

cat > "$HERMES_HOME/.env" <<EOF
OPENAI_API_KEY="$API_KEY_ESC"
OPENAI_BASE_URL="$BASE_URL_ESC"
LLM_MODEL="$MODEL_ENV_ESC"
EOF

cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: "$MODEL_YAML_ESC"
  provider: custom
  base_url: "$BASE_URL_YAML_ESC"
  api_mode: "$API_MODE_YAML_ESC"
EOF

chown "$TARGET_USER:$TARGET_USER" "$HERMES_HOME/.env" "$HERMES_HOME/config.yaml"
chmod 600 "$HERMES_HOME/.env"
chmod 600 "$HERMES_HOME/config.yaml"
printf '%s\n' success > "$STAGE_DIR/key_status"
printf '%s\n' "$(date -Iseconds)" > "$STAGE_DIR/key_updated_at"
EOS
'@
    $initCommand = @'
set -euo pipefail

STAGE_DIR=/var/lib/hermes-bootstrap
mkdir -p "\$STAGE_DIR"

cat > "\$STAGE_DIR/config.env" <<'EOF'
HERMES_BOOTSTRAP_USERNAME_B64=__USERNAME_B64__
HERMES_BOOTSTRAP_BASE_URL_B64=__BASE_URL_B64__
HERMES_BOOTSTRAP_MODEL_B64=__MODEL_B64__
HERMES_BOOTSTRAP_API_MODE_B64=__API_MODE_B64__
EOF

printf '%s\n' '__BASE_IMAGE_MODE__' > "\$STAGE_DIR/bootstrap_mode"

cat > /usr/local/bin/hermes-inject-key.sh <<'EOS'
__KEY_HELPER__
EOS
chmod 700 /usr/local/bin/hermes-inject-key.sh

decode_b64() {
  printf '%s' "\$1" | base64 --decode
}

escape_yaml() {
  printf '%s' "\$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

TARGET_USER="\$(decode_b64 '__USERNAME_B64__')"
BASE_URL="\$(decode_b64 '__BASE_URL_B64__')"
MODEL_NAME="\$(decode_b64 '__MODEL_B64__')"
API_MODE="\$(decode_b64 '__API_MODE_B64__')"
HOME_DIR="/home/\$TARGET_USER"
HERMES_HOME="\$HOME_DIR/.hermes"

MODEL_YAML_ESC="\$(escape_yaml "\$MODEL_NAME")"
BASE_URL_YAML_ESC="\$(escape_yaml "\$BASE_URL")"
API_MODE_YAML_ESC="\$(escape_yaml "\$API_MODE")"

install -d -m 700 -o "\$TARGET_USER" -g "\$TARGET_USER" "\$HERMES_HOME"
cat > "\$HERMES_HOME/config.yaml" <<EOF
model:
  default: "\$MODEL_YAML_ESC"
  provider: custom
  base_url: "\$BASE_URL_YAML_ESC"
  api_mode: "\$API_MODE_YAML_ESC"
EOF

touch "\$HOME_DIR/.hushlogin"
chown "\$TARGET_USER:\$TARGET_USER" "\$HOME_DIR/.hushlogin" "\$HERMES_HOME/config.yaml"
chmod 600 "\$HERMES_HOME/config.yaml"

test -x "\$HOME_DIR/.local/bin/hermes"
su - "\$TARGET_USER" -c 'export PATH="\$HOME/.local/bin:\$PATH"; ~/.local/bin/hermes version >/dev/null'

printf '%s\n' ready-for-key > "\$STAGE_DIR/stage.txt"
printf '%s\n' ready_for_key > "\$STAGE_DIR/result"
'@
    $initCommand = $initCommand.Replace('__USERNAME_B64__', $usernameB64)
    $initCommand = $initCommand.Replace('__BASE_URL_B64__', $baseUrlB64)
    $initCommand = $initCommand.Replace('__MODEL_B64__', $modelB64)
    $initCommand = $initCommand.Replace('__API_MODE_B64__', $apiModeB64)
    $initCommand = $initCommand.Replace('__BASE_IMAGE_MODE__', $ResolvedConfig.BaseImageMode)
    $initCommand = $initCommand.Replace('__KEY_HELPER__', $keyHelper)

    Invoke-WslBash `
        -Distro $ResolvedConfig.DistroName `
        -User 'root' `
        -Command $initCommand `
        -TimeoutSeconds 900 `
        -ProgressMessage '正在完成预构建 Hermes WSL 基础镜像的本地收尾。' `
        -RequireSuccess | Out-Null
}

function Invoke-ResumeBootstrapRepair {
    param(
        [Parameter(Mandatory = $true)]$ResolvedConfig
    )

    $existingResult = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User 'root' -Command 'cat /var/lib/hermes-bootstrap/result 2>/dev/null || true' -TimeoutSeconds 20
    if ($existingResult.Trim() -eq 'ready_for_key') {
        return 'ready'
    }

    $existingStage = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User 'root' -Command 'cat /var/lib/hermes-bootstrap/stage.txt 2>/dev/null || true' -TimeoutSeconds 20
    if ($existingStage.Trim() -ne 'install-hermes') {
        return 'not-applicable'
    }

    $installScriptPath = Join-Path $paths.Downloads $ResolvedConfig.InstallScriptName
    $sourceArchivePath = Join-Path $paths.Downloads $ResolvedConfig.SourceArchiveName
    $nodeArchivePath = Join-Path $paths.Downloads $ResolvedConfig.NodeArchiveName
    if (-not (Test-Path -LiteralPath $installScriptPath) -or -not (Test-Path -LiteralPath $sourceArchivePath)) {
        return 'not-applicable'
    }

    $usernameForBash = $ResolvedConfig.Username.Replace("'", "'\''")
    $installScriptPathForBash = (Convert-WindowsPathToWslMountPath -Path $installScriptPath).Replace("'", "'\''")
    $sourceArchivePathForBash = (Convert-WindowsPathToWslMountPath -Path $sourceArchivePath).Replace("'", "'\''")
    $nodeArchivePathForBash = (Convert-WindowsPathToWslMountPath -Path $nodeArchivePath).Replace("'", "'\''")
    $repairCommand = @'
set -euo pipefail

STAGE_DIR=/var/lib/hermes-bootstrap

run_as_user() {
  sudo -Hiu "$TARGET_USER" bash -lc "$1"
}

prepare_git_network() {
  run_as_user 'git config --global http.version HTTP/1.1'
  run_as_user 'git config --global http.postBuffer 524288000'
  run_as_user 'git config --global http.lowSpeedLimit 1000'
  run_as_user 'git config --global http.lowSpeedTime 600'
}

TARGET_USER='__TARGET_USER__'
HOME_DIR="/home/$TARGET_USER"
HERMES_CMD="$HOME_DIR/.local/bin/hermes"
LINUX_INSTALL_SCRIPT='__INSTALL_SCRIPT_PATH__'
LINUX_SOURCE_ARCHIVE='__SOURCE_ARCHIVE_PATH__'
LINUX_NODE_ARCHIVE='__NODE_ARCHIVE_PATH__'
APT_PRIMARY_URL='__APT_PRIMARY_URL__'
APT_SECURITY_URL='__APT_SECURITY_URL__'
NODE_DIST_MIRROR_URL='__NODE_DIST_MIRROR_URL__'
NPM_REGISTRY_URL='__NPM_REGISTRY_URL__'

if [ ! -f "$LINUX_INSTALL_SCRIPT" ] || [ ! -f "$LINUX_SOURCE_ARCHIVE" ]; then
  echo 'Local cached Hermes assets are missing inside WSL.' >&2
  exit 1
fi

printf '%s\n' install-hermes > "$STAGE_DIR/stage.txt"
rm -f "$STAGE_DIR/result" "$STAGE_DIR/failed_stage.txt"

cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $APT_PRIMARY_URL
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $APT_SECURITY_URL
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

apt-get update -qq

pkill -f 'git clone --branch main https://github.com/NousResearch/hermes-agent.git' 2>/dev/null || true
pkill -f 'git-remote-https origin https://github.com/NousResearch/hermes-agent.git' 2>/dev/null || true
pkill -f '/usr/local/bin/hermes-bootstrap.sh' 2>/dev/null || true
pkill -u "$TARGET_USER" -f 'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh' 2>/dev/null || true
pkill -u "$TARGET_USER" -f "$HOME_DIR/.hermes/hermes-agent" 2>/dev/null || true
pkill -u "$TARGET_USER" -f 'npm install' 2>/dev/null || true
pkill -u "$TARGET_USER" -f 'camoufox-js fetch' 2>/dev/null || true
pkill -u "$TARGET_USER" -f 'playwright install' 2>/dev/null || true
sleep 2

prepare_git_network
run_as_user 'rm -rf ~/.hermes/hermes-agent'

TEMP_DIR=/var/tmp/hermes-local-install
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
chmod 755 "$TEMP_DIR"

ORIGINAL_SCRIPT="$TEMP_DIR/install.sh"
PATCHED_SCRIPT="$TEMP_DIR/install-local.sh"
cp "$LINUX_INSTALL_SCRIPT" "$ORIGINAL_SCRIPT"
sed '$d' "$ORIGINAL_SCRIPT" > "$PATCHED_SCRIPT"

cat >> "$PATCHED_SCRIPT" <<'EOF'
clone_repo() {
    log_info "Installing from local cached source archive..."

    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"

    local local_archive="@@LOCAL_SOURCE_ARCHIVE@@"
    local extract_dir
    local source_dir
    extract_dir="$(mktemp -d /var/tmp/hermes-source-XXXXXX)"

    tar -xzf "$local_archive" -C "$extract_dir"
    source_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [ -z "$source_dir" ]; then
        log_error "Failed to unpack the local Hermes source archive"
        exit 1
    fi

    mv "$source_dir" "$INSTALL_DIR"
    rm -rf "$extract_dir"
    cd "$INSTALL_DIR"

    log_success "Repository ready from local cached archive"
}

install_node() {
    if [ "$DISTRO" = "termux" ]; then
        log_info "Installing Node.js via pkg..."
        if pkg install -y nodejs >/dev/null; then
            local installed_ver
            installed_ver=$(node --version 2>/dev/null)
            log_success "Node.js $installed_ver installed via pkg"
            HAS_NODE=true
        else
            log_warn "Failed to install Node.js via pkg"
            HAS_NODE=false
        fi
        return 0
    fi

    local arch
    local node_arch
    local node_os
    local mirror_root="__NODE_DIST_MIRROR_URL__"
    local local_archive="@@LOCAL_NODE_ARCHIVE@@"
    local tarball_name=""
    local archive_path=""
    local index_url=""
    local tmp_dir
    local extracted_dir
    local installed_ver

    arch="$(uname -m)"
    case "$arch" in
        x86_64) node_arch="x64" ;;
        aarch64|arm64) node_arch="arm64" ;;
        armv7l) node_arch="armv7l" ;;
        *)
            log_warn "Unsupported architecture ($arch) for Node.js auto-install"
            HAS_NODE=false
            return 0
            ;;
    esac

    case "$OS" in
        linux) node_os="linux" ;;
        macos) node_os="darwin" ;;
        *)
            log_warn "Unsupported OS for Node.js auto-install"
            HAS_NODE=false
            return 0
            ;;
    esac

    tmp_dir="$(mktemp -d)"

    if [ -f "$local_archive" ]; then
        tarball_name="$(basename "$local_archive")"
        archive_path="$local_archive"
        log_info "Using local cached Node.js archive: $local_archive"
    else
        index_url="${mirror_root}/latest-v${NODE_VERSION}.x/"
        tarball_name=$(curl -fsSL "${index_url}SHASUMS256.txt" \
            | grep -oE "node-v${NODE_VERSION}\.[0-9]+\.[0-9]+-${node_os}-${node_arch}\.tar\.xz" \
            | head -1)

        if [ -z "$tarball_name" ]; then
            tarball_name=$(curl -fsSL "${index_url}SHASUMS256.txt" \
                | grep -oE "node-v${NODE_VERSION}\.[0-9]+\.[0-9]+-${node_os}-${node_arch}\.tar\.gz" \
                | head -1)
        fi

        if [ -z "$tarball_name" ]; then
            log_warn "Could not find Node.js $NODE_VERSION binary for $node_os-$node_arch"
            rm -rf "$tmp_dir"
            HAS_NODE=false
            return 0
        fi

        archive_path="$tmp_dir/$tarball_name"
        log_info "Downloading $tarball_name from the Node.js mirror..."
        if ! curl -fsSL "${index_url}${tarball_name}" -o "$archive_path"; then
            log_warn "Node.js mirror download failed"
            rm -rf "$tmp_dir"
            HAS_NODE=false
            return 0
        fi
    fi

    log_info "Extracting Node.js to ~/.hermes/node/..."
    if [[ "$archive_path" == *.tar.xz ]]; then
        tar xf "$archive_path" -C "$tmp_dir"
    else
        tar xzf "$archive_path" -C "$tmp_dir"
    fi

    extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name 'node-v*' | head -1)"
    if [ ! -d "$extracted_dir" ]; then
        log_warn "Node.js archive extraction failed"
        rm -rf "$tmp_dir"
        HAS_NODE=false
        return 0
    fi

    rm -rf "$HERMES_HOME/node"
    mkdir -p "$HERMES_HOME"
    mv "$extracted_dir" "$HERMES_HOME/node"
    rm -rf "$tmp_dir"

    mkdir -p "$HOME/.local/bin"
    ln -sf "$HERMES_HOME/node/bin/node" "$HOME/.local/bin/node"
    ln -sf "$HERMES_HOME/node/bin/npm" "$HOME/.local/bin/npm"
    ln -sf "$HERMES_HOME/node/bin/npx" "$HOME/.local/bin/npx"

    export PATH="$HERMES_HOME/node/bin:$PATH"
    installed_ver=$("$HERMES_HOME/node/bin/node" --version 2>/dev/null)
    log_success "Node.js $installed_ver installed to ~/.hermes/node/"
    HAS_NODE=true
}

install_node_deps() {
    if [ "$HAS_NODE" = false ]; then
        log_info "Skipping Node.js dependencies (Node not installed)"
        return 0
    fi

    if [ "$DISTRO" = "termux" ]; then
        log_info "Skipping automatic Node/browser dependency setup on Termux"
        return 0
    fi

    export npm_config_registry="__NPM_REGISTRY_URL__"
    export npm_config_audit=false
    export npm_config_fund=false
    export npm_config_update_notifier=false
    export npm_config_prefer_offline=true
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

    if [ -f "$INSTALL_DIR/package.json" ]; then
        log_info "Installing Node.js dependencies from the configured npm mirror..."
        cd "$INSTALL_DIR"
        npm install --silent --ignore-scripts 2>/dev/null || {
            log_warn "npm install failed (browser tools may not work)"
        }
        log_success "Node.js dependencies installed"
        log_info "Skipping Playwright, Camoufox, and agent-browser binary downloads during the Windows bootstrap."
    fi

    if [ -f "$INSTALL_DIR/scripts/whatsapp-bridge/package.json" ]; then
        log_info "Skipping WhatsApp bridge npm install during the Windows bootstrap."
    fi
}

main
EOF

ESCAPED_ARCHIVE="$(printf '%s' "$LINUX_SOURCE_ARCHIVE" | sed 's/[&|]/\\&/g')"
sed -i "s|@@LOCAL_SOURCE_ARCHIVE@@|$ESCAPED_ARCHIVE|g" "$PATCHED_SCRIPT"
ESCAPED_NODE_ARCHIVE="$(printf '%s' "$LINUX_NODE_ARCHIVE" | sed 's/[&|]/\\&/g')"
sed -i "s|@@LOCAL_NODE_ARCHIVE@@|$ESCAPED_NODE_ARCHIVE|g" "$PATCHED_SCRIPT"
ESCAPED_NODE_DIST_MIRROR="$(printf '%s' "$NODE_DIST_MIRROR_URL" | sed 's/[&|]/\\&/g')"
sed -i "s|__NODE_DIST_MIRROR_URL__|$ESCAPED_NODE_DIST_MIRROR|g" "$PATCHED_SCRIPT"
ESCAPED_NPM_REGISTRY="$(printf '%s' "$NPM_REGISTRY_URL" | sed 's/[&|]/\\&/g')"
sed -i "s|__NPM_REGISTRY_URL__|$ESCAPED_NPM_REGISTRY|g" "$PATCHED_SCRIPT"
chmod 755 "$PATCHED_SCRIPT"

run_as_user "$(printf '%q' "$PATCHED_SCRIPT") --skip-setup"

printf '%s\n' hermes-version > "$STAGE_DIR/stage.txt"
run_as_user "$HERMES_CMD version >/dev/null"

printf '%s\n' cloud-init-schema > "$STAGE_DIR/stage.txt"
cloud-init schema --system >/dev/null

printf '%s\n' ready-for-key > "$STAGE_DIR/stage.txt"
printf '%s\n' ready_for_key > "$STAGE_DIR/result"
rm -f "$STAGE_DIR/failed_stage.txt"
rm -rf "$TEMP_DIR"
'@
    $repairCommand = $repairCommand.Replace('__TARGET_USER__', $usernameForBash)
    $repairCommand = $repairCommand.Replace('__INSTALL_SCRIPT_PATH__', $installScriptPathForBash)
    $repairCommand = $repairCommand.Replace('__SOURCE_ARCHIVE_PATH__', $sourceArchivePathForBash)
    $repairCommand = $repairCommand.Replace('__NODE_ARCHIVE_PATH__', $nodeArchivePathForBash)
    $repairCommand = $repairCommand.Replace('__APT_PRIMARY_URL__', $ResolvedConfig.AptPrimaryUrl)
    $repairCommand = $repairCommand.Replace('__APT_SECURITY_URL__', $ResolvedConfig.AptSecurityUrl)
    $repairCommand = $repairCommand.Replace('__NODE_DIST_MIRROR_URL__', $ResolvedConfig.NodeDistMirrorUrl)
    $repairCommand = $repairCommand.Replace('__NPM_REGISTRY_URL__', $ResolvedConfig.NpmRegistryUrl)

    $repairScriptPath = Join-Path $paths.StateRoot 'resume-bootstrap-repair.sh'
    $repairScriptContent = ($repairCommand -replace "`r`n", "`n") -replace "`r", ''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($repairScriptPath, $repairScriptContent, $utf8NoBom)
    $repairScriptPathInWsl = Convert-WindowsPathToWslMountPath -Path $repairScriptPath

    Write-Step '检测到旧的 resume-hermes 环境卡在 install-hermes，正在使用本地缓存资源修复。'
    try {
        Invoke-WslBash `
            -Distro $ResolvedConfig.DistroName `
            -User 'root' `
            -Command ("chmod 700 '{0}' && bash '{0}'" -f $repairScriptPathInWsl) `
            -TimeoutSeconds 3600 `
            -ProgressMessage '正在使用本地缓存资源修复恢复中的 Hermes bootstrap。' `
            -RequireSuccess | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $repairScriptPath) {
            Remove-Item -LiteralPath $repairScriptPath -Force
        }
    }

    return 'repaired'
}

function Replace-TemplateTokens {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][hashtable]$Tokens
    )

    $resolved = $Content
    foreach ($token in $Tokens.Keys) {
        $resolved = $resolved.Replace([string]$token, [string]$Tokens[$token])
    }

    return $resolved
}

function Get-UnresolvedTemplateTokens {
    param([Parameter(Mandatory = $true)][string]$Content)

    $tokens = @()
    foreach ($match in [regex]::Matches($Content, '__[A-Z0-9_]+__')) {
        $tokens += $match.Value
    }

    return @($tokens | Sort-Object -Unique)
}

function Assert-NoTemplatePlaceholders {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$ContextLabel
    )

    $remainingTokens = @(Get-UnresolvedTemplateTokens -Content $Content)
    if ($remainingTokens.Count -gt 0) {
        throw "$ContextLabel still contains unresolved template tokens: $($remainingTokens -join ', ')"
    }
}

function Get-UbuntuSourcesHealth {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $sourceText = ''
    try {
        $sourceText = Invoke-WslBash -Distro $DistroName -User 'root' -Command 'cat /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true' -TimeoutSeconds 20
    }
    catch {
        $sourceText = ''
    }

    $trimmedSourceText = [string]$sourceText
    $trimmedSourceText = $trimmedSourceText.Trim()
    if (-not $trimmedSourceText) {
        return [PSCustomObject]@{
            Status  = 'missing'
            Detail  = 'ubuntu.sources is not present yet.'
            Content = ''
        }
    }

    if ($trimmedSourceText -match '__[A-Z0-9_]+__') {
        return [PSCustomObject]@{
            Status  = 'placeholder'
            Detail  = 'ubuntu.sources still contains unresolved template placeholders.'
            Content = $trimmedSourceText
        }
    }

    $uriMatches = [regex]::Matches($trimmedSourceText, '(?im)^URIs:\s*(.+)$')
    if ($uriMatches.Count -eq 0) {
        return [PSCustomObject]@{
            Status  = 'invalid'
            Detail  = 'ubuntu.sources does not contain any URIs entries.'
            Content = $trimmedSourceText
        }
    }

    $invalidUris = @()
    foreach ($uriMatch in $uriMatches) {
        $uriValue = $uriMatch.Groups[1].Value.Trim()
        if ($uriValue -notmatch '^https?://') {
            $invalidUris += $uriValue
        }
    }

    if ($invalidUris.Count -gt 0) {
        return [PSCustomObject]@{
            Status  = 'invalid'
            Detail  = "ubuntu.sources contains invalid URIs: $($invalidUris -join ', ')"
            Content = $trimmedSourceText
        }
    }

    return [PSCustomObject]@{
        Status  = 'configured'
        Detail  = 'ubuntu.sources contains concrete HTTP(S) mirror URLs.'
        Content = $trimmedSourceText
    }
}

function Get-BootstrapDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [switch]$IncludeCloudInit
    )

    $details = @()
    $sourcesHealth = Get-UbuntuSourcesHealth -DistroName $DistroName
    $details += "APT source health: $($sourcesHealth.Status)"
    if ($sourcesHealth.Detail) {
        $details += $sourcesHealth.Detail
    }
    if ($sourcesHealth.Content) {
        $details += "ubuntu.sources:`n$($sourcesHealth.Content)"
    }

    try {
        $bootstrapLogTail = Invoke-WslBash -Distro $DistroName -User 'root' -Command 'tail -n 80 /var/log/hermes-bootstrap.log 2>/dev/null || true' -TimeoutSeconds 20
        if ($bootstrapLogTail) {
            $details += "hermes-bootstrap.log:`n$($bootstrapLogTail.TrimEnd())"
        }
    }
    catch {
    }

    if ($IncludeCloudInit) {
        try {
            $cloudInitTail = Invoke-WslBash -Distro $DistroName -User 'root' -Command 'tail -n 120 /var/log/cloud-init.log 2>/dev/null || true' -TimeoutSeconds 20
            if ($cloudInitTail) {
                $details += "cloud-init.log:`n$($cloudInitTail.TrimEnd())"
            }
        }
        catch {
        }
    }

    return ($details -join "`n")
}

function Render-CloudInit {
    param(
        [Parameter(Mandatory = $true)]$ResolvedConfig,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    Ensure-Directory -Path (Split-Path -Parent $OutputPath)

    $usernameB64 = Convert-ToBase64 -Value $ResolvedConfig.Username
    $baseUrlB64 = Convert-ToBase64 -Value $ResolvedConfig.BaseUrl
    $modelB64 = Convert-ToBase64 -Value $ResolvedConfig.Model
    $apiModeB64 = Convert-ToBase64 -Value $ResolvedConfig.ApiMode
    $installScriptPathInWsl = Convert-WindowsPathToWslMountPath -Path (Join-Path $paths.Downloads $ResolvedConfig.InstallScriptName)
    $sourceArchivePathInWsl = Convert-WindowsPathToWslMountPath -Path (Join-Path $paths.Downloads $ResolvedConfig.SourceArchiveName)
    $nodeArchivePathInWsl = Convert-WindowsPathToWslMountPath -Path (Join-Path $paths.Downloads $ResolvedConfig.NodeArchiveName)
    $bootstrapTokens = @{
        '__APT_PRIMARY_URL__'         = $ResolvedConfig.AptPrimaryUrl
        '__APT_SECURITY_URL__'        = $ResolvedConfig.AptSecurityUrl
        '__INSTALL_SCRIPT_WSL_PATH__' = $installScriptPathInWsl
        '__SOURCE_ARCHIVE_WSL_PATH__' = $sourceArchivePathInWsl
        '__NODE_ARCHIVE_WSL_PATH__'   = $nodeArchivePathInWsl
        '__NODE_DIST_MIRROR_URL__'    = $ResolvedConfig.NodeDistMirrorUrl
        '__NPM_REGISTRY_URL__'        = $ResolvedConfig.NpmRegistryUrl
    }

    $bootstrap = @'
#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR=/var/lib/hermes-bootstrap
LOG_FILE=/var/log/hermes-bootstrap.log
CONFIG_FILE="$STAGE_DIR/config.env"

mkdir -p "$STAGE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

set_stage() {
  printf '%s\n' "$1" > "$STAGE_DIR/stage.txt"
}

set_result() {
  printf '%s\n' "$1" > "$STAGE_DIR/result"
}

fail_handler() {
  local exit_code=$?
  local stage_name="unknown"
  if [ -f "$STAGE_DIR/stage.txt" ]; then
    stage_name="$(cat "$STAGE_DIR/stage.txt")"
  fi
  printf 'failed:%s\n' "$stage_name" > "$STAGE_DIR/result"
  printf '%s\n' "$stage_name" > "$STAGE_DIR/failed_stage.txt"
  exit "$exit_code"
}

trap fail_handler ERR

decode_b64() {
  printf '%s' "$1" | base64 --decode
}

escape_env() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_yaml() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

run_as_user() {
  sudo -Hiu "$TARGET_USER" bash -lc "$1"
}

prepare_git_network() {
  run_as_user 'git config --global http.version HTTP/1.1'
  run_as_user 'git config --global http.postBuffer 524288000'
  run_as_user 'git config --global http.lowSpeedLimit 1000'
  run_as_user 'git config --global http.lowSpeedTime 600'
}

windows_to_linux_path() {
  local windows_path="$1"
  if [ -z "$windows_path" ]; then
    return 1
  fi

  if ! command -v wslpath >/dev/null 2>&1; then
    return 1
  fi

  wslpath -a "$windows_path" 2>/dev/null
}

run_local_cached_install() {
  local linux_install_script
  local linux_source_archive
  local linux_node_archive
  local temp_dir
  local original_script
  local patched_script
  local escaped_archive
  local escaped_node_archive
  local escaped_node_dist_mirror
  local escaped_npm_registry
  local install_cmd

  linux_install_script='__INSTALL_SCRIPT_WSL_PATH__'
  linux_source_archive='__SOURCE_ARCHIVE_WSL_PATH__'
  linux_node_archive='__NODE_ARCHIVE_WSL_PATH__'

  if [ ! -f "$linux_install_script" ] || [ ! -f "$linux_source_archive" ]; then
    return 1
  fi

  printf 'Using local cached Hermes assets from %s and %s\n' "$linux_install_script" "$linux_source_archive"

  temp_dir="/var/tmp/hermes-local-install"
  rm -rf "$temp_dir"
  mkdir -p "$temp_dir"
  chmod 755 "$temp_dir"

  original_script="$temp_dir/install.sh"
  patched_script="$temp_dir/install-local.sh"

  cp "$linux_install_script" "$original_script"
  sed '$d' "$original_script" > "$patched_script"

  cat >> "$patched_script" <<'EOF'
clone_repo() {
    log_info "Installing from local cached source archive..."

    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"

    local local_archive="@@LOCAL_SOURCE_ARCHIVE@@"
    local extract_dir
    local source_dir
    extract_dir="$(mktemp -d /var/tmp/hermes-source-XXXXXX)"

    tar -xzf "$local_archive" -C "$extract_dir"
    source_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [ -z "$source_dir" ]; then
        log_error "Failed to unpack the local Hermes source archive"
        exit 1
    fi

    mv "$source_dir" "$INSTALL_DIR"
    rm -rf "$extract_dir"
    cd "$INSTALL_DIR"

    log_success "Repository ready from local cached archive"
}

install_node() {
    if [ "$DISTRO" = "termux" ]; then
        log_info "Installing Node.js via pkg..."
        if pkg install -y nodejs >/dev/null; then
            local installed_ver
            installed_ver=$(node --version 2>/dev/null)
            log_success "Node.js $installed_ver installed via pkg"
            HAS_NODE=true
        else
            log_warn "Failed to install Node.js via pkg"
            HAS_NODE=false
        fi
        return 0
    fi

    local arch
    local node_arch
    local node_os
    local mirror_root="__NODE_DIST_MIRROR_URL__"
    local local_archive="@@LOCAL_NODE_ARCHIVE@@"
    local tarball_name=""
    local archive_path=""
    local index_url=""
    local tmp_dir
    local extracted_dir
    local installed_ver

    arch="$(uname -m)"
    case "$arch" in
        x86_64) node_arch="x64" ;;
        aarch64|arm64) node_arch="arm64" ;;
        armv7l) node_arch="armv7l" ;;
        *)
            log_warn "Unsupported architecture ($arch) for Node.js auto-install"
            HAS_NODE=false
            return 0
            ;;
    esac

    case "$OS" in
        linux) node_os="linux" ;;
        macos) node_os="darwin" ;;
        *)
            log_warn "Unsupported OS for Node.js auto-install"
            HAS_NODE=false
            return 0
            ;;
    esac

    tmp_dir="$(mktemp -d)"

    if [ -f "$local_archive" ]; then
        tarball_name="$(basename "$local_archive")"
        archive_path="$local_archive"
        log_info "Using local cached Node.js archive: $local_archive"
    else
        index_url="${mirror_root}/latest-v${NODE_VERSION}.x/"
        tarball_name=$(curl -fsSL "${index_url}SHASUMS256.txt" \
            | grep -oE "node-v${NODE_VERSION}\.[0-9]+\.[0-9]+-${node_os}-${node_arch}\.tar\.xz" \
            | head -1)

        if [ -z "$tarball_name" ]; then
            tarball_name=$(curl -fsSL "${index_url}SHASUMS256.txt" \
                | grep -oE "node-v${NODE_VERSION}\.[0-9]+\.[0-9]+-${node_os}-${node_arch}\.tar\.gz" \
                | head -1)
        fi

        if [ -z "$tarball_name" ]; then
            log_warn "Could not find Node.js $NODE_VERSION binary for $node_os-$node_arch"
            rm -rf "$tmp_dir"
            HAS_NODE=false
            return 0
        fi

        archive_path="$tmp_dir/$tarball_name"
        log_info "Downloading $tarball_name from the Node.js mirror..."
        if ! curl -fsSL "${index_url}${tarball_name}" -o "$archive_path"; then
            log_warn "Node.js mirror download failed"
            rm -rf "$tmp_dir"
            HAS_NODE=false
            return 0
        fi
    fi

    log_info "Extracting Node.js to ~/.hermes/node/..."
    if [[ "$archive_path" == *.tar.xz ]]; then
        tar xf "$archive_path" -C "$tmp_dir"
    else
        tar xzf "$archive_path" -C "$tmp_dir"
    fi

    extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name 'node-v*' | head -1)"
    if [ ! -d "$extracted_dir" ]; then
        log_warn "Node.js archive extraction failed"
        rm -rf "$tmp_dir"
        HAS_NODE=false
        return 0
    fi

    rm -rf "$HERMES_HOME/node"
    mkdir -p "$HERMES_HOME"
    mv "$extracted_dir" "$HERMES_HOME/node"
    rm -rf "$tmp_dir"

    mkdir -p "$HOME/.local/bin"
    ln -sf "$HERMES_HOME/node/bin/node" "$HOME/.local/bin/node"
    ln -sf "$HERMES_HOME/node/bin/npm" "$HOME/.local/bin/npm"
    ln -sf "$HERMES_HOME/node/bin/npx" "$HOME/.local/bin/npx"

    export PATH="$HERMES_HOME/node/bin:$PATH"
    installed_ver=$("$HERMES_HOME/node/bin/node" --version 2>/dev/null)
    log_success "Node.js $installed_ver installed to ~/.hermes/node/"
    HAS_NODE=true
}

install_node_deps() {
    if [ "$HAS_NODE" = false ]; then
        log_info "Skipping Node.js dependencies (Node not installed)"
        return 0
    fi

    if [ "$DISTRO" = "termux" ]; then
        log_info "Skipping automatic Node/browser dependency setup on Termux"
        return 0
    fi

    export npm_config_registry="__NPM_REGISTRY_URL__"
    export npm_config_audit=false
    export npm_config_fund=false
    export npm_config_update_notifier=false
    export npm_config_prefer_offline=true
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

    if [ -f "$INSTALL_DIR/package.json" ]; then
        log_info "Installing Node.js dependencies from the configured npm mirror..."
        cd "$INSTALL_DIR"
        npm install --silent --ignore-scripts 2>/dev/null || {
            log_warn "npm install failed (browser tools may not work)"
        }
        log_success "Node.js dependencies installed"
        log_info "Skipping Playwright, Camoufox, and agent-browser binary downloads during the Windows bootstrap."
    fi

    if [ -f "$INSTALL_DIR/scripts/whatsapp-bridge/package.json" ]; then
        log_info "Skipping WhatsApp bridge npm install during the Windows bootstrap."
    fi
}

main
EOF

  escaped_archive="$(printf '%s' "$linux_source_archive" | sed 's/[&|]/\\&/g')"
  sed -i "s|@@LOCAL_SOURCE_ARCHIVE@@|$escaped_archive|g" "$patched_script"
  escaped_node_archive="$(printf '%s' "$linux_node_archive" | sed 's/[&|]/\\&/g')"
  sed -i "s|@@LOCAL_NODE_ARCHIVE@@|$escaped_node_archive|g" "$patched_script"
  escaped_node_dist_mirror="$(printf '%s' '__NODE_DIST_MIRROR_URL__' | sed 's/[&|]/\\&/g')"
  sed -i "s|__NODE_DIST_MIRROR_URL__|$escaped_node_dist_mirror|g" "$patched_script"
  escaped_npm_registry="$(printf '%s' '__NPM_REGISTRY_URL__' | sed 's/[&|]/\\&/g')"
  sed -i "s|__NPM_REGISTRY_URL__|$escaped_npm_registry|g" "$patched_script"
  chmod 755 "$patched_script"

  install_cmd="$(printf '%q' "$patched_script") --skip-setup"
  if run_as_user "$install_cmd"; then
    rm -rf "$temp_dir"
    return 0
  fi

  rm -rf "$temp_dir"
  return 1
}

run_upstream_install() {
  local install_cmd='curl --retry 5 --retry-delay 5 --retry-all-errors -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --skip-setup'
  local attempt=1
  local max_attempts=3

  prepare_git_network

  if run_local_cached_install; then
    return 0
  fi

  while [ "$attempt" -le "$max_attempts" ]; do
    printf 'Hermes upstream install attempt %s/%s\n' "$attempt" "$max_attempts"
    run_as_user 'rm -rf ~/.hermes/hermes-agent'

    if run_as_user "$install_cmd"; then
      return 0
    fi

    printf 'Hermes upstream install attempt %s failed\n' "$attempt"
    attempt=$((attempt + 1))
    sleep 15
  done

  return 1
}

set_stage init
source "$CONFIG_FILE"

APT_PRIMARY_URL="__APT_PRIMARY_URL__"
APT_SECURITY_URL="__APT_SECURITY_URL__"

cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $APT_PRIMARY_URL
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $APT_SECURITY_URL
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

TARGET_USER="$(decode_b64 "$HERMES_BOOTSTRAP_USERNAME_B64")"
BASE_URL="$(decode_b64 "$HERMES_BOOTSTRAP_BASE_URL_B64")"
MODEL_NAME="$(decode_b64 "$HERMES_BOOTSTRAP_MODEL_B64")"
API_MODE="$(decode_b64 "$HERMES_BOOTSTRAP_API_MODE_B64")"
HOME_DIR="/home/$TARGET_USER"
HERMES_HOME="$HOME_DIR/.hermes"
HERMES_CMD="$HOME_DIR/.local/bin/hermes"

set_stage files
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$HERMES_HOME"

MODEL_YAML_ESC="$(escape_yaml "$MODEL_NAME")"
BASE_URL_YAML_ESC="$(escape_yaml "$BASE_URL")"
API_MODE_YAML_ESC="$(escape_yaml "$API_MODE")"

cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: "$MODEL_YAML_ESC"
  provider: custom
  base_url: "$BASE_URL_YAML_ESC"
  api_mode: "$API_MODE_YAML_ESC"
EOF

cat > /usr/local/bin/hermes-inject-key.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR=/var/lib/hermes-bootstrap
CONFIG_FILE="$STAGE_DIR/config.env"
source "$CONFIG_FILE"

decode_b64() {
  printf '%s' "$1" | base64 --decode
}

escape_env() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_yaml() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

TARGET_USER="$(decode_b64 "$HERMES_BOOTSTRAP_USERNAME_B64")"
BASE_URL="$(decode_b64 "$HERMES_BOOTSTRAP_BASE_URL_B64")"
MODEL_NAME="$(decode_b64 "$HERMES_BOOTSTRAP_MODEL_B64")"
API_MODE="$(decode_b64 "$HERMES_BOOTSTRAP_API_MODE_B64")"
HOME_DIR="/home/$TARGET_USER"
HERMES_HOME="$HOME_DIR/.hermes"

read -r API_KEY
API_KEY="${API_KEY%$'\r'}"
if [ -z "$API_KEY" ]; then
  echo 'API key is empty.' >&2
  exit 1
fi

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$HERMES_HOME"

API_KEY_ESC="$(escape_env "$API_KEY")"
BASE_URL_ESC="$(escape_env "$BASE_URL")"
MODEL_ENV_ESC="$(escape_env "$MODEL_NAME")"
MODEL_YAML_ESC="$(escape_yaml "$MODEL_NAME")"
BASE_URL_YAML_ESC="$(escape_yaml "$BASE_URL")"
API_MODE_YAML_ESC="$(escape_yaml "$API_MODE")"

cat > "$HERMES_HOME/.env" <<EOF
OPENAI_API_KEY="$API_KEY_ESC"
OPENAI_BASE_URL="$BASE_URL_ESC"
LLM_MODEL="$MODEL_ENV_ESC"
EOF

cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: "$MODEL_YAML_ESC"
  provider: custom
  base_url: "$BASE_URL_YAML_ESC"
  api_mode: "$API_MODE_YAML_ESC"
EOF

chown "$TARGET_USER:$TARGET_USER" "$HERMES_HOME/.env" "$HERMES_HOME/config.yaml"
chmod 600 "$HERMES_HOME/.env"
chmod 600 "$HERMES_HOME/config.yaml"
printf '%s\n' success > "$STAGE_DIR/key_status"
printf '%s\n' "$(date -Iseconds)" > "$STAGE_DIR/key_updated_at"
EOS

chmod 700 /usr/local/bin/hermes-inject-key.sh

chown "$TARGET_USER:$TARGET_USER" "$HERMES_HOME/config.yaml"
chmod 600 "$HERMES_HOME/config.yaml"

touch "$HOME_DIR/.hushlogin"
chown "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.hushlogin"

set_stage install-hermes
run_upstream_install

set_stage hermes-version
run_as_user "$HERMES_CMD version"

set_stage cloud-init-schema
cloud-init schema --system

set_stage ready-for-key
set_result ready_for_key
'@
    $bootstrap = Replace-TemplateTokens -Content $bootstrap -Tokens $bootstrapTokens
    Assert-NoTemplatePlaceholders -Content $bootstrap -ContextLabel 'Embedded Hermes bootstrap script'

    $template = @'
#cloud-config
apt:
  primary:
    - arches: [default]
      uri: __APT_PRIMARY_URL__
  security:
    - arches: [default]
      uri: __APT_SECURITY_URL__
users:
  - name: __WSL_USERNAME__
    gecos: Hermes WSL User
    groups: [adm, dialout, cdrom, floppy, sudo, audio, dip, video, plugdev, netdev]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true

package_update: true
packages:
  - git
  - curl
  - ca-certificates

write_files:
  - path: /etc/wsl.conf
    permissions: '0644'
    owner: root:root
    content: |
      [user]
      default=__WSL_USERNAME__
  - path: /var/lib/hermes-bootstrap/config.env
    permissions: '0600'
    owner: root:root
    content: |
      HERMES_BOOTSTRAP_USERNAME_B64=__USERNAME_B64__
      HERMES_BOOTSTRAP_BASE_URL_B64=__BASEURL_B64__
      HERMES_BOOTSTRAP_MODEL_B64=__MODEL_B64__
      HERMES_BOOTSTRAP_API_MODE_B64=__API_MODE_B64__
  - path: /usr/local/bin/hermes-bootstrap.sh
    permissions: '0755'
    owner: root:root
    content: |
__BOOTSTRAP_CONTENT__

runcmd:
  - [bash, -lc, /usr/local/bin/hermes-bootstrap.sh]
'@

    $indentedBootstrap = ($bootstrap -split "`n" | ForEach-Object { '      ' + $_ }) -join "`n"
    $content = $template
    $content = $content.Replace('__WSL_USERNAME__', $ResolvedConfig.Username)
    $content = $content.Replace('__USERNAME_B64__', $usernameB64)
    $content = $content.Replace('__BASEURL_B64__', $baseUrlB64)
    $content = $content.Replace('__MODEL_B64__', $modelB64)
    $content = $content.Replace('__API_MODE_B64__', $apiModeB64)
    $content = $content.Replace('__APT_PRIMARY_URL__', $ResolvedConfig.AptPrimaryUrl)
    $content = $content.Replace('__APT_SECURITY_URL__', $ResolvedConfig.AptSecurityUrl)
    $content = $content.Replace('__INSTALL_SCRIPT_WSL_PATH__', $installScriptPathInWsl)
    $content = $content.Replace('__SOURCE_ARCHIVE_WSL_PATH__', $sourceArchivePathInWsl)
    $content = $content.Replace('__NODE_ARCHIVE_WSL_PATH__', $nodeArchivePathInWsl)
    $content = $content.Replace('__NODE_DIST_MIRROR_URL__', $ResolvedConfig.NodeDistMirrorUrl)
    $content = $content.Replace('__NPM_REGISTRY_URL__', $ResolvedConfig.NpmRegistryUrl)
    $content = $content.Replace('__BOOTSTRAP_CONTENT__', $indentedBootstrap)
    Assert-NoTemplatePlaceholders -Content $content -ContextLabel 'Rendered cloud-init payload'

    Set-Content -LiteralPath $OutputPath -Value $content -Encoding Ascii
}

function Wait-ForDistroRegistration {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [int]$SoftTimeoutMinutes = 10,
        [int]$HardTimeoutMinutes = 30
    )

    $soft = [TimeSpan]::FromMinutes($SoftTimeoutMinutes)
    $hard = [TimeSpan]::FromMinutes($HardTimeoutMinutes)
    $start = Get-Date

    while ($true) {
        $elapsed = (Get-Date) - $start
        $distroExists = Test-WslDistributionExists -Name $DistroName
        $wslProcesses = @(Get-Process | Where-Object { $_.ProcessName -like 'wsl*' })

        if ($distroExists -and $Process.HasExited) {
            Write-Step "WSL 发行版 $DistroName 已注册，导入进程也已退出。"
            return
        }

        if (-not $distroExists -and $Process.HasExited) {
            throw "WSL import exited but distribution $DistroName was not registered."
        }

        if ($elapsed -ge $hard) {
            if ($distroExists) {
                Write-Step "导入已超过硬超时限制，但发行版 $DistroName 已存在，将继续后续流程。"
                return
            }
            & wsl.exe --shutdown 2>$null | Out-Null
            throw "WSL import exceeded $HardTimeoutMinutes minutes without registering the distribution."
        }

        if ($elapsed -ge $soft) {
            Write-Step "WSL 导入已超过 $SoftTimeoutMinutes 分钟，继续轮询。当前 wsl 进程数：$($wslProcesses.Count)"
        }
        elseif ($distroExists) {
            Write-Step "发行版 $DistroName 已可见，正在等待导入进程完成。"
        }
        else {
            Write-Step "正在等待发行版 $DistroName 出现。"
        }

        Start-Sleep -Seconds 15
        $Process.Refresh()
    }
}

function Wait-ForBootstrap {
    param(
        [Parameter(Mandatory = $true)]$ResolvedConfig,
        [int]$SoftTimeoutMinutes = 15,
        [int]$HardTimeoutMinutes = 45
    )

    $DistroName = $ResolvedConfig.DistroName

    $existingResult = ''
    try {
        $existingResult = Invoke-WslBash -Distro $DistroName -User 'root' -Command 'cat /var/lib/hermes-bootstrap/result 2>/dev/null || true' -TimeoutSeconds 20
    }
    catch {
        $existingResult = ''
    }

    if ($existingResult -eq 'ready_for_key') {
        Write-Step 'bootstrap 结果已存在，复用当前的 ready_for_key 状态。'
        return
    }

    $bootstrapCommand = @'
set -euo pipefail

if [ -f /var/lib/hermes-bootstrap/result ]; then
  exit 0
fi

cloud-init modules --mode config
rm -f /var/lib/cloud/instances/*/sem/config_scripts_user
rm -f /var/lib/cloud/instances/*/sem/config_scripts_per_instance
cloud-init modules --mode final

while [ ! -f /var/lib/hermes-bootstrap/result ]; do
  sleep 2
done
'@

    $launchProcess = Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('-d', $DistroName, '-u', 'root', '--', 'bash', '-lc', $bootstrapCommand) `
        -PassThru `
        -WindowStyle Hidden

    $start = Get-Date
    $soft = [TimeSpan]::FromMinutes($SoftTimeoutMinutes)
    $hard = [TimeSpan]::FromMinutes($HardTimeoutMinutes)

    while ($true) {
        $elapsed = (Get-Date) - $start
        $stage = ''
        $result = ''
        $trimmedStage = ''

        try {
            $stage = Invoke-WslBash -Distro $DistroName -User 'root' -Command 'cat /var/lib/hermes-bootstrap/stage.txt 2>/dev/null || true' -TimeoutSeconds 20
            $result = Invoke-WslBash -Distro $DistroName -User 'root' -Command 'cat /var/lib/hermes-bootstrap/result 2>/dev/null || true' -TimeoutSeconds 20
        }
        catch {
            $stage = ''
            $result = ''
        }

        $trimmedStage = if ($stage) { [string]$stage.Trim() } else { '' }
        $stateStage = if ($stage) { [string]$stage.Trim() } else { 'distro-ready' }
        Save-HermesState -Stage $stateStage -Config $ResolvedConfig -LastResult 'bootstrap-running'

        $sourcesHealth = Get-UbuntuSourcesHealth -DistroName $DistroName
        if ($sourcesHealth.Status -eq 'placeholder' -or ($sourcesHealth.Status -eq 'invalid' -and $trimmedStage -eq 'install-hermes')) {
            $diagnostics = Get-BootstrapDiagnostics -DistroName $DistroName -IncludeCloudInit
            throw "Bootstrap detected an invalid ubuntu.sources file before completion.`n$diagnostics"
        }

        if ($result -eq 'ready_for_key') {
            if (-not $launchProcess.HasExited) {
                $launchProcess.WaitForExit(1000) | Out-Null
            }
            Write-Step '无密钥 bootstrap 已完成，正在等待本地 key 输入。'
            return
        }

        if ($result -like 'failed:*') {
            $diagnostics = Get-BootstrapDiagnostics -DistroName $DistroName -IncludeCloudInit
            throw "Bootstrap failed: $result`n$diagnostics"
        }

        if ($launchProcess.HasExited -and -not $result) {
            $diagnostics = Get-BootstrapDiagnostics -DistroName $DistroName -IncludeCloudInit
            throw "Bootstrap process exited before ready_for_key was recorded.`n$diagnostics"
        }

        if ($elapsed -ge $hard) {
            & wsl.exe --shutdown 2>$null | Out-Null
            $lastStage = if ($stage) { $stage } else { 'unknown' }
            $diagnostics = Get-BootstrapDiagnostics -DistroName $DistroName -IncludeCloudInit
            throw "Bootstrap exceeded $HardTimeoutMinutes minutes. Last stage: $lastStage`n$diagnostics"
        }

        if ($elapsed -ge $soft) {
            $softTimeoutDiagnostics = Get-BootstrapDiagnostics -DistroName $DistroName
            Write-Step "bootstrap 已超过 $SoftTimeoutMinutes 分钟。当前阶段：$stage`n$softTimeoutDiagnostics"
        }
        else {
            Write-Step ("当前 bootstrap 阶段：{0}" -f ($(if ($stage) { $stage } else { '等待中' })))
        }

        Start-Sleep -Seconds 15
        $launchProcess.Refresh()
    }
}

try {
    $config = Get-ResolvedInstallConfig
    if ($config.InstallMode -ne 'dedicated') {
        throw 'windows-bootstrap.ps1 only supports the dedicated install mode.'
    }
    Ensure-Directory -Path $paths.Downloads
    Ensure-Directory -Path $paths.StateRoot
    $baseImagePath = Get-ExistingHermesBaseImagePath
    $usingPrebuiltBaseImage = -not [string]::IsNullOrWhiteSpace($baseImagePath)
    Save-HermesState -Stage 'bootstrap-started' -Config $config

    Write-Phase -Index 1 -Total $totalPhases -Message '检查管理员权限、下载目录和解析后的默认配置'
    if (-not (Test-IsAdministrator)) {
        throw 'windows-bootstrap.ps1 must run as administrator.'
    }

    $completed.Add('Confirmed administrator privileges.')
    $completed.Add('Confirmed the downloads directory exists.')
    $completed.Add(("Resolved install defaults: distro {0}, user {1}, model {2}, api_mode {3}" -f $config.DistroName, $config.Username, $config.Model, $config.ApiMode))
    if ($usingPrebuiltBaseImage -and $config.Username -ne (Get-HermesDefaults).Username) {
        throw ('Prebuilt base image installs currently require WSL_USERNAME={0}.' -f (Get-HermesDefaults).Username)
    }
    if ($usingPrebuiltBaseImage) {
        $completed.Add(("Detected a prebuilt Hermes WSL base image asset: {0}" -f $baseImagePath))
    }
    if ($config.InstallEnvPresent) {
        $completed.Add('Detected install.env and only used non-secret overrides from it.')
    }
    $environment = Get-WslEnvironmentClassification -Config $config
    $completed.Add(("Classified the current WSL environment as: {0}" -f $environment.Classification))

    if ($environment.Classification -eq 'target-name-conflict') {
        $distroNames = if ($environment.DistributionNames.Count -gt 0) { $environment.DistributionNames -join ', ' } else { 'none' }
        Save-HermesState -Stage 'blocked-existing-wsl' -Config $config -Notes $environment.Summary -LastResult 'target-name-conflict'
        Write-Step "由于专用目标名称与现有发行版冲突，当前流程已被阻止：$distroNames"
        return [PSCustomObject]@{
            Status         = 'blocked-existing-wsl'
            Classification = $environment.Classification
            DistroName     = $config.DistroName
            Username       = $config.Username
        }
    }

    if ($environment.Classification -eq 'managed-installed') {
        Save-HermesState -Stage 'success' -Config $config -LastResult 'already-installed'
        Write-Step "检测到 $($config.DistroName) 已存在 Hermes 托管安装。"
        return [PSCustomObject]@{
            Status         = 'already-installed'
            Classification = $environment.Classification
            DistroName     = $config.DistroName
            Username       = $config.Username
        }
    }

    Write-Phase -Index 2 -Total $totalPhases -Message '启用 WSL 并检查是否必须重启'
    if ($environment.Classification -eq 'resume-hermes') {
        $completed.Add('Detected a resume-only Hermes-managed environment and skipped generic WSL platform enablement.')
        Save-HermesState -Stage 'wsl-ready' -Config $config -LastResult 'resume-hermes'
    }
    else {
        & wsl.exe --install --no-distribution | Out-Null
        & wsl.exe --set-default-version 2 | Out-Null
        $completed.Add('Ran wsl --install --no-distribution.')
        $completed.Add('Ran wsl --set-default-version 2.')

        $reboot = Test-RebootPending
        if ($reboot.CBSRebootPending -or $reboot.WURebootRequired) {
            $resumeMethod = Register-HermesResume
            Save-HermesState -Stage 'reboot-required' -Config $config -ResumeMethod $resumeMethod -Notes 'Waiting for Windows reboot to resume setup.' -LastResult 'blocked-reboot'
            $resumeMethodLabel = if ($resumeMethod -eq 'runonce') { 'RunOnce' } else { $resumeMethod }
            Write-Step "检测到 Windows 需要重启，已注册一次性恢复入口（$resumeMethodLabel）。"
            $userChoice = Show-HermesRebootRequiredDialog -ResumeMethod $resumeMethodLabel
            if ($userChoice -eq 'restart-now') {
                Write-Step '用户选择立即重启，Windows 即将重启。'
                & shutdown.exe /r /t 0 | Out-Null
            }
            else {
                Write-Step '用户选择稍后手动重启。'
            }
            return [PSCustomObject]@{
                Status       = 'blocked-reboot'
                ResumeMethod = $resumeMethod
                UserChoice   = $userChoice
                DistroName   = $config.DistroName
                Username     = $config.Username
            }
        }

        $completed.Add('Confirmed there is no pending reboot.')
        Save-HermesState -Stage 'wsl-ready' -Config $config
        $environment = Get-WslEnvironmentClassification -Config $config
    }

    Write-Phase -Index 3 -Total $totalPhases -Message '准备或复用本地 WSL 安装资源'
    $packagePath = Join-Path $paths.Downloads $config.PackageName
    if ($environment.Classification -eq 'resume-hermes') {
        $completed.Add('Skipped local asset preparation because the Hermes-managed distribution already exists.')
        Save-HermesState -Stage 'package-ready' -Config $config -LastResult 'resume-hermes'
    }
    elseif ($usingPrebuiltBaseImage) {
        $baseImageSize = (Get-Item -LiteralPath $baseImagePath).Length
        $baseImageHash = Get-FileSha256OrNull -Path $baseImagePath
        $completed.Add(("Prebuilt Hermes WSL base image is ready: {0}" -f $baseImagePath))
        $completed.Add(("Recorded prebuilt base image size: {0} bytes" -f $baseImageSize))
        $completed.Add(("Recorded prebuilt base image SHA256: {0}" -f $baseImageHash))
        Save-HermesState -Stage 'package-ready' -Config $config -Notes $config.BaseImageMode -LastResult 'prebuilt-base-image'
    }
    else {
        $metadataProbe = Try-GetRemoteFileMetadata -Uri $config.PackageUrl
        $meta = if ($metadataProbe.Success) { $metadataProbe.Metadata } else { $null }
        $reuse = $false

        if (-not $metadataProbe.Success) {
            Write-Step ("Ubuntu 安装包远程元数据获取失败，将按本地缓存优先继续处理：{0}" -f $metadataProbe.Error)
            $completed.Add(("Ubuntu 安装包远程元数据获取失败，但仍继续处理本地缓存：{0}" -f $metadataProbe.Error))
        }

        if (Test-Path -LiteralPath $packagePath) {
            $item = Get-Item -LiteralPath $packagePath
            if ($item.Length -gt 0 -and ($null -eq $meta -or $meta.ContentLength -le 0 -or $item.Length -eq $meta.ContentLength)) {
                $reuse = $true
                Write-Step "复用已有 Ubuntu 安装包：$packagePath"
            }
            elseif ($item.Length -le 0) {
                Write-Step '现有 Ubuntu 安装包为空文件，先删除再重新下载。'
                Remove-Item -LiteralPath $packagePath -Force
            }
            else {
                Write-Step '现有 Ubuntu 安装包大小不匹配，先删除再重新下载。'
                Remove-Item -LiteralPath $packagePath -Force
            }
        }

        if (-not $reuse) {
            Download-FileWithProgress `
                -Uri $config.PackageUrl `
                -OutputPath $packagePath `
                -Activity '正在下载 Ubuntu WSL 安装包' `
                -StatusLabel 'Ubuntu WSL 安装包下载' `
                -TotalBytesHint $(if ($null -ne $meta) { $meta.ContentLength } else { 0 })
        }

        $packageHash = Get-FileSha256OrNull -Path $packagePath
        $packageLength = (Get-Item -LiteralPath $packagePath).Length
        if ($null -ne $meta -and $meta.ContentLength -gt 0 -and $packageLength -ne $meta.ContentLength) {
            throw "Downloaded package size mismatch. Expected $($meta.ContentLength) bytes, got $packageLength bytes."
        }
        $completed.Add(("Ubuntu package is ready: {0}" -f $packagePath))
        $completed.Add(("Recorded Ubuntu package size: {0} bytes" -f $packageLength))
        $completed.Add(("Recorded Ubuntu package SHA256: {0}" -f $packageHash))
        Save-HermesState -Stage 'package-ready' -Config $config
    }

    Assert-SufficientDedicatedInstallDiskSpace -ResolvedConfig $config -UsingPrebuiltBaseImage:$usingPrebuiltBaseImage

    Write-Phase -Index 4 -Total $totalPhases -Message '生成或准备不含密钥的 bootstrap 载荷'
    if ($environment.Classification -eq 'resume-hermes') {
        $completed.Add('Skipped bootstrap payload rendering because the Hermes-managed distribution already exists.')
        Save-HermesState -Stage 'cloud-init-ready' -Config $config -LastResult 'resume-hermes'
    }
    elseif ($usingPrebuiltBaseImage) {
        $completed.Add('Skipped cloud-init rendering because the prebuilt Hermes WSL base image will be finalized locally after import.')
        Save-HermesState -Stage 'cloud-init-ready' -Config $config -Notes $config.BaseImageMode -LastResult 'prebuilt-base-image'
    }
    else {
        $cloudInitPath = Join-Path $paths.CloudInitDir ("{0}.user-data" -f $config.DistroName)
        Render-CloudInit -ResolvedConfig $config -OutputPath $cloudInitPath
        $completed.Add(("Rendered cloud-init file: {0}" -f $cloudInitPath))
        $completed.Add('Rendered Hermes install and key-injection helper scripts into the cloud-init template.')
        Save-HermesState -Stage 'cloud-init-ready' -Config $config
    }

    Write-Phase -Index 5 -Total $totalPhases -Message '导入目标 WSL 发行版并轮询状态'
    if ($environment.Classification -eq 'resume-hermes') {
        Write-Step "复用 Hermes 托管发行版 $($config.DistroName)。"
        $completed.Add(("Reused the Hermes-managed distribution: {0}" -f $config.DistroName))
    }
    elseif (Test-WslDistributionExists -Name $config.DistroName) {
        throw "Distribution $($config.DistroName) already exists, but this run is not allowed to reuse it."
    }
    elseif ($usingPrebuiltBaseImage) {
        $installProcess = Start-WslImportProcess -BaseImagePath $baseImagePath -DistroName $config.DistroName
        Wait-ForDistroRegistration -Process $installProcess -DistroName $config.DistroName
        $completed.Add(("Imported the prebuilt Hermes WSL base image as distribution: {0}" -f $config.DistroName))
    }
    else {
        $installProcess = Start-WslInstallProcess -PackagePath $packagePath -DistroName $config.DistroName
        Wait-ForDistroRegistration -Process $installProcess -DistroName $config.DistroName
        $completed.Add(("Imported distribution with --no-launch: {0}" -f $config.DistroName))
    }

    $environment = Get-WslEnvironmentClassification -Config $config
    Save-HermesState -Stage 'distro-ready' -Config $config

    Write-Phase -Index 6 -Total $totalPhases -Message '完成导入镜像的收尾并等待 ready_for_key'
    Save-HermesState -Stage 'install-hermes' -Config $config -LastResult 'bootstrap-running'
    if ($usingPrebuiltBaseImage -and $environment.Classification -ne 'resume-hermes') {
        Initialize-PrebuiltBaseDistro -ResolvedConfig $config
    }
    elseif ($environment.Classification -eq 'resume-hermes') {
        $resumeRepairResult = Invoke-ResumeBootstrapRepair -ResolvedConfig $config
        if ($resumeRepairResult -eq 'repaired') {
            $completed.Add('Detected a resume-hermes install that was still blocked on the old online Hermes fetch path.')
            $completed.Add('Repaired the resumed bootstrap by consuming the Windows-side cached Hermes install assets.')
        }
        elseif ($resumeRepairResult -eq 'ready') {
            $completed.Add('Detected that the resumed Hermes bootstrap had already reached ready-for-key.')
        }
        else {
            Wait-ForBootstrap -ResolvedConfig $config
        }
    }
    else {
        Wait-ForBootstrap -ResolvedConfig $config
    }
    if (-not (Test-WslDistributionHealthy -Name $config.DistroName)) {
        throw "Distribution $($config.DistroName) is registered but failed the health probe."
    }

    if ($usingPrebuiltBaseImage) {
        $completed.Add('Imported and finalized the prebuilt Hermes WSL base image.')
        $completed.Add('Verified the prebuilt image is now waiting for one local key entry.')
        Save-HermesState -Stage 'ready-for-key' -Config $config -Notes $config.BaseImageMode -LastResult 'ready-for-key'
    }
    else {
        $completed.Add('Completed the first Ubuntu launch.')
        $completed.Add('Created the Linux user and set it as the default WSL user.')
        $completed.Add('Installed Hermes without any secret material. The system is now waiting for a local key entry.')
        Save-HermesState -Stage 'ready-for-key' -Config $config -LastResult 'ready-for-key'
    }
    return [PSCustomObject]@{
        Status       = 'ready-for-key'
        ResumeMethod = ''
        DistroName   = $config.DistroName
        Username     = $config.Username
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
