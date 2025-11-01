#!/usr/bin/env bash

set -euo pipefail

REPO="mplabs/backup-sqrt"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-$INSTALL_PREFIX/sbin}"
DOC_DIR="${DOC_DIR:-$INSTALL_PREFIX/share/doc/backup-sqrt}"
CONFIG_DIR="${CONFIG_DIR:-/etc/config-backup}"
PROFILES_DIR="${PROFILES_DIR:-$CONFIG_DIR/profiles}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/backup-configs}"
COMMAND_REQUIREMENTS=(curl tar gzip gpg rsync sha256sum)
APT_DEPENDENCIES=(curl gpg rsync tar gzip coreutils zstd)

log() {
  echo "[backup-sqrt] $*"
}

ensure_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This installer must be run as root (try: sudo bash install.sh)" >&2
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  if command_exists apt-get; then
    local missing=()
    for pkg in "$@"; do
      if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
      fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      log "Installing packages: ${missing[*]}"
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
  else
    log "Skipping package installation; unsupported package manager."
  fi
}

resolve_version() {
  local requested="${VERSION:-latest}"
  local api_url
  if [[ "$requested" == "latest" ]]; then
    api_url="https://api.github.com/repos/${REPO}/releases/latest"
  else
    api_url="https://api.github.com/repos/${REPO}/releases/tags/${requested}"
  fi
  local release_json
  release_json=$(curl -fsSL "$api_url")
  local tag
  tag=$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  if [[ -z "$tag" ]]; then
    echo "Unable to determine release tag from GitHub API response." >&2
    exit 1
  fi
  VERSION_RESOLVED="$tag"
}

download_release() {
  local tmpdir=$1
  local asset="backup-sqrt-${VERSION_RESOLVED}.tar.gz"
  local url="https://github.com/${REPO}/releases/download/${VERSION_RESOLVED}/${asset}"
  local target="${tmpdir}/${asset}"
  log "Downloading ${url}"
  curl -fL "$url" -o "$target"

  local checksum_url="${url}.sha256"
  local checksum_file="${target}.sha256"
  if curl -fL "$checksum_url" -o "$checksum_file"; then
    log "Verifying checksum"
    (cd "$tmpdir" && sha256sum -c "$(basename "$checksum_file")")
  else
    log "Checksum file not available, skipping verification."
  fi

  RELEASE_ARCHIVE="$target"
}

install_files() {
  local tmpdir=$1
  local extract_dir="${tmpdir}/extracted"
  mkdir -p "$extract_dir"
  tar -xzf "$RELEASE_ARCHIVE" -C "$extract_dir"

  install -d "$BIN_DIR"
  install -m 0750 "$extract_dir/scripts/backup-configs.sh" "$BIN_DIR/backup-configs"
  ln -sf "$BIN_DIR/backup-configs" "$BIN_DIR/backup-configs.sh"

  install -d "$DOC_DIR"
  (
    shopt -s nullglob
    for doc in "$extract_dir"/docs/*.md; do
      install -m 0644 "$doc" "$DOC_DIR/"
    done
  )

  install -d "$PROFILES_DIR"
  if [[ ! -f "$PROFILES_DIR/example.conf" ]]; then
    install -m 0640 "$extract_dir/config/profiles/example.conf" "$PROFILES_DIR/example.conf"
  else
    log "example.conf already exists; leaving in place."
  fi

  install -d "$CONFIG_DIR/passphrases"
  log "Installed backup-configs to $BIN_DIR"
}

configure_cron() {
  if [[ -f "$CRON_FILE" ]]; then
    log "Cron file $CRON_FILE already exists; skipping."
    return
  fi

  cat >"$CRON_FILE" <<'EOF'
# Cron job for backup-configs.
# Uncomment and adjust environment variables before enabling.
# 15 2 * * * root CONFIG_PROFILES_DIR=/etc/config-backup/profiles \
#   UPTIME_KUMA_WEBHOOK=https://uptime.example.com/api/push/<token> \
#   /usr/local/sbin/backup-configs
EOF
  chmod 0644 "$CRON_FILE"
  log "Created cron template at $CRON_FILE (disabled by default)."
}

main() {
  ensure_root
  install_packages "${APT_DEPENDENCIES[@]}"

  for cmd in "${COMMAND_REQUIREMENTS[@]}"; do
    if ! command_exists "$cmd"; then
      echo "Required command '$cmd' is not available even after package installation." >&2
      exit 1
    fi
  done

  resolve_version
  log "Installing backup-sqrt version ${VERSION_RESOLVED}"
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  download_release "$tmpdir"
  install_files "$tmpdir"
  configure_cron

  log "Installation complete."
  log "Next steps:"
  log "  1. Populate /etc/config-backup/profiles with real profile configs."
  log "  2. Store symmetric passphrases in 1Password or /etc/config-backup/passphrases."
  log "  3. Enable cron in $CRON_FILE once environment variables are set."
}

main "$@"
