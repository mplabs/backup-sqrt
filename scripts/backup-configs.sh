#!/usr/bin/env bash

# Backup Duply configuration bundles with symmetric GPG encryption.
# Reads declarative per-profile config files from $CONFIG_PROFILES_DIR (defaults
# to ./config/profiles or /etc/config-backup/profiles).

set -euo pipefail

CONFIG_ROOT="${CONFIG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEFAULT_PROFILES_DIR="$CONFIG_ROOT/config/profiles"
if [[ ! -d "$DEFAULT_PROFILES_DIR" ]]; then
  DEFAULT_PROFILES_DIR="/etc/config-backup/profiles"
fi
CONFIG_PROFILES_DIR="${CONFIG_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}"
TMP_PARENT="${TMPDIR:-/tmp}/config-backup"
HOST_ID="${HOST_ID:-$(hostname -f 2>/dev/null || hostname)}"
DATESTAMP="$(date +%Y%m%dT%H%M%S)"
RSYNC_FLAGS="${RSYNC_FLAGS:--az}"
UPTIME_KUMA_WEBHOOK="${UPTIME_KUMA_WEBHOOK:-}"
OP_CLI="${OP_CLI:-$(command -v op 2>/dev/null || true)}"
LOCK_FILE="${LOCK_FILE:-/var/lock/backup-configs.lock}"

abort() {
  local msg=$1
  echo "ERROR: $msg" >&2
  if [[ -n "$UPTIME_KUMA_WEBHOOK" ]]; then
    curl -fsS -X POST "$UPTIME_KUMA_WEBHOOK" \
      -d "status=down" \
      --data-urlencode "msg=$msg" >/dev/null || true
  fi
  exit 1
}

require_command() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || abort "Required command '$cmd' not found in PATH."
}

send_webhook() {
  local status=$1
  local message=$2
  [[ -z "$UPTIME_KUMA_WEBHOOK" ]] && return 0
  curl -fsS -X POST "$UPTIME_KUMA_WEBHOOK" \
    -d "status=$status" \
    --data-urlencode "msg=$message" >/dev/null || true
}

trim() {
  local var=$1
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

strip_quotes() {
  local val=$1
  if [[ "$val" =~ ^\".*\"$ || "$val" =~ ^\'.*\'$ ]]; then
    val=${val:1:-1}
  fi
  printf '%s' "$val"
}

fetch_passphrase() {
  local secret_ref=$1
  local file_ref=$2

  if [[ -n "$secret_ref" ]]; then
    [[ -n "$OP_CLI" ]] || abort "op CLI is not available but PASSPHRASE_SECRET was set."
    "$OP_CLI" read "$secret_ref"
  elif [[ -n "$file_ref" ]]; then
    [[ -r "$file_ref" ]] || abort "Passphrase file '$file_ref' is not readable."
    cat "$file_ref"
  else
    abort "Neither PASSPHRASE_SECRET nor PASSPHRASE_FILE configured for profile."
  fi
}

run_as_user() {
  local user=$1
  shift
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$user" "$@"
  else
    abort "Neither runuser nor sudo is available to impersonate '$user'."
  fi
}

parse_profile_file() {
  local profile_file=$1
  local line key value

  PROFILE_NAME=""
  PROFILE_USER=""
  DUPLY_DIR=""
  RSYNC_TARGET=""
  PASSPHRASE_SECRET=""
  PASSPHRASE_FILE=""
  CRON_REFERENCE=""
  PROFILE_NOTES=""
  COMPRESSION="gzip"
  INCLUDE_PATHS=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" != *"="* ]]; then
      abort "Invalid line in $profile_file: '$line'"
    fi
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    value="$(strip_quotes "$value")"

    case "${key,,}" in
      profile_name) PROFILE_NAME="$value" ;;
      profile_user) PROFILE_USER="$value" ;;
      duply_dir) DUPLY_DIR="$value" ;;
      rsync_target) RSYNC_TARGET="$value" ;;
      passphrase_secret) PASSPHRASE_SECRET="$value" ;;
      passphrase_file) PASSPHRASE_FILE="$value" ;;
      cron_reference) CRON_REFERENCE="$value" ;;
      notes) PROFILE_NOTES="$value" ;;
      compression) COMPRESSION="${value,,}" ;;
      include) INCLUDE_PATHS+=("$value") ;;
      *)
        abort "Unknown key '$key' in $profile_file"
        ;;
    esac
  done <"$profile_file"
}

process_profile() {
  local profile_file=$1
  local tarball bundle checksum compression_cmd passfile duply_basename include include_stage include_owner workdir

  parse_profile_file "$profile_file"

  : "${PROFILE_NAME:?PROFILE_NAME is required}"
  : "${PROFILE_USER:?PROFILE_USER is required}"
  : "${DUPLY_DIR:?DUPLY_DIR is required}"
  : "${RSYNC_TARGET:?RSYNC_TARGET is required}"
  [[ -d "$DUPLY_DIR" ]] || abort "Duply dir '$DUPLY_DIR' for $PROFILE_NAME not found."
  if [[ -n "$PASSPHRASE_SECRET" ]] && [[ -z "$OP_CLI" ]]; then
    abort "Profile $PROFILE_NAME requests PASSPHRASE_SECRET but op CLI is unavailable."
  fi

  workdir="$(mktemp -d "$TMP_PARENT/${PROFILE_NAME}-${DATESTAMP}-XXXXXX")"

  case "$COMPRESSION" in
    gzip|gz|"")
      COMPRESSION="gzip"
      tarball="$workdir/${PROFILE_NAME}-${DATESTAMP}.tar.gz"
      compression_cmd="gzip -c"
      require_command gzip
      ;;
    zstd|zst)
      COMPRESSION="zstd"
      tarball="$workdir/${PROFILE_NAME}-${DATESTAMP}.tar.zst"
      compression_cmd="zstd -c --quiet"
      require_command zstd
      ;;
    none|tar)
      COMPRESSION="none"
      tarball="$workdir/${PROFILE_NAME}-${DATESTAMP}.tar"
      compression_cmd=""
      ;;
    *)
      abort "Unsupported compression '$COMPRESSION' for $PROFILE_NAME (use gzip|zstd|none)."
      ;;
  esac

  local profile_stage="$workdir/${PROFILE_NAME}"
  mkdir -p "$profile_stage"/{duply,includes}
  chmod 700 "$profile_stage"

  duply_basename="$(basename "$DUPLY_DIR")"
  mkdir -p "$profile_stage/duply/$duply_basename"
  echo "[$PROFILE_NAME] Collecting duply profile from $DUPLY_DIR as $PROFILE_USER"
  if ! run_as_user "$PROFILE_USER" test -r "$DUPLY_DIR"; then
    abort "User $PROFILE_USER cannot read $DUPLY_DIR"
  fi
  if ! rsync -a --acls --xattrs --owner --group "$DUPLY_DIR"/ "$profile_stage/duply/$duply_basename/"; then
    abort "Failed to copy duply dir for $PROFILE_NAME"
  fi

  for include in "${INCLUDE_PATHS[@]}"; do
    [[ -e "$include" ]] || { echo "[$PROFILE_NAME] Skipping missing include: $include" >&2; continue; }
    include_stage="$profile_stage/includes/$(basename "$include")"
    include_owner="$(stat -c '%U' "$include" 2>/dev/null || echo "$PROFILE_USER")"
    echo "[$PROFILE_NAME] Collecting include $include as $include_owner"
    mkdir -p "$(dirname "$include_stage")"
    if [[ -d "$include" ]]; then
      if ! rsync -a --acls --xattrs --owner --group "$include"/ "$include_stage/"; then
        abort "Failed to copy include dir '$include'"
      fi
    else
      if ! rsync -a --acls --xattrs --owner --group "$include" "$include_stage"; then
        abort "Failed to copy include file '$include'"
      fi
    fi
  done

  cat >"$profile_stage/manifest.yaml" <<EOF
profile: "$PROFILE_NAME"
user: "$PROFILE_USER"
duply_dir: "$DUPLY_DIR"
includes:
$(for include in "${INCLUDE_PATHS[@]}"; do printf "  - \"%s\"\n" "$include"; done)
rsync_target: "$RSYNC_TARGET"
cron_reference: "${CRON_REFERENCE:-}"
notes: "${PROFILE_NOTES:-}"
host: "$HOST_ID"
duply_version: "$(duply --version 2>/dev/null | head -n1 || echo "unknown")"
duplicity_version: "$(duplicity --version 2>/dev/null | head -n1 || echo "unknown")"
created_at: "$DATESTAMP"
compression: "$COMPRESSION"
EOF

  bundle="$tarball.gpg"
  checksum="${bundle}.sha256"

  echo "[$PROFILE_NAME] Creating archive"
  if [[ -n "$compression_cmd" ]]; then
    if ! tar -C "$workdir" --numeric-owner --acls --xattrs -c "./${PROFILE_NAME}" | eval "$compression_cmd" >"$tarball"; then
      abort "Tar/compression step failed for $PROFILE_NAME"
    fi
  else
    if ! tar -C "$workdir" --numeric-owner --acls --xattrs -cf "$tarball" "./${PROFILE_NAME}"; then
      abort "Tar step failed for $PROFILE_NAME"
    fi
  fi

  echo "[$PROFILE_NAME] Encrypting archive"
  passfile="$(mktemp "$workdir/passphrase-XXXXXX")"
  chmod 600 "$passfile"
  fetch_passphrase "$PASSPHRASE_SECRET" "$PASSPHRASE_FILE" >"$passfile"
  if ! gpg --batch --yes --pinentry-mode loopback --passphrase-file "$passfile" \
    --symmetric --cipher-algo AES256 \
    --output "$bundle" "$tarball" 2>"$workdir/gpg.err"; then
    send_webhook "down" "GPG encryption failed for $PROFILE_NAME"
    cat "$workdir/gpg.err" >&2 || true
    rm -f "$passfile"
    abort "GPG encryption failed for $PROFILE_NAME"
  fi
  rm -f "$passfile" "$workdir/gpg.err"
  if command -v shred >/dev/null 2>&1; then
    shred -u "$tarball"
  else
    rm -f "$tarball"
  fi

  if ! (
    cd "$(dirname "$bundle")"
    sha256sum "$(basename "$bundle")" >"$(basename "$checksum")"
  ); then
    abort "Checksum generation failed for $PROFILE_NAME"
  fi

  echo "[$PROFILE_NAME] Pushing to $RSYNC_TARGET"
  if ! rsync $RSYNC_FLAGS "$bundle" "$checksum" "${RSYNC_TARGET%/}/"; then
    abort "rsync failed for $PROFILE_NAME"
  fi

  send_webhook "up" "$PROFILE_NAME config bundle uploaded"
  echo "[$PROFILE_NAME] Completed"

  rm -rf "$workdir"
}

main() {
  [[ $EUID -eq 0 ]] || abort "Run this script as root to preserve file ownership."
  mkdir -p "$TMP_PARENT"
  mkdir -p "$(dirname "$LOCK_FILE")"

  require_command gpg
  require_command tar
  require_command rsync
  require_command sha256sum
  if [[ -n "$UPTIME_KUMA_WEBHOOK" ]]; then
    require_command curl
  fi
  if ! command -v runuser >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
    abort "Need either runuser or sudo installed to impersonate profile owners."
  fi
  [[ -n "$OP_CLI" ]] || echo "INFO: op CLI not found; profiles must use PASSPHRASE_FILE."

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    abort "Another backup-configs instance is running (lock $LOCK_FILE)."
  fi

  shopt -s nullglob
  local profile_file
  local processed=0
  for profile_file in "$CONFIG_PROFILES_DIR"/*.conf; do
    processed=1
    process_profile "$profile_file"
  done
  shopt -u nullglob
  if [[ $processed -eq 0 ]]; then
    echo "No profile configs found in $CONFIG_PROFILES_DIR."
  fi
}

main "$@"
