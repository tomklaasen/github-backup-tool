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

if [[ "$CLONE_PROTOCOL" != "https" && "$CLONE_PROTOCOL" != "ssh" ]]; then
    echo "ERROR: CLONE_PROTOCOL must be 'https' or 'ssh', got '$CLONE_PROTOCOL'" >&2
    exit 1
fi

# --- Verify prerequisites ---
if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI is not installed. Install it with: sudo apt install gh" >&2
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "ERROR: gh CLI is not authenticated. Run: gh auth login" >&2
    exit 1
fi

if ! command -v git &>/dev/null; then
    echo "ERROR: git is not installed." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- Collect all repos ---
echo "Fetching repository list..."

repos=()

# Personal repos
while IFS= read -r repo; do
    repos+=("$repo")
done < <(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')

echo "Found ${#repos[@]} personal repos."

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
    done < <(gh repo list "$org" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
    echo "Found $(( ${#repos[@]} - count_before )) repos in org '$org'."
done

# Deduplicate
mapfile -t repos < <(printf '%s\n' "${repos[@]}" | sort -u)

echo "Total unique repos: ${#repos[@]}"
echo ""

# --- Backup each repo ---
cloned=0
updated=0
failed=0
failed_repos=()

for full_name in "${repos[@]}"; do
    # repo name is the part after the slash
    repo_name="${full_name#*/}"
    target="$BACKUP_DIR/$repo_name"

    if [[ -d "$target/.git" ]]; then
        echo "Updating $full_name ..."
        if (cd "$target" && git fetch --all --quiet && git pull --quiet) 2>&1; then
            updated=$((updated + 1))
        else
            echo "  FAILED to update $full_name" >&2
            failed=$((failed + 1))
            failed_repos+=("$full_name")
        fi
    else
        echo "Cloning $full_name ..."
        if [[ "$CLONE_PROTOCOL" == "ssh" ]]; then
            clone_url="git@github.com:$full_name.git"
        else
            clone_url="https://github.com/$full_name.git"
        fi
        if git clone "$clone_url" "$target" --quiet 2>&1; then
            cloned=$((cloned + 1))
        else
            echo "  FAILED to clone $full_name" >&2
            failed=$((failed + 1))
            failed_repos+=("$full_name")
        fi
    fi
done

# --- Summary ---
echo ""
echo "===== Backup complete ====="
echo "Cloned:  $cloned new"
echo "Updated: $updated existing"
echo "Failed:  $failed"
if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo "Failed repos:"
    for r in "${failed_repos[@]}"; do
        echo "  - $r"
    done
fi
