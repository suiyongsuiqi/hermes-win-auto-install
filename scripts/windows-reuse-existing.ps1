[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\windows-common.ps1"

$paths = Get-HermesPaths
$completed = New-Object System.Collections.Generic.List[string]

function Test-ReuseInstallHealthy {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $command = @'
set -euo pipefail
if [ -x "$HOME/.local/bin/hermes" ] && [ -x /usr/local/bin/hermes-inject-key.sh ] && [ -f /var/lib/hermes-bootstrap/config.env ]; then
  printf 'ready'
else
  printf 'missing'
fi
'@

    try {
        $result = Invoke-WslBash -Distro $ResolvedConfig.DistroName -User $ResolvedConfig.Username -Command $command -TimeoutSeconds 30
        return $result.Trim() -eq 'ready'
    }
    catch {
        return $false
    }
}

function Remove-ReusedHermesAssets {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $targetUser = $ResolvedConfig.Username.Replace("'", "'\''")
    $cleanupCommand = @"
set -euo pipefail
TARGET_USER='$targetUser'
HOME_DIR="\$(getent passwd "\$TARGET_USER" | cut -d: -f6)"
if [ -z "\$HOME_DIR" ]; then
  echo 'Could not resolve the selected Linux home directory.' >&2
  exit 1
fi

rm -f /usr/local/bin/hermes-inject-key.sh
rm -rf /var/lib/hermes-bootstrap
runuser -u "\$TARGET_USER" -- bash -lc 'rm -rf ~/.hermes ~/.cache/hermes ~/.local/bin/hermes ~/.local/bin/hermes-* ~/.local/share/hermes 2>/dev/null || true'
printf 'clean'
"@

    $result = Invoke-WslBash `
        -Distro $ResolvedConfig.DistroName `
        -User 'root' `
        -Command $cleanupCommand `
        -TimeoutSeconds 300 `
        -ProgressMessage '正在清理所选 WSL 发行版中的 Hermes 专属文件。' `
        -RequireSuccess

    if ($result.Trim() -ne 'clean') {
        throw 'Hermes-only cleanup inside the selected WSL distribution did not finish cleanly.'
    }
}

function Invoke-ReuseInstall {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $installScriptPath = Join-Path $paths.Downloads $ResolvedConfig.InstallScriptName
    $sourceArchivePath = Join-Path $paths.Downloads $ResolvedConfig.SourceArchiveName
    $nodeArchivePath = Join-Path $paths.Downloads $ResolvedConfig.NodeArchiveName

    if (-not (Test-Path -LiteralPath $installScriptPath) -or -not (Test-Path -LiteralPath $sourceArchivePath)) {
        throw 'Local cached Hermes assets are missing. Run the prefetch stage first.'
    }

    $usernameB64 = Convert-ToBase64 -Value $ResolvedConfig.Username
    $baseUrlB64 = Convert-ToBase64 -Value $ResolvedConfig.BaseUrl
    $modelB64 = Convert-ToBase64 -Value $ResolvedConfig.Model
    $apiModeB64 = Convert-ToBase64 -Value $ResolvedConfig.ApiMode
    $installScriptPathInWsl = (Convert-WindowsPathToWslMountPath -Path $installScriptPath).Replace("'", "'\''")
    $sourceArchivePathInWsl = (Convert-WindowsPathToWslMountPath -Path $sourceArchivePath).Replace("'", "'\''")
    $nodeArchivePathInWsl = (Convert-WindowsPathToWslMountPath -Path $nodeArchivePath).Replace("'", "'\''")

    $script = @'
set -euo pipefail

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
  runuser -u "$TARGET_USER" -- bash -lc "$1"
}

TARGET_USER="$(decode_b64 '__USERNAME_B64__')"
BASE_URL="$(decode_b64 '__BASE_URL_B64__')"
MODEL_NAME="$(decode_b64 '__MODEL_B64__')"
API_MODE="$(decode_b64 '__API_MODE_B64__')"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$HOME_DIR" ]; then
  echo 'Could not resolve the selected Linux home directory.' >&2
  exit 1
fi

HERMES_HOME="$HOME_DIR/.hermes"
STAGE_DIR=/var/lib/hermes-bootstrap
LINUX_INSTALL_SCRIPT='__INSTALL_SCRIPT_PATH__'
LINUX_SOURCE_ARCHIVE='__SOURCE_ARCHIVE_PATH__'
LINUX_NODE_ARCHIVE='__NODE_ARCHIVE_PATH__'
APT_PRIMARY_URL='__APT_PRIMARY_URL__'
APT_SECURITY_URL='__APT_SECURITY_URL__'
NODE_DIST_MIRROR_URL='__NODE_DIST_MIRROR_URL__'
NPM_REGISTRY_URL='__NPM_REGISTRY_URL__'

mkdir -p "$STAGE_DIR"
cat > "$STAGE_DIR/config.env" <<EOF
HERMES_BOOTSTRAP_USERNAME_B64=__USERNAME_B64__
HERMES_BOOTSTRAP_BASE_URL_B64=__BASE_URL_B64__
HERMES_BOOTSTRAP_MODEL_B64=__MODEL_B64__
HERMES_BOOTSTRAP_API_MODE_B64=__API_MODE_B64__
EOF

printf '%s\n' reuse-existing-distro > "$STAGE_DIR/bootstrap_mode"
printf '%s\n' install-hermes > "$STAGE_DIR/stage.txt"
rm -f "$STAGE_DIR/result" "$STAGE_DIR/key_status" "$STAGE_DIR/key_updated_at"

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
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
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
chmod 600 "$HERMES_HOME/.env" "$HERMES_HOME/config.yaml"
printf '%s\n' success > "$STAGE_DIR/key_status"
printf '%s\n' "$(date -Iseconds)" > "$STAGE_DIR/key_updated_at"
EOS

chmod 700 /usr/local/bin/hermes-inject-key.sh

. /etc/os-release
if [ "${ID:-}" = "ubuntu" ]; then
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
fi

apt-get update -qq

TEMP_DIR=/var/tmp/hermes-reuse-install
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

    local local_archive="__LOCAL_SOURCE_ARCHIVE__"
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
    local arch
    local node_arch
    local node_os
    local mirror_root="__NODE_DIST_MIRROR_URL__"
    local local_archive="__LOCAL_NODE_ARCHIVE__"
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
    else
        index_url="${mirror_root}/latest-v${NODE_VERSION}.x/"
        tarball_name=$(curl -fsSL "${index_url}SHASUMS256.txt" | grep -oE "node-v${NODE_VERSION}\.[0-9]+\.[0-9]+-${node_os}-${node_arch}\.tar\.xz" | head -1)
        archive_path="$tmp_dir/$tarball_name"
        curl -fsSL "${index_url}${tarball_name}" -o "$archive_path"
    fi

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
        return 0
    fi

    export npm_config_registry="__NPM_REGISTRY_URL__"
    export npm_config_audit=false
    export npm_config_fund=false
    export npm_config_update_notifier=false
    export npm_config_prefer_offline=true
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

    if [ -f "$INSTALL_DIR/package.json" ]; then
        cd "$INSTALL_DIR"
        npm install --silent --ignore-scripts 2>/dev/null || {
            log_warn "npm install failed (browser tools may not work)"
        }
    fi
}

main
EOF

ESCAPED_ARCHIVE="$(printf '%s' "$LINUX_SOURCE_ARCHIVE" | sed 's/[&|]/\\&/g')"
sed -i "s|__LOCAL_SOURCE_ARCHIVE__|$ESCAPED_ARCHIVE|g" "$PATCHED_SCRIPT"
ESCAPED_NODE_ARCHIVE="$(printf '%s' "$LINUX_NODE_ARCHIVE" | sed 's/[&|]/\\&/g')"
sed -i "s|__LOCAL_NODE_ARCHIVE__|$ESCAPED_NODE_ARCHIVE|g" "$PATCHED_SCRIPT"
ESCAPED_NODE_DIST_MIRROR="$(printf '%s' "$NODE_DIST_MIRROR_URL" | sed 's/[&|]/\\&/g')"
sed -i "s|__NODE_DIST_MIRROR_URL__|$ESCAPED_NODE_DIST_MIRROR|g" "$PATCHED_SCRIPT"
ESCAPED_NPM_REGISTRY="$(printf '%s' "$NPM_REGISTRY_URL" | sed 's/[&|]/\\&/g')"
sed -i "s|__NPM_REGISTRY_URL__|$ESCAPED_NPM_REGISTRY|g" "$PATCHED_SCRIPT"
chmod 755 "$PATCHED_SCRIPT"

run_as_user "rm -rf ~/.hermes/hermes-agent"
run_as_user "$(printf '%q' "$PATCHED_SCRIPT") --skip-setup"

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$HERMES_HOME"
touch "$HOME_DIR/.hushlogin"
chown "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.hushlogin"

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
chown "$TARGET_USER:$TARGET_USER" "$HERMES_HOME/config.yaml"
chmod 600 "$HERMES_HOME/config.yaml"

printf '%s\n' ready-for-key > "$STAGE_DIR/stage.txt"
printf '%s\n' ready_for_key > "$STAGE_DIR/result"
run_as_user 'export PATH="$HOME/.local/bin:$PATH"; ~/.local/bin/hermes version >/dev/null'
rm -rf "$TEMP_DIR"
'@

    $script = $script.Replace('__USERNAME_B64__', $usernameB64)
    $script = $script.Replace('__BASE_URL_B64__', $baseUrlB64)
    $script = $script.Replace('__MODEL_B64__', $modelB64)
    $script = $script.Replace('__API_MODE_B64__', $apiModeB64)
    $script = $script.Replace('__INSTALL_SCRIPT_PATH__', $installScriptPathInWsl)
    $script = $script.Replace('__SOURCE_ARCHIVE_PATH__', $sourceArchivePathInWsl)
    $script = $script.Replace('__NODE_ARCHIVE_PATH__', $nodeArchivePathInWsl)
    $script = $script.Replace('__APT_PRIMARY_URL__', $ResolvedConfig.AptPrimaryUrl)
    $script = $script.Replace('__APT_SECURITY_URL__', $ResolvedConfig.AptSecurityUrl)
    $script = $script.Replace('__NODE_DIST_MIRROR_URL__', $ResolvedConfig.NodeDistMirrorUrl)
    $script = $script.Replace('__NPM_REGISTRY_URL__', $ResolvedConfig.NpmRegistryUrl)

    $scriptPath = Join-Path $paths.StateRoot ("reuse-install-{0}.sh" -f ([guid]::NewGuid().ToString()))
    $scriptContent = ($script -replace "`r`n", "`n") -replace "`r", ''
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($scriptPath, $scriptContent, $utf8NoBom)
    $scriptPathInWsl = Convert-WindowsPathToWslMountPath -Path $scriptPath

    try {
        Invoke-WslBash `
            -Distro $ResolvedConfig.DistroName `
            -User 'root' `
            -Command ("chmod 700 '{0}' && bash '{0}'" -f $scriptPathInWsl) `
            -TimeoutSeconds 3600 `
            -ProgressMessage '正在将 Hermes 安装到所选现有 WSL 发行版中。' `
            -RequireSuccess | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $scriptPath) {
            Remove-Item -LiteralPath $scriptPath -Force
        }
    }
}

try {
    $config = Get-ResolvedInstallConfig
    if ($config.InstallMode -ne 'reuse-existing') {
        throw 'windows-reuse-existing.ps1 only supports the reuse-existing install mode.'
    }

    Write-Step '开始执行 reuse-existing WSL 安装路径。'
    $environment = Get-WslEnvironmentClassification -Config $config
    if ($environment.Classification -eq 'selected-distro-missing') {
        throw "The selected distribution $($config.DistroName) no longer exists."
    }
    if ($environment.Classification -eq 'selected-distro-wsl1') {
        throw "The selected distribution $($config.DistroName) is not running on WSL 2."
    }

    $osInfo = Get-WslOsReleaseInfo -DistroName $config.DistroName
    if (-not $osInfo.HasApt -or $osInfo.Id -notin @('ubuntu', 'debian')) {
        throw "The selected distribution $($config.DistroName) is not a supported Ubuntu or Debian apt-based distro."
    }

    $completed.Add(("Confirmed the selected existing distro is reusable: {0} ({1})" -f $config.DistroName, $osInfo.PrettyName))

    if (Test-ReuseInstallHealthy -ResolvedConfig $config) {
        Save-HermesState -Stage 'ready-for-key' -Config $config -LastResult 'reuse-existing-ready'
        $completed.Add('Detected an existing Hermes-managed installation that is already ready for local key injection.')
        return [PSCustomObject]@{
            Status     = 'ready-for-key'
            DistroName = $config.DistroName
            Username   = $config.Username
        }
    }
    Remove-ReusedHermesAssets -ResolvedConfig $config
    $completed.Add('Removed old Hermes-only files from the selected existing distro without touching unrelated user data.')

    Save-HermesState -Stage 'install-hermes' -Config $config -LastResult 'reuse-existing-installing'
    Invoke-ReuseInstall -ResolvedConfig $config
    $completed.Add('Installed Hermes into the selected existing distro from local cached assets.')

    if (-not (Test-ReuseInstallHealthy -ResolvedConfig $config)) {
        throw 'The reused distro did not reach the ready-for-key state after installation.'
    }
    Save-HermesState -Stage 'ready-for-key' -Config $config -LastResult 'ready-for-key'
    return [PSCustomObject]@{
        Status     = 'ready-for-key'
        DistroName = $config.DistroName
        Username   = $config.Username
    }
}
catch {
    $configForFailure = if ($null -ne (Get-Variable -Name config -ErrorAction SilentlyContinue)) { $config } else { Get-HermesDefaults }
    Save-HermesState -Stage 'reuse-existing-failed' -Config $configForFailure -LastResult $_.Exception.Message
    throw
}
