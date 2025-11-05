#!/usr/bin/env bash
set -euo pipefail
trap 'log_error "Setup failed at line $LINENO"; exit 1' ERR

# Automates setup of multiple GitHub accounts with workspace-specific configuration.
#  - Generates (or reuses) a dedicated SSH key and configures ~/.ssh/config with a host alias
#  - Sets up an includeIf block in ~/.gitconfig pointing at ~/.gitconfig-<alias>
#  - Optionally generates a GPG key for commit signing and uploads SSH/GPG keys via GitHub CLI
#  - Records every change in a manifest so it can be reverted with cleanup_github_account.sh
#
# Environment variables:
#  GH_ACCOUNTS_AUTO_INSTALL - Auto-install missing packages: 1=yes (default), 0=no
#  SKIP_SSH_ADD             - Skip ssh-add step: 1=yes, 0=no (default)

# Auto-install configuration
AUTO_INSTALL="${GH_ACCOUNTS_AUTO_INSTALL:-1}"

detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/redhat-release ]]; then
    echo "redhat"
  elif [[ -f /etc/arch-release ]]; then
    echo "arch"
  else
    echo "unknown"
  fi
}

install_package() {
  local package="$1"
  local os_type="$(detect_os)"
  
  log_warn "Package '$package' not found. Attempting to install..."
  
  case "$os_type" in
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        log_error "Homebrew not found. Please install from https://brew.sh"
        return 1
      fi
      log_info "Installing via Homebrew: brew install $package"
      brew install "$package" </dev/null
      ;;
    debian)
      log_info "Installing via apt: sudo apt-get install -y $package"
      sudo apt-get update -qq && sudo apt-get install -y "$package" </dev/null
      ;;
    redhat)
      log_info "Installing via yum: sudo yum install -y $package"
      sudo yum install -y "$package" </dev/null
      ;;
    arch)
      log_info "Installing via pacman: sudo pacman -S --noconfirm $package"
      sudo pacman -S --noconfirm "$package" </dev/null
      ;;
    *)
      log_error "Unknown OS. Please install '$package' manually"
      return 1
      ;;
  esac
}

require_cmd() {
  local cmd="$1"
  local package="${2:-$1}"
  
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ "$AUTO_INSTALL" == "1" ]]; then
      log_warn "Command '$cmd' not found in PATH"
      if prompt_yes_no "Install $package automatically? [Y/n]: " "Y"; then
        if install_package "$package"; then
          log_info "Successfully installed $package"
          
          # Refresh PATH for macOS Homebrew
          if [[ "$(detect_os)" == "macos" ]]; then
            if [[ -f "/opt/homebrew/bin/$cmd" ]]; then
              export PATH="/opt/homebrew/bin:$PATH"
            elif [[ -f "/usr/local/bin/$cmd" ]]; then
              export PATH="/usr/local/bin:$PATH"
            fi
          fi
          
          # Verify installation with retry
          local retries=3
          local found=0
          for ((i=1; i<=retries; i++)); do
            if command -v "$cmd" >/dev/null 2>&1; then
              found=1
              break
            fi
            sleep 1
          done
          
          if [[ $found -eq 0 ]]; then
            log_error "Installation succeeded but '$cmd' still not found. Try restarting terminal."
            exit 1
          fi
        else
          log_error "Failed to install $package"
          exit 1
        fi
      else
        log_error "Required command '$cmd' not found in PATH"
        exit 1
      fi
    else
      echo "Error: required command '$cmd' not found in PATH" >&2
      exit 1
    fi
  fi
}

log_info() {
  printf "[INFO] %s\n" "$*"
}

log_warn() {
  printf "[WARN] %s\n" "$*" >&2
}

log_error() {
  printf "[ERROR] %s\n" "$*" >&2
}

ensure_file() {
  local path="$1"
  local mode="$2"
  if [[ ! -f "$path" ]]; then
    mkdir -p "$(dirname "$path")"
    touch "$path"
    chmod "$mode" "$path"
  fi
}

append_if_missing() {
  local file="$1"
  local marker="$2"
  local content="$3"
  if ! grep -Fq "$marker" "$file"; then
    printf "\n%s\n" "$content" >>"$file"
  fi
}

lowercase() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

prompt_required() {
  local var_name="$1"
  local prompt="$2"
  local value
  while true; do
    read -rp "$prompt" value </dev/tty
    if [[ -n "$value" ]]; then
      printf -v "$var_name" "%s" "$value"
      break
    fi
    echo "Value is required." >&2
  done
}

prompt_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value
  read -rp "$prompt" value </dev/tty
  value="${value:-$default_value}"
  printf -v "$var_name" "%s" "$value"
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-Y}"
  local reply
  while true; do
    read -rp "$prompt" reply </dev/tty
    reply="${reply:-$default_answer}"
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "Please answer y or n." >&2 ;;
    esac
  done
}

ensure_gh_scopes() {
  local scopes=("$@")
  if [[ "${#scopes[@]}" -eq 0 ]]; then
    return 0
  fi

  local status_output missing refresh_args
  status_output="$(gh auth status --hostname github.com --show-token 2>/dev/null || true)"
  if [[ -z "$status_output" ]]; then
    log_warn "Unable to read GitHub auth status; continuing without verifying scopes."
    return 1
  fi

  missing="$(STATUS_OUTPUT="$status_output" python3 - "${scopes[@]}" <<'PY'
import os
import re
import sys

scopes = [scope.lower() for scope in sys.argv[1:]]
status = os.environ.get("STATUS_OUTPUT", "")
available = set()
for line in status.splitlines():
    lower = line.lower()
    if "token scopes:" in lower:
        tail = lower.split("token scopes:", 1)[1]
        available = {
            part.strip("'\"").lower()
            for part in re.split(r"[\s,]+", tail)
            if part.strip()
        }
        break

aliases = {
    "admin:public_key": {"admin:public_key", "write:public_key"},
    "write:public_key": {"write:public_key"},
    "write:gpg_key": {"write:gpg_key", "admin:gpg_key"},
    "read:gpg_key": {"read:gpg_key", "write:gpg_key", "admin:gpg_key"},
}

missing = []
for scope in scopes:
    allowed = aliases.get(scope, {scope})
    if not available.intersection(allowed):
        missing.append(scope)

print(" ".join(missing), end="")
PY
)"

  if [[ -z "$missing" ]]; then
    return 0
  fi

  refresh_args=()
  for scope in "${scopes[@]}"; do
    refresh_args+=("-s" "$scope")
  done

  log_warn "GitHub token missing required scopes: $missing"
  log_warn "Run: gh auth refresh -h github.com ${refresh_args[*]}"
  return 1
}

abort_if_unmanaged_block_exists() {
  local file="$1"
  local pattern="$2"
  local namespace="$3"
  local alias="$4"
  local marker="${namespace} ${alias} begin"
  
  if grep -Fq "$pattern" "$file"; then
    if ! grep -Fq "$marker" "$file"; then
      echo "Error: found existing entry matching '$pattern' in $file" >&2
      echo "without managed markers for namespace '$namespace'." >&2
      echo "Please backup and remove it manually before proceeding." >&2
      exit 1
    fi
  fi
}

LAST_INSERTED_BLOCK=""

add_marked_block() {
  local file="$1"
  local namespace="$2"
  local alias="$3"
  local comment_char="$4"
  local content="$5"
  local begin_marker end_marker block
  comment_char="${comment_char:-#}"
  begin_marker="${comment_char} ${namespace} ${alias} begin"
  end_marker="${comment_char} ${namespace} ${alias} end"

  if grep -Fq "$begin_marker" "$file"; then
    LAST_INSERTED_BLOCK="$(python3 - "$file" "$begin_marker" "$end_marker" <<'PY' || true
import sys
path, begin, end = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
start = text.find(begin)
if start == -1:
    sys.exit(0)
end_index = text.find(end, start)
if end_index == -1:
    sys.exit(0)
end_index += len(end)
if end_index < len(text) and text[end_index] == "\n":
    end_index += 1
print(text[start:end_index], end="")
PY
)"
    return 0
  fi

  block="${begin_marker}"$'\n'"${content}"$'\n'"${end_marker}"$'\n'
  if [[ -s "$file" ]]; then
    printf "\n%s" "$block" >>"$file"
  else
    printf "%s" "$block" >>"$file"
  fi
  LAST_INSERTED_BLOCK="$block"
  return 0
}

lookup_gh_ssh_key_id() {
  local title="$1"
  local listing
  if ! listing="$(gh api /user/keys 2>/dev/null || true)"; then
    return 0
  fi
  LISTING="$listing" python3 - "$title" <<'PY'
import json, os, sys
data = os.environ.get("LISTING", "")
try:
    items = json.loads(data)
except Exception:
    sys.exit()
title = sys.argv[1]
for item in items:
    if item.get("title") == title:
        print(item.get("id", ""))
        break
PY
}

lookup_gh_gpg_key_id() {
  local fingerprint="$1"
  local listing
  if ! listing="$(gh api /user/gpg_keys 2>/dev/null || true)"; then
    return 0
  fi
  local key_id_suffix="${fingerprint: -16}"
  LISTING="$listing" python3 - "$key_id_suffix" <<'PY'
import json, os, sys
data = os.environ.get("LISTING", "")
try:
    items = json.loads(data)
except Exception:
    sys.exit()
target = sys.argv[1].upper()
for item in items:
    key_id = str(item.get("key_id", "")).upper()
    if key_id == target:
        print(item.get("id", ""))
        break
PY
}

write_manifest() {
  local manifest_path="$1"
  python3 - "$manifest_path" <<'PY'
import json, os, sys

path = sys.argv[1]

def env(name, default=""):
    return os.environ.get(name, default)

def env_bool(name):
    return env(name) == "1"

data = {
    "version": int(env("GH_MANIFEST_VERSION", "1")),
    "namespace": env("GH_NAMESPACE"),
    "alias": env("GH_ALIAS"),
    "workspace": env("GH_WORKSPACE"),
    "gh_user": env("GH_USER"),
    "gh_email": env("GH_EMAIL"),
    "ssh": {
        "key_path": env("GH_SSH_KEY_PATH"),
        "public_key_path": env("GH_SSH_PUBLIC_KEY_PATH"),
        "config_path": env("GH_SSH_CONFIG_PATH"),
        "config_block": env("GH_SSH_CONFIG_BLOCK"),
        "key_reused": env_bool("GH_SSH_KEY_REUSED"),
        "uploaded": env_bool("GH_SSH_KEY_UPLOADED"),
        "github_title": env("GH_SSH_KEY_TITLE"),
        "github_id": env("GH_SSH_KEY_ID"),
    },
    "git": {
        "config_path": env("GH_GIT_CONFIG_PATH"),
        "include_block": env("GH_GIT_INCLUDE_BLOCK"),
        "alias_config_path": env("GH_ALIAS_GITCONFIG"),
    },
    "gpg": {
        "enabled": env_bool("GH_GPG_ENABLED"),
        "created": env_bool("GH_GPG_CREATED"),
        "reused": env_bool("GH_GPG_REUSED"),
        "fingerprint": env("GH_GPG_FINGERPRINT"),
        "comment": env("GH_GPG_COMMENT"),
        "github_title": env("GH_GPG_KEY_TITLE"),
        "github_id": env("GH_GPG_KEY_ID"),
    },
    "gh": {
        "auth_login_performed": env_bool("GH_AUTH_LOGIN_PERFORMED"),
        "auth_switched": env_bool("GH_AUTH_SWITCHED"),
    },
}

with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
os.chmod(path, 0o600)
PY
}

# Check for required commands with auto-install support
require_cmd ssh-keygen openssh
require_cmd ssh-add openssh
require_cmd gh gh
require_cmd python3 python3

TEMP_FILES=()
cleanup_temp() {
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    if [[ -n "$file" && -f "$file" ]]; then
      rm -f "$file"
    fi
  done
}
trap cleanup_temp EXIT

prompt_required GH_USER "Account GitHub username: "
GH_USER_LOWER="$(lowercase "$GH_USER")"

prompt_required GH_EMAIL "Commit email for that account: "

# Namespace: fixed prefix 'github-' to avoid collisions with other tools
NAMESPACE="github-${GH_USER_LOWER}"

DEFAULT_WORKSPACE="$(pwd)"
prompt_default WORKSPACE "Workspace path for this account's projects [$DEFAULT_WORKSPACE]: " "$DEFAULT_WORKSPACE"
WORKSPACE="${WORKSPACE/#\~/$HOME}"

if [[ ! -d "$WORKSPACE" ]]; then
  echo "Error: workspace directory '$WORKSPACE' does not exist" >&2
  exit 1
fi

DEFAULT_ALIAS="github.com-$GH_USER_LOWER"
GH_ALIAS="$DEFAULT_ALIAS"
log_info "Using SSH host alias '$GH_ALIAS'"

DEFAULT_KEY_PATH="$HOME/.ssh/id_ed25519_${GH_ALIAS//[^[:alnum:]_-]/}"
KEY_PATH="$DEFAULT_KEY_PATH"
log_info "Using SSH key path $KEY_PATH"
PUB_KEY_PATH="${KEY_PATH}.pub"

SSH_KEY_REUSED=0
if [[ -f "$KEY_PATH" || -f "$PUB_KEY_PATH" ]]; then
  log_info "Removing existing SSH key at $KEY_PATH"
  rm -f "$KEY_PATH" "$PUB_KEY_PATH"
fi

ssh-keygen -t ed25519 -C "$GH_EMAIL" -f "$KEY_PATH" -N ""

if [[ "${SKIP_SSH_ADD:-0}" == "1" ]]; then
  echo "Skipping ssh-add step (SKIP_SSH_ADD=1)"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  ssh-add --apple-use-keychain "$KEY_PATH"
else
  ssh-add "$KEY_PATH"
fi

SSH_CONFIG="$HOME/.ssh/config"
ensure_file "$SSH_CONFIG" 600

append_if_missing "$SSH_CONFIG" "Host *" $'Host *\n  AddKeysToAgent yes'

abort_if_unmanaged_block_exists "$SSH_CONFIG" "Host $GH_ALIAS" "$NAMESPACE" "$GH_ALIAS"
SSH_ALIAS_BLOCK=$'Host '"$GH_ALIAS"$'\n  HostName github.com\n  User git\n  IdentityFile '"$KEY_PATH"$'\n  IdentitiesOnly yes'
add_marked_block "$SSH_CONFIG" "$NAMESPACE" "$GH_ALIAS" "#" "$SSH_ALIAS_BLOCK"
SSH_CONFIG_BLOCK="$LAST_INSERTED_BLOCK"

GITCONFIG="$HOME/.gitconfig"
ensure_file "$GITCONFIG" 644

include_section="includeIf \"gitdir:${WORKSPACE%/}/**\""
abort_if_unmanaged_block_exists "$GITCONFIG" "path = .gitconfig-$GH_ALIAS" "$NAMESPACE" "$GH_ALIAS"
GIT_INCLUDE_BLOCK_CONTENT=$'['"$include_section"$']\n\tpath = .gitconfig-'"$GH_ALIAS"
add_marked_block "$GITCONFIG" "$NAMESPACE" "$GH_ALIAS" "#" "$GIT_INCLUDE_BLOCK_CONTENT"
GIT_INCLUDE_BLOCK="$LAST_INSERTED_BLOCK"

ALIAS_GITCONFIG="$HOME/.gitconfig-$GH_ALIAS"

# State directory with namespace
STATE_DIR="$HOME/.config/${NAMESPACE}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
MANIFEST_PATH="$STATE_DIR/${GH_ALIAS}.json"

GPG_ENABLED=1
GPG_CREATED=0
GPG_REUSED=0
GPG_FINGERPRINT=""
GPG_COMMENT="${NAMESPACE}-${GH_ALIAS}"

require_cmd gpg gnupg

# Remove prior script-managed keys (identified by comment) to avoid conflicts
existing_fprs=( $({ gpg --list-secret-keys --with-colons "$GH_EMAIL" 2>/dev/null || true; } | python3 - "$GPG_COMMENT" <<'PY'
import sys

target_comment = sys.argv[1]
fingerprints = []
current_fpr = None

for raw_line in sys.stdin:
    line = raw_line.strip()
    if line.startswith("fpr:"):
        parts = line.split(":")
        if len(parts) > 9:
            current_fpr = parts[9]
    elif line.startswith("uid:") and current_fpr:
        parts = line.split(":")
        uid = parts[9] if len(parts) > 9 else ""
        if target_comment and target_comment in uid:
            fingerprints.append(current_fpr)
            current_fpr = None

print(" ".join(fingerprints))
PY
) )
if [[ ${#existing_fprs[@]} -gt 0 ]]; then
  log_info "Removing ${#existing_fprs[@]} existing script-managed GPG key(s) for $GH_EMAIL"
  for fpr in "${existing_fprs[@]}"; do
    gpg --batch --yes --delete-secret-key "$fpr" >/dev/null 2>&1 || true
    gpg --batch --yes --delete-key "$fpr" >/dev/null 2>&1 || true
  done
fi

GPG_BATCH="$(mktemp)"
TEMP_FILES+=("$GPG_BATCH")
{
  echo "Key-Type: eddsa"
  echo "Key-Curve: Ed25519"
  echo "Key-Usage: sign"
  echo "Name-Real: $GH_USER"
  echo "Name-Comment: $GPG_COMMENT"
  echo "Name-Email: $GH_EMAIL"
  echo "Expire-Date: 0"
  echo "%no-protection"
  echo "%commit"
  echo "%echo done"
} >"$GPG_BATCH"

gpg --batch --generate-key "$GPG_BATCH" </dev/null
GPG_CREATED=1

GPG_FINGERPRINT="$({ gpg --list-secret-keys --with-colons "$GH_EMAIL" 2>/dev/null || true; } | python3 - "$GPG_COMMENT" <<'PY'
import sys
comment = sys.argv[1]
last_fpr = None
fingerprint = ""
for line in sys.stdin:
    line = line.strip()
    if line.startswith("fpr:"):
        parts = line.split(":")
        if len(parts) > 9:
            last_fpr = parts[9]
    elif line.startswith("uid:"):
        parts = line.split(":")
        if len(parts) > 9 and comment and comment in parts[9]:
            fingerprint = last_fpr or ""
            break
if fingerprint:
    print(fingerprint)
PY
)"

if [[ -z "$GPG_FINGERPRINT" ]]; then
  GPG_FINGERPRINT="$({ gpg --list-secret-keys --with-colons "$GH_EMAIL" 2>/dev/null || true; } | awk -F: '/^fpr:/ {print $10; exit}')"
fi

if [[ -z "$GPG_FINGERPRINT" ]]; then
  echo "Failed to determine GPG fingerprint." >&2
  exit 1
fi

{
  printf "# %s %s\n" "$NAMESPACE" "$GH_ALIAS"
  printf "[user]\n\tname = %s\n\temail = %s\n" "$GH_USER" "$GH_EMAIL"
  if [[ -n "$GPG_FINGERPRINT" ]]; then
    printf "\tsigningkey = %s\n" "$GPG_FINGERPRINT"
  fi
  printf "\n[url \"git@%s:\"]\n\tinsteadOf = git@github.com:\n" "$GH_ALIAS"
  if [[ -n "$GPG_FINGERPRINT" ]]; then
    printf "\n[commit]\n\tgpgsign = true\n"
    printf "\n[gpg]\n\tprogram = gpg\n"
  fi
} >"$ALIAS_GITCONFIG"
chmod 600 "$ALIAS_GITCONFIG"

read -rp "PAT for $GH_USER (leave blank to skip gh auth): " GH_PAT </dev/tty

GH_AUTH_LOGIN_PERFORMED=0
GH_AUTH_SWITCHED=0
GH_SSH_KEY_TITLE=""
GH_SSH_KEY_ID=""
GH_SSH_KEY_UPLOADED=0
GH_REQUIRED_SCOPE_CMD="gh auth refresh -h github.com -s admin:public_key -s write:gpg_key"
GH_SCOPES_OK=0

if [[ -n "$GH_PAT" ]]; then
  GH_AUTH_LOGIN_PERFORMED=1
  printf '%s\n' "$GH_PAT" | gh auth login --hostname github.com --git-protocol ssh --with-token --skip-ssh-key || {
    echo "[ERROR] gh auth login failed." >&2
    exit 1
  }
  gh auth switch --hostname github.com --user "$GH_USER" || {
    echo "[ERROR] gh auth switch failed." >&2
    exit 1
  }
  GH_AUTH_SWITCHED=1
  if ensure_gh_scopes admin:public_key write:gpg_key; then
    GH_SCOPES_OK=1
  else
    echo "[ERROR] GitHub token missing required scopes (admin:public_key, write:gpg_key)." >&2
    exit 1
  fi
  GH_SSH_KEY_TITLE="$(hostname)-$GH_ALIAS"
  if [[ "$GH_SCOPES_OK" -eq 1 ]]; then
    if SSH_RESPONSE="$(gh api -X POST /user/keys -f title="$GH_SSH_KEY_TITLE" -F key=@"$PUB_KEY_PATH" 2>/dev/null)"; then
      GH_SSH_KEY_UPLOADED=1
      GH_SSH_KEY_ID="$(python3 - <<'PY'
import json,sys
try:
    data=json.load(sys.stdin)
    print(str(data.get("id","")))
except Exception:
    pass
PY
<<<"$SSH_RESPONSE")"
      if [[ -z "$GH_SSH_KEY_ID" ]]; then
        GH_SSH_KEY_ID="$(lookup_gh_ssh_key_id "$GH_SSH_KEY_TITLE")"
      fi
      log_info "SSH key uploaded via gh"
    else
      echo "Warning: failed to upload SSH key via gh api." >&2
      exit 1
    fi
  fi
else
  echo
  echo "PAT not provided. Remember to:"
  PUB_KEY_ABS="$(cd "$(dirname "$PUB_KEY_PATH")" && pwd)/$(basename "$PUB_KEY_PATH")"
  echo "  1. Add $PUB_KEY_ABS to GitHub SSH keys for $GH_USER"
  echo "  2. Run 'gh auth login --hostname github.com --with-token' later if CLI access is needed"
fi

GH_AUTH_STATUS=0
if gh auth status --hostname github.com >/dev/null 2>&1; then
  GH_AUTH_STATUS=1
fi

GH_GPG_KEY_TITLE=""
GH_GPG_KEY_ID=""

if [[ "$GPG_ENABLED" -eq 1 && -n "$GPG_FINGERPRINT" ]]; then
  if [[ "$GH_AUTH_STATUS" -ne 1 ]]; then
    echo "[ERROR] gh CLI is not authenticated; cannot upload GPG key." >&2
    exit 1
  fi
  if [[ "$GH_SCOPES_OK" -ne 1 ]]; then
    echo "[ERROR] GitHub token missing write:gpg_key scope; cannot upload GPG key." >&2
    exit 1
  fi
  GPG_EXPORT="$(mktemp)"
  TEMP_FILES+=("$GPG_EXPORT")
  gpg --armor --export "$GPG_FINGERPRINT" >"$GPG_EXPORT"
  GH_GPG_KEY_TITLE="$(hostname)-$GH_ALIAS"
  if GPG_RESPONSE="$(gh api -X POST /user/gpg_keys -F armored_public_key=@"$GPG_EXPORT" 2>/dev/null)"; then
    GH_GPG_KEY_ID="$(python3 - <<'PY'
import json,sys
try:
    data=json.load(sys.stdin)
    print(str(data.get("id","")))
except Exception:
    pass
PY
<<<"$GPG_RESPONSE")"
    if [[ -z "$GH_GPG_KEY_ID" ]]; then
      GH_GPG_KEY_ID="$(lookup_gh_gpg_key_id "$GPG_FINGERPRINT")"
    fi
    log_info "GPG key uploaded to GitHub."
  else
    echo "Warning: failed to upload GPG key via gh api." >&2
    exit 1
  fi
fi

GH_MANIFEST_VERSION=1
GH_NAMESPACE="$NAMESPACE"
GH_ALIAS="$GH_ALIAS"
GH_WORKSPACE="$WORKSPACE"
GH_USER="$GH_USER"
GH_EMAIL="$GH_EMAIL"
GH_SSH_KEY_PATH="$KEY_PATH"
GH_SSH_PUBLIC_KEY_PATH="$PUB_KEY_PATH"
GH_SSH_CONFIG_PATH="$SSH_CONFIG"
GH_SSH_CONFIG_BLOCK="$SSH_CONFIG_BLOCK"
GH_SSH_KEY_REUSED="$SSH_KEY_REUSED"
GH_SSH_KEY_UPLOADED="$GH_SSH_KEY_UPLOADED"
GH_SSH_KEY_TITLE="$GH_SSH_KEY_TITLE"
GH_SSH_KEY_ID="$GH_SSH_KEY_ID"
GH_GIT_CONFIG_PATH="$GITCONFIG"
GH_GIT_INCLUDE_BLOCK="$GIT_INCLUDE_BLOCK"
GH_ALIAS_GITCONFIG="$ALIAS_GITCONFIG"
GH_GPG_ENABLED="$GPG_ENABLED"
GH_GPG_CREATED="$GPG_CREATED"
GH_GPG_REUSED="$GPG_REUSED"
GH_GPG_FINGERPRINT="$GPG_FINGERPRINT"
GH_GPG_COMMENT="$GPG_COMMENT"
GH_GPG_KEY_TITLE="$GH_GPG_KEY_TITLE"
GH_GPG_KEY_ID="${GH_GPG_KEY_ID:-}"
GH_AUTH_LOGIN_PERFORMED="$GH_AUTH_LOGIN_PERFORMED"
GH_AUTH_SWITCHED="$GH_AUTH_SWITCHED"

export GH_MANIFEST_VERSION
export GH_NAMESPACE
export GH_ALIAS
export GH_WORKSPACE
export GH_USER
export GH_EMAIL
export GH_SSH_KEY_PATH
export GH_SSH_PUBLIC_KEY_PATH
export GH_SSH_CONFIG_PATH
export GH_SSH_CONFIG_BLOCK
export GH_SSH_KEY_REUSED
export GH_SSH_KEY_UPLOADED
export GH_SSH_KEY_TITLE
export GH_SSH_KEY_ID
export GH_GIT_CONFIG_PATH
export GH_GIT_INCLUDE_BLOCK
export GH_ALIAS_GITCONFIG
export GH_GPG_ENABLED
export GH_GPG_CREATED
export GH_GPG_REUSED
export GH_GPG_FINGERPRINT
export GH_GPG_COMMENT
export GH_GPG_KEY_TITLE
export GH_GPG_KEY_ID
export GH_AUTH_LOGIN_PERFORMED
export GH_AUTH_SWITCHED

write_manifest "$MANIFEST_PATH"

log_info "Manifest written to $MANIFEST_PATH"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "[ERROR] Failed to write manifest at $MANIFEST_PATH" >&2
  exit 1
fi

cat <<EOF

Setup complete.
- SSH alias '$GH_ALIAS' points to $KEY_PATH
- Git repositories under '$WORKSPACE' use '$GH_USER <$GH_EMAIL>'
- Per-alias gitconfig stored at $ALIAS_GITCONFIG
- Manifest stored at $MANIFEST_PATH (used by cleanup script)
EOF

if [[ -n "$GPG_FINGERPRINT" ]]; then
  echo "- GPG signing fingerprint: $GPG_FINGERPRINT"
fi

if [[ "$GH_SSH_KEY_UPLOADED" -eq 1 ]]; then
  echo "- SSH key uploaded to GitHub with title '$GH_SSH_KEY_TITLE'"
fi

if [[ -n "${GH_GPG_KEY_ID:-}" ]]; then
  echo "- GPG key uploaded to GitHub with title '$GH_GPG_KEY_TITLE'"
fi

cat <<EOF

To clone via this account:
  git clone git@$GH_ALIAS:ORG/REPO.git
  # or, inside '$WORKSPACE', simply run:
  git clone git@github.com:ORG/REPO.git
  gh repo clone ORG/REPO
  (both commands are rewritten to use the alias inside the workspace)

Cleanup when you're done:
  $(dirname "$0")/cleanup_github_account.sh --alias "$GH_ALIAS"
EOF

log_info "Testing ssh -T git@$GH_ALIAS"
if ssh -T -o StrictHostKeyChecking=accept-new git@"$GH_ALIAS"; then
  :
else
  status=$?
  if [[ $status -eq 1 ]]; then
    echo "(SSH returned exit code 1, which is expected because GitHub closes the session.)"
  else
    echo "SSH test failed with exit code $status" >&2
    exit $status
  fi
fi
