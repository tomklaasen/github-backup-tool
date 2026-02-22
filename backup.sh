#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    echo "Create it from backup.conf.example" >&2
    exit 1
fi
source "$CONFIG_FILE"

# Defaults
BACKUP_DIR="${BACKUP_DIR:-/mnt/usb/GithubBackup}"
CLONE_PROTOCOL="${CLONE_PROTOCOL:-https}"
LOG_FILE="${LOG_FILE:-}"
LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-10240}"
LOG_KEEP="${LOG_KEEP:-5}"
HC_PING_URL="${HC_PING_URL:-}"

if [[ "$CLONE_PROTOCOL" != "https" && "$CLONE_PROTOCOL" != "ssh" ]]; then
    echo "ERROR: CLONE_PROTOCOL must be 'https' or 'ssh', got '$CLONE_PROTOCOL'" >&2
    exit 1
fi

# --- Logging ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

hc_ping() {
    if [[ -n "$HC_PING_URL" ]]; then
        local suffix="${1:-}"
        local body="${2:-}"
        local url="$HC_PING_URL"
        [[ -n "$suffix" ]] && url="$url/$suffix"
        if [[ -n "$body" ]]; then
            curl -fsS --max-time 10 --retry 3 --data-raw "$body" "$url" > /dev/null 2>&1 || true
        else
            curl -fsS --max-time 10 --retry 3 "$url" > /dev/null 2>&1 || true
        fi
    fi
}

# --- Log rotation ---
rotate_logs() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return

    local size_kb
    size_kb=$(du -k "$log_file" | cut -f1)

    if (( size_kb >= LOG_MAX_SIZE_KB )); then
        [[ -f "$log_file.$LOG_KEEP" ]] && rm -f "$log_file.$LOG_KEEP"
        for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
            [[ -f "$log_file.$i" ]] && mv "$log_file.$i" "$log_file.$((i + 1))"
        done
        mv "$log_file" "$log_file.1"
    fi
}

# Set up file logging if LOG_FILE is configured
if [[ -n "$LOG_FILE" ]]; then
    rotate_logs "$LOG_FILE"
    exec >> "$LOG_FILE" 2>&1
fi

# --- Verify prerequisites ---
if ! command -v gh &>/dev/null; then
    log "ERROR: gh CLI is not installed. Install it with: sudo apt install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    log "ERROR: gh CLI is not authenticated. Run: gh auth login"
    exit 1
fi

if ! command -v git &>/dev/null; then
    log "ERROR: git is not installed."
    exit 1
fi

if [[ -n "$HC_PING_URL" ]] && ! command -v curl &>/dev/null; then
    log "ERROR: curl is not installed (required for HC_PING_URL)."
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- Collect all repos ---
log "Fetching repository list..."

repos=()

# Personal repos
while IFS= read -r repo; do
    repos+=("$repo")
done < <(gh repo list --limit 4000 --json nameWithOwner --jq '.[].nameWithOwner')

log "Found ${#repos[@]} personal repos."

# Org repos
orgs=()
while IFS= read -r org; do
    [[ -z "$org" ]] && continue
    orgs+=("$org")
done < <(gh api /user/orgs --jq '.[].login' 2>/dev/null || true)

for org in "${orgs[@]}"; do
    count_before=${#repos[@]}
    while IFS= read -r repo; do
        repos+=("$repo")
    done < <(gh repo list "$org" --limit 4000 --json nameWithOwner --jq '.[].nameWithOwner')
    log "Found $(( ${#repos[@]} - count_before )) repos in org '$org'."
done

# Deduplicate
mapfile -t repos < <(printf '%s\n' "${repos[@]}" | sort -u)

log "Total unique repos: ${#repos[@]}"
echo

hc_ping start

# --- Backup each repo ---
cloned=0
updated=0
failed=0
failed_repos=()

for full_name in "${repos[@]}"; do
    target="$BACKUP_DIR/$full_name"

    if [[ "$CLONE_PROTOCOL" == "ssh" ]]; then
        clone_url="git@github.com:$full_name.git"
    else
        clone_url="https://github.com/$full_name.git"
    fi

    if [[ -d "$target" ]]; then
        log "Updating $full_name ..."
        if git -C "$target" remote update --prune 2>&1; then
            updated=$((updated + 1))
        else
            log "  FAILED to update $full_name"
            failed=$((failed + 1))
            failed_repos+=("$full_name")
        fi
    else
        log "Cloning $full_name ..."
        if git clone --mirror "$clone_url" "$target" --quiet 2>&1; then
            cloned=$((cloned + 1))
        else
            log "  FAILED to clone $full_name"
            failed=$((failed + 1))
            failed_repos+=("$full_name")
        fi
    fi
done

# --- Summary ---
echo
log "===== Backup complete ====="
log "Cloned:  $cloned new"
log "Updated: $updated existing"
log "Failed:  $failed"
summary="Cloned: $cloned new, Updated: $updated existing, Failed: $failed"
if [[ ${#failed_repos[@]} -gt 0 ]]; then
    log "Failed repos:"
    for r in "${failed_repos[@]}"; do
        log "  - $r"
        summary+=$'\n'"  - $r"
    done
    hc_ping fail "$summary"
else
    hc_ping "" "$summary"
fi
