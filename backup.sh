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
EXTRA_TOKENS=("${EXTRA_TOKENS[@]+"${EXTRA_TOKENS[@]}"}")

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

# --- Helpers ---

# Run gh with an optional token override.
# Usage: run_gh "token" [gh args...]
run_gh() {
    local token="$1"; shift
    if [[ -n "$token" ]]; then
        GH_TOKEN="$token" gh "$@"
    else
        gh "$@"
    fi
}

# Run git with an optional token override (sets GH_TOKEN so gh credential helper works).
# Usage: run_git "token" [git args...]
run_git() {
    local token="$1"; shift
    if [[ -n "$token" ]]; then
        GH_TOKEN="$token" git "$@"
    else
        git "$@"
    fi
}

# --- Collect all repos ---
log "Fetching repository list..."

declare -A repo_tokens

# Discover repos for a given account token and add to repo_tokens.
# Repos already in repo_tokens are skipped (first account wins).
# Usage: list_account_repos "token"  (empty string = main gh account)
list_account_repos() {
    local token="$1"
    local label
    if [[ -n "$token" ]]; then
        label="extra account"
    else
        label="main account"
    fi

    local added=0

    # Personal repos
    local personal=()
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        personal+=("$repo")
    done < <(run_gh "$token" repo list --limit 4000 --json nameWithOwner --jq '.[].nameWithOwner')

    for repo in "${personal[@]}"; do
        if [[ -z "${repo_tokens[$repo]+x}" ]]; then
            repo_tokens["$repo"]="$token"
            added=$((added + 1))
        fi
    done
    log "Found ${#personal[@]} personal repos for $label ($added new)."

    # Org repos
    local orgs=()
    while IFS= read -r org; do
        [[ -z "$org" ]] && continue
        orgs+=("$org")
    done < <(run_gh "$token" api /user/orgs --jq '.[].login' 2>/dev/null || true)

    for org in "${orgs[@]}"; do
        local org_repos=()
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            org_repos+=("$repo")
        done < <(run_gh "$token" repo list "$org" --limit 4000 --json nameWithOwner --jq '.[].nameWithOwner')

        local org_added=0
        for repo in "${org_repos[@]}"; do
            if [[ -z "${repo_tokens[$repo]+x}" ]]; then
                repo_tokens["$repo"]="$token"
                org_added=$((org_added + 1))
            fi
        done
        log "Found ${#org_repos[@]} repos in org '$org' for $label ($org_added new)."
    done
}

# Main account first (gets priority for shared repos)
list_account_repos ""

# Extra accounts
for token in "${EXTRA_TOKENS[@]}"; do
    list_account_repos "$token"
done

log "Total unique repos: ${#repo_tokens[@]}"
echo

hc_ping start

# --- Backup each repo ---
cloned=0
updated=0
failed=0
failed_repos=()

# Sort repo names for deterministic order
mapfile -t sorted_repos < <(printf '%s\n' "${!repo_tokens[@]}" | sort)

for full_name in "${sorted_repos[@]}"; do
    token="${repo_tokens[$full_name]}"
    target="$BACKUP_DIR/$full_name"

    if [[ "$CLONE_PROTOCOL" == "ssh" ]]; then
        clone_url="git@github.com:$full_name.git"
    else
        clone_url="https://github.com/$full_name.git"
    fi

    if [[ -d "$target" ]]; then
        log "Updating $full_name ..."
        if run_git "$token" -C "$target" remote update --prune 2>&1; then
            updated=$((updated + 1))
        else
            log "  FAILED to update $full_name"
            failed=$((failed + 1))
            failed_repos+=("$full_name")
        fi
    else
        log "Cloning $full_name ..."
        if run_git "$token" clone --mirror "$clone_url" "$target" --quiet 2>&1; then
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
