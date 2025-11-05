#!/usr/bin/env bash
set -uo pipefail

# Reverts changes introduced by setup_github_account.sh using its manifest.

usage() {
  cat <<EOF
Usage: $(basename "$0") --alias <alias> [options]
       $(basename "$0") --manifest <path> [options]

Options:
  --alias <alias>     Alias used during setup (case-insensitive, e.g., github.com-username)
  --manifest <path>   Path to a manifest file produced by the setup script
  --dry-run           Show what would be removed without touching the system
  -y, --yes           Skip interactive confirmations (DANGEROUS)
  -h, --help          Show this help

Note: Alias is case-insensitive (github.com-MyUser and github.com-myuser are equivalent)
EOF
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

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ask_confirm() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local reply
  while true; do
    read -rp "$prompt " reply </dev/tty
    reply="${reply:-$default_answer}"
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) log_warn "Please answer y or n." ;;
    esac
  done
}

remove_block_from_file() {
  local file="$1"
  local block_b64="$2"
  local namespace="${3:-}"
  local alias="${4:-}"
  
  if [[ -z "$block_b64" ]]; then
    log_info "No recorded block for $file; skipping"
    return
  fi
  if [[ ! -f "$file" ]]; then
    log_info "$file not found; skipping block removal"
    return
  fi
  local outcome
  outcome="$(python3 - "$file" "$block_b64" <<'PY' 2>/dev/null
import base64, sys, pathlib
path = pathlib.Path(sys.argv[1])
block = base64.b64decode(sys.argv[2].encode()).decode()
text = path.read_text(encoding="utf-8")
if block in text:
    path.write_text(text.replace(block, "", 1), encoding="utf-8")
    print("removed")
else:
    print("missing")
PY
)"
  
  # If block not found with exact match, try to find and remove by markers
  if [[ -n "$namespace" && -n "$alias" && "$outcome" != "removed" ]]; then
    outcome="$(python3 - "$file" "$namespace" "$alias" <<'PY' 2>/dev/null || echo "missing"
import sys, pathlib
path = pathlib.Path(sys.argv[1])
namespace, alias = sys.argv[2], sys.argv[3]
content = path.read_text(encoding="utf-8")

begin = f"# {namespace} {alias} begin\n"
end = f"# {namespace} {alias} end\n"
start = content.find(begin)
if start != -1:
    end_pos = content.find(end, start)
    if end_pos != -1:
        end_pos += len(end)
        content = content[:start] + content[end_pos:]
        path.write_text(content, encoding="utf-8")
        print("removed")
        sys.exit(0)
print("missing")
PY
)"
  fi
  
  if [[ "$outcome" == "removed" ]]; then
    log_info "Removed managed block from $file"
  else
    log_info "Managed block already absent in $file"
  fi
}

delete_file_if_exists() {
  local path="$1"
  local description="$2"
  if [[ ! -e "$path" ]]; then
    log_info "$description already absent ($path)"
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[dry-run] Would remove $description at $path"
    return
  fi
  if [[ "$AUTO_YES" -ne 1 ]]; then
    if ! ask_confirm "Remove $description at $path? [y/N]" "N"; then
      log_warn "Skipped removing $description"
      return
    fi
  fi
  if rm -f "$path"; then
    log_info "Removed $description ($path)"
  else
    log_warn "Failed to remove $description ($path)"
  fi
}

lookup_gh_ssh_key_id() {
  local title="$1"
  gh ssh-key list --limit 200 --json id,title 2>/dev/null | python3 - "$title" <<'PY'
import json, sys
title = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data:
    if item.get("title") == title:
        print(item.get("id", ""))
        break
PY
}

lookup_gh_gpg_key_id() {
  local fingerprint="$1"
  gh gpg-key list --limit 200 --json id,fingerprint 2>/dev/null | python3 - "$fingerprint" <<'PY'
import json, sys
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data:
    if item.get("fingerprint") == target:
        print(item.get("id", ""))
        break
PY
}

ALIAS=""
MANIFEST_PATH=""
DRY_RUN=0
AUTO_YES=0
NAMESPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias)
      [[ $# -lt 2 ]] && { log_error "--alias requires a value"; exit 1; }
      ALIAS="$2"
      shift 2
      ;;
    --manifest)
      [[ $# -lt 2 ]] && { log_error "--manifest requires a path"; exit 1; }
      MANIFEST_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -y|--yes)
      AUTO_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$MANIFEST_PATH" ]]; then
  if [[ -z "$ALIAS" ]]; then
    log_error "Provide --alias or --manifest"
    usage
    exit 1
  fi
  
  # Normalize alias to lowercase (GitHub usernames are case-insensitive)
  ALIAS="$(tr '[:upper:]' '[:lower:]' <<<"$ALIAS")"
  
  # Determine namespace from alias: fixed prefix 'github-'
  USERNAME="${ALIAS#github.com-}"
  USERNAME="${USERNAME#*.com-}"
  USERNAME="$(tr '[:upper:]' '[:lower:]' <<<"$USERNAME")"
  
  NAMESPACE="github-${USERNAME}"
  STATE_DIR="$HOME/.config/${NAMESPACE}"
  MANIFEST_PATH="$STATE_DIR/${ALIAS}.json"
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
  log_error "Manifest not found at $MANIFEST_PATH"
  exit 1
fi

if ! have_cmd python3; then
  log_error "python3 is required for cleanup"
  exit 1
fi

eval "$(
  python3 - "$MANIFEST_PATH" <<'PY'
import base64, json, shlex, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

def emit(key, value):
    if isinstance(value, bool):
        value = "1" if value else "0"
    elif value is None:
        value = ""
    else:
        value = str(value)
    print(f"{key}={shlex.quote(value)}")

def emit_b64(key, value):
    if value:
        encoded = base64.b64encode(value.encode()).decode()
    else:
        encoded = ""
    emit(key, encoded)

emit("MANIFEST_VERSION", data.get("version", 1))
emit("MANIFEST_NAMESPACE", data.get("namespace", ""))
emit("MANIFEST_ALIAS", data.get("alias", ""))
emit("MANIFEST_WORKSPACE", data.get("workspace", ""))
emit("MANIFEST_GH_USER", data.get("gh_user", ""))
emit("MANIFEST_GH_EMAIL", data.get("gh_email", ""))

ssh = data.get("ssh", {})
emit("MANIFEST_SSH_KEY_PATH", ssh.get("key_path", ""))
emit("MANIFEST_SSH_PUBLIC_KEY_PATH", ssh.get("public_key_path", ""))
emit("MANIFEST_SSH_CONFIG_PATH", ssh.get("config_path", ""))
emit_b64("MANIFEST_SSH_CONFIG_BLOCK_B64", ssh.get("config_block", ""))
emit("MANIFEST_SSH_KEY_REUSED", ssh.get("key_reused", False))
emit("MANIFEST_SSH_UPLOADED", ssh.get("uploaded", False))
emit("MANIFEST_SSH_GH_TITLE", ssh.get("github_title", ""))
emit("MANIFEST_SSH_GH_ID", ssh.get("github_id", ""))

git = data.get("git", {})
emit("MANIFEST_GIT_CONFIG_PATH", git.get("config_path", ""))
emit_b64("MANIFEST_GIT_INCLUDE_BLOCK_B64", git.get("include_block", ""))
emit("MANIFEST_ALIAS_GITCONFIG", git.get("alias_config_path", ""))

gpg = data.get("gpg", {})
emit("MANIFEST_GPG_ENABLED", gpg.get("enabled", False))
emit("MANIFEST_GPG_CREATED", gpg.get("created", False))
emit("MANIFEST_GPG_REUSED", gpg.get("reused", False))
emit("MANIFEST_GPG_FINGERPRINT", gpg.get("fingerprint", ""))
emit("MANIFEST_GPG_COMMENT", gpg.get("comment", ""))
emit("MANIFEST_GPG_GH_TITLE", gpg.get("github_title", ""))
emit("MANIFEST_GPG_GH_ID", gpg.get("github_id", ""))

gh = data.get("gh", {})
emit("MANIFEST_GH_AUTH_LOGIN_PERFORMED", gh.get("auth_login_performed", False))
emit("MANIFEST_GH_AUTH_SWITCHED", gh.get("auth_switched", False))
PY
)"

ALIAS="${ALIAS:-$MANIFEST_ALIAS}"

if [[ -z "$ALIAS" ]]; then
  log_error "Alias missing in manifest."
  exit 1
fi

# Read namespace from manifest if not set from path
if [[ -z "$NAMESPACE" ]]; then
  NAMESPACE="$MANIFEST_NAMESPACE"
fi

if [[ -z "$NAMESPACE" ]]; then
  log_error "Namespace missing in manifest."
  exit 1
fi

declare -a ACTIONS=()

if [[ -n "$MANIFEST_ALIAS_GITCONFIG" && -f "$MANIFEST_ALIAS_GITCONFIG" ]]; then
  ACTIONS+=("Remove per-alias gitconfig $MANIFEST_ALIAS_GITCONFIG")
fi

if [[ -n "$MANIFEST_GIT_CONFIG_PATH" && -f "$MANIFEST_GIT_CONFIG_PATH" ]]; then
  ACTIONS+=("Remove includeIf block from $MANIFEST_GIT_CONFIG_PATH")
fi

if [[ -n "$MANIFEST_SSH_CONFIG_PATH" && -f "$MANIFEST_SSH_CONFIG_PATH" ]]; then
  ACTIONS+=("Remove SSH alias block from $MANIFEST_SSH_CONFIG_PATH")
fi

if [[ -n "$MANIFEST_SSH_KEY_PATH" && -f "$MANIFEST_SSH_KEY_PATH" ]]; then
  ACTIONS+=("Remove SSH private key $MANIFEST_SSH_KEY_PATH")
fi

if [[ -n "$MANIFEST_SSH_PUBLIC_KEY_PATH" && -f "$MANIFEST_SSH_PUBLIC_KEY_PATH" ]]; then
  ACTIONS+=("Remove SSH public key $MANIFEST_SSH_PUBLIC_KEY_PATH")
fi

if [[ "${MANIFEST_GPG_ENABLED:-0}" == "1" ]]; then
  ACTIONS+=("Remove generated GPG key ${MANIFEST_GPG_FINGERPRINT}")
fi

if [[ "${MANIFEST_SSH_UPLOADED:-0}" == "1" ]]; then
  ACTIONS+=("Remove uploaded SSH key '${MANIFEST_SSH_GH_TITLE}' from GitHub")
fi

if [[ "${MANIFEST_GPG_ENABLED:-0}" == "1" && ( -n "$MANIFEST_GPG_GH_ID" || -n "$MANIFEST_GPG_FINGERPRINT" ) ]]; then
  ACTIONS+=("Remove uploaded GPG key '${MANIFEST_GPG_GH_TITLE}' from GitHub")
fi

ACTIONS+=("Remove manifest $MANIFEST_PATH")

if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
  log_info "Nothing to clean. Exiting."
  exit 0
fi

log_info "Planned cleanup actions:"
for action in "${ACTIONS[@]}"; do
  printf "  - %s\n" "$action"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "Dry run complete."
  exit 0
fi

if [[ "$AUTO_YES" -ne 1 ]]; then
  if ! ask_confirm "Proceed with cleanup? [y/N]" "N"; then
    log_warn "Cleanup aborted by user."
    exit 0
  fi
fi

# Remove alias gitconfig file
if [[ -n "$MANIFEST_ALIAS_GITCONFIG" && -f "$MANIFEST_ALIAS_GITCONFIG" ]]; then
  if grep -Fq "# $NAMESPACE $ALIAS" "$MANIFEST_ALIAS_GITCONFIG"; then
    delete_file_if_exists "$MANIFEST_ALIAS_GITCONFIG" "per-alias gitconfig"
  else
    log_warn "$MANIFEST_ALIAS_GITCONFIG does not contain expected marker; skipped"
  fi
else
  log_info "Per-alias gitconfig already absent."
fi

# Remove include block
if [[ -n "$MANIFEST_GIT_INCLUDE_BLOCK_B64" ]]; then
  remove_block_from_file "$MANIFEST_GIT_CONFIG_PATH" "$MANIFEST_GIT_INCLUDE_BLOCK_B64" "$NAMESPACE" "$ALIAS"
fi

# Remove SSH alias block
if [[ -n "$MANIFEST_SSH_CONFIG_BLOCK_B64" ]]; then
  remove_block_from_file "$MANIFEST_SSH_CONFIG_PATH" "$MANIFEST_SSH_CONFIG_BLOCK_B64" "$NAMESPACE" "$ALIAS"
fi

# Delete SSH keys
if [[ -n "$MANIFEST_SSH_KEY_PATH" ]]; then
  delete_file_if_exists "$MANIFEST_SSH_KEY_PATH" "SSH private key"
fi
if [[ -n "$MANIFEST_SSH_PUBLIC_KEY_PATH" ]]; then
  delete_file_if_exists "$MANIFEST_SSH_PUBLIC_KEY_PATH" "SSH public key"
fi

# Delete GPG key
if [[ "${MANIFEST_GPG_ENABLED:-0}" == "1" ]]; then
  if ! have_cmd gpg; then
    log_warn "gpg not available; cannot delete generated GPG key."
  elif [[ -z "$MANIFEST_GPG_FINGERPRINT" ]]; then
    log_warn "GPG fingerprint missing; skipping deletion."
  else
    GPG_INFO="$(gpg --list-secret-keys --with-colons "$MANIFEST_GPG_FINGERPRINT" 2>/dev/null || true)"
    if [[ -z "$GPG_INFO" ]]; then
      log_info "GPG key $MANIFEST_GPG_FINGERPRINT already absent."
    elif [[ -n "$MANIFEST_GPG_COMMENT" ]] && ! grep -Fq "$MANIFEST_GPG_COMMENT" <<<"$GPG_INFO"; then
      log_warn "GPG key $MANIFEST_GPG_FINGERPRINT does not contain expected comment; skipped."
    else
      DELETE_SUCCESS=1
      gpg --batch --yes --delete-secret-key "$MANIFEST_GPG_FINGERPRINT" >/dev/null 2>&1 || { log_warn "Failed to delete secret GPG key."; DELETE_SUCCESS=0; }
      gpg --batch --yes --delete-key "$MANIFEST_GPG_FINGERPRINT" >/dev/null 2>&1 || { log_warn "Failed to delete public GPG key."; DELETE_SUCCESS=0; }
      if [[ "$DELETE_SUCCESS" -eq 1 ]]; then
        log_info "Removed GPG key $MANIFEST_GPG_FINGERPRINT"
      fi
    fi
  fi
fi

# Delete SSH key in GitHub if possible
if [[ "${MANIFEST_SSH_UPLOADED:-0}" == "1" ]]; then
  if ! have_cmd gh; then
    log_warn "gh CLI not available; cannot delete uploaded SSH key."
  elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log_warn "gh is not authenticated; skip deleting remote SSH key."
  else
    SSH_KEY_ID="$MANIFEST_SSH_GH_ID"
    if [[ -z "$SSH_KEY_ID" && -n "$MANIFEST_SSH_GH_TITLE" ]]; then
      SSH_KEY_ID="$(lookup_gh_ssh_key_id "$MANIFEST_SSH_GH_TITLE")"
    fi
    if [[ -n "$SSH_KEY_ID" ]]; then
      if gh ssh-key delete "$SSH_KEY_ID" --yes >/dev/null 2>&1; then
        log_info "Removed SSH key '$MANIFEST_SSH_GH_TITLE' from GitHub"
      else
        log_warn "Failed to delete SSH key '$MANIFEST_SSH_GH_TITLE' from GitHub."
      fi
    else
      log_warn "SSH key id not found; cannot delete from GitHub."
    fi
  fi
fi

# Delete GPG key in GitHub
if [[ "${MANIFEST_GPG_ENABLED:-0}" == "1" && -n "$MANIFEST_GPG_FINGERPRINT" ]]; then
  if ! have_cmd gh; then
    log_warn "gh CLI not available; cannot delete uploaded GPG key."
  elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log_warn "gh is not authenticated; skip deleting remote GPG key."
  else
    GPG_KEY_ID="$MANIFEST_GPG_GH_ID"
    if [[ -z "$GPG_KEY_ID" ]]; then
      GPG_KEY_ID="$(lookup_gh_gpg_key_id "$MANIFEST_GPG_FINGERPRINT")"
    fi
    if [[ -n "$GPG_KEY_ID" ]]; then
      if gh api -X DELETE "/user/gpg_keys/$GPG_KEY_ID" >/dev/null 2>&1; then
        log_info "Removed GPG key '$MANIFEST_GPG_FINGERPRINT' from GitHub"
      else
        log_warn "Failed to delete GPG key '$MANIFEST_GPG_FINGERPRINT' from GitHub."
      fi
    else
      log_warn "GPG key id not found; cannot delete from GitHub."
    fi
  fi
fi

# Remove manifest last
delete_file_if_exists "$MANIFEST_PATH" "manifest"

# Offer gh auth logout if we previously switched
if [[ "${MANIFEST_GH_AUTH_SWITCHED:-0}" == "1" && -n "$MANIFEST_GH_USER" ]]; then
  if have_cmd gh && gh auth status --hostname github.com >/dev/null 2>&1; then
    DO_LOGOUT=0
    if [[ "$AUTO_YES" -eq 1 ]]; then
      DO_LOGOUT=1
    elif ask_confirm "Log out gh user ${MANIFEST_GH_USER}? [y/N]" "N"; then
      DO_LOGOUT=1
    fi
    if [[ "$DO_LOGOUT" -eq 1 ]]; then
      if gh auth logout --hostname github.com --user "$MANIFEST_GH_USER" >/dev/null 2>&1; then
        log_info "Logged out gh user ${MANIFEST_GH_USER}"
      else
        log_warn "Failed to log out gh user ${MANIFEST_GH_USER}."
      fi
    fi
  fi
fi

log_info "Cleanup complete."
