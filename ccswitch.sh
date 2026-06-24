#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# ANSI colors (disabled when stdout is not a terminal)
if [[ -t 1 ]]; then
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_RED=$'\033[31m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_DIM='' C_RESET=''
fi

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier resolution function
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Look up account number by email
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
        else
            echo ""
        fi
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi
    
    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi
    
    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi
    
    local account_num
    account_num=$(get_next_account_number)
    
    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi
    
    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")
    
    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local account_num
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi
        
        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi
    
    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi
    
    local email
    email=$(echo "$account_info" | jq -r '.email')
    
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    
    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi
    
    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi
    
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi
    
    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi
    
    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi
    
    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)
    
    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi
    
    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        if "\($num)" == $active then
            "  \($num): \(.email) (active)"
        else
            "  \($num): \(.email)"
        end
    ' "$SEQUENCE_FILE"
}

# Parse ISO 8601 timestamp to Unix epoch seconds
parse_iso_to_epoch() {
    local ts="$1"
    case "$(detect_platform)" in
        linux|wsl)
            date -d "$ts" +%s 2>/dev/null || echo "0"
            ;;
        macos)
            # Strip microseconds, normalize +HH:MM to +HHMM for BSD date
            local ts_norm
            ts_norm=$(echo "$ts" | sed 's/\.[0-9]*//' | sed 's/+\([0-9][0-9]\):\([0-9][0-9]\)$/+\1\2/')
            date -jf "%Y-%m-%dT%H:%M:%S%z" "$ts_norm" +%s 2>/dev/null || echo "0"
            ;;
        *)
            python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${ts}').timestamp()))" 2>/dev/null || echo "0"
            ;;
    esac
}

# Format seconds as human-readable time remaining
format_time_remaining() {
    local total_seconds="$1"
    local days=$(( total_seconds / 86400 ))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))

    local day_s="days" hour_s="hours" min_s="minutes"
    [[ $days -eq 1 ]] && day_s="day"
    [[ $hours -eq 1 ]] && hour_s="hour"
    [[ $minutes -eq 1 ]] && min_s="minute"

    if [[ $days -gt 0 ]]; then
        [[ $hours -gt 0 ]] && echo "${days} ${day_s} and ${hours} ${hour_s}" || echo "${days} ${day_s}"
    elif [[ $hours -gt 0 ]]; then
        [[ $minutes -gt 0 ]] && echo "${hours} ${hour_s} and ${minutes} ${min_s}" || echo "${hours} ${hour_s}"
    else
        echo "${minutes} ${min_s}"
    fi
}

# Return ANSI color for a utilization percentage (green=lots left, red=almost full)
usage_color() {
    local percent="$1"
    if [[ $percent -ge 80 ]]; then
        printf '%s' "$C_RED"
    elif [[ $percent -ge 50 ]]; then
        printf '%s' "$C_YELLOW"
    else
        printf '%s' "$C_GREEN"
    fi
}

# Render a 50-char wide text progress bar with optional color
draw_progress_bar() {
    local percent="$1"
    local color="${2:-}"
    local width=50
    local filled=$(( percent * width / 100 ))
    [[ $filled -gt $width ]] && filled=$width
    [[ $filled -lt 0 ]] && filled=0

    local bar="" i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<width; i++)); do bar+=" "; done
    printf "    %s%s%s  %d%% used\n" "$color" "$bar" "$C_RESET" "$percent"
}

# Fetch usage stats from the Anthropic API using stored credentials.
# Auto-refreshes expired access tokens using the stored refresh token.
# Pass account_num + email for inactive accounts so refreshed tokens are
# written back to the backup (Anthropic rotates refresh tokens on each use).
fetch_account_usage() {
    local creds_json="$1"
    local account_num="${2:-}"
    local email="${3:-}"

    local access_token expires_at
    access_token=$(echo "$creds_json" | jq -r '.claudeAiOauth.accessToken // empty')
    expires_at=$(echo "$creds_json" | jq -r '.claudeAiOauth.expiresAt // 0')

    [[ -z "$access_token" ]] && return 1

    # expiresAt is in milliseconds; refresh if expired using claude CLI
    local now_ms=$(( $(date +%s) * 1000 ))
    if [[ "$expires_at" -le "$now_ms" && -n "$account_num" && -n "$email" ]]; then
        # Cloudflare blocks curl/wget/python/node from the refresh endpoint
        # (TLS fingerprint detection). Use claude CLI which passes through.
        # Temporarily swap credentials + config, let claude refresh, restore.
        local config_path
        config_path=$(get_claude_config_path)
        local orig_creds="" orig_config=""
        [[ -f "$HOME/.claude/.credentials.json" ]] && orig_creds=$(cat "$HOME/.claude/.credentials.json")
        [[ -f "$config_path" ]] && orig_config=$(cat "$config_path")

        # Swap in target account's credentials
        mkdir -p "$HOME/.claude"
        printf '%s' "$creds_json" > "$HOME/.claude/.credentials.json"
        chmod 600 "$HOME/.claude/.credentials.json"

        # Swap in target account's oauthAccount config section
        local target_config
        target_config=$(read_account_config "$account_num" "$email")
        if [[ -n "$target_config" && -n "$orig_config" ]]; then
            local oauth_section merged
            oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
            if [[ -n "$oauth_section" && "$oauth_section" != "null" ]]; then
                merged=$(echo "$orig_config" | jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' 2>/dev/null)
                [[ -n "$merged" ]] && write_json "$config_path" "$merged"
            fi
        fi

        # A minimal headless query forces a real OAuth token refresh via the
        # stored refresh token. NOTE: `claude auth status` only READS cached
        # state and never refreshes — it was a silent no-op here, leaving
        # inactive tokens expired (401 "Invalid authentication credentials").
        # `claude -p` actually re-authenticates and rotates the tokens.
        claude -p "ok" >/dev/null 2>&1

        # Read back refreshed credentials and save to backup
        if [[ -f "$HOME/.claude/.credentials.json" ]]; then
            local refreshed_creds new_expiry
            refreshed_creds=$(cat "$HOME/.claude/.credentials.json")
            new_expiry=$(echo "$refreshed_creds" | jq -r '.claudeAiOauth.expiresAt // 0')
            if [[ "$new_expiry" -gt "$now_ms" ]]; then
                access_token=$(echo "$refreshed_creds" | jq -r '.claudeAiOauth.accessToken // empty')
                write_account_credentials "$account_num" "$email" "$refreshed_creds"
            fi
        fi

        # Restore original credentials and config
        if [[ -n "$orig_creds" ]]; then
            printf '%s' "$orig_creds" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
        fi
        if [[ -n "$orig_config" ]]; then
            write_json "$config_path" "$orig_config"
        fi
    fi

    local claude_version
    claude_version=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "2.0.0")

    curl -s \
        --max-time 10 \
        -H "Authorization: Bearer $access_token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        -H "User-Agent: claude-code/${claude_version}" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
}

# Display usage stats for one account
display_account_usage() {
    local account_num="$1"
    local email="$2"
    local is_active="$3"
    local usage_json="$4"
    local now
    now=$(date +%s)

    # Parse weekly usage early to color the header
    local five_util five_reset five_percent="" seven_util_early seven_percent=""
    five_util=$(echo "$usage_json" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
    five_reset=$(echo "$usage_json" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
    [[ -n "$five_util" ]] && five_percent=$(echo "$five_util" | jq '. | round')
    seven_util_early=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
    [[ -n "$seven_util_early" ]] && seven_percent=$(echo "$seven_util_early" | jq '. | round')

    # Color the account header based on weekly utilization
    local hdr_color=""
    [[ -n "$seven_percent" ]] && hdr_color=$(usage_color "$seven_percent")

    if [[ "$is_active" == "true" ]]; then
        printf "\n  %s%sAccount %s: %s (active)%s\n" "$hdr_color" "$C_BOLD" "$account_num" "$email" "$C_RESET"
    else
        printf "\n  %s%sAccount %s: %s%s\n" "$hdr_color" "$C_BOLD" "$account_num" "$email" "$C_RESET"
    fi

    if [[ -z "$usage_json" ]]; then
        printf "    No credentials available\n"
        return
    fi

    if jq -e '.error' <<<"$usage_json" >/dev/null 2>&1; then
        local err_msg
        err_msg=$(echo "$usage_json" | jq -r '.error.message // "unknown error"' 2>/dev/null)
        printf "    %sUnable to fetch usage: %s%s\n" "$C_DIM" "$err_msg" "$C_RESET"
        return
    fi

    printf "\n    Current session\n"
    if [[ -n "$five_percent" ]]; then
        local color reset_epoch secs_left
        color=$(usage_color "$five_percent")
        draw_progress_bar "$five_percent" "$color"
        if [[ -n "$five_reset" ]]; then
            reset_epoch=$(parse_iso_to_epoch "$five_reset")
            secs_left=$(( reset_epoch - now ))
            if [[ $secs_left -gt 0 ]]; then
                printf "    %sResets in %s%s\n" "$C_DIM" "$(format_time_remaining "$secs_left")" "$C_RESET"
            else
                printf "    Resetting now\n"
            fi
        fi
    else
        printf "    N/A\n"
    fi

    # Seven-day window
    local seven_util seven_reset
    seven_util=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty')
    seven_reset=$(echo "$usage_json" | jq -r '.seven_day.resets_at // empty')

    printf "\n    Current week (all models)\n"
    if [[ -n "$seven_util" ]]; then
        local percent color reset_epoch secs_left
        percent=$(echo "$seven_util" | jq '. | round')
        color=$(usage_color "$percent")
        draw_progress_bar "$percent" "$color"
        if [[ -n "$seven_reset" ]]; then
            reset_epoch=$(parse_iso_to_epoch "$seven_reset")
            secs_left=$(( reset_epoch - now ))
            if [[ $secs_left -gt 0 ]]; then
                printf "    %sResets in %s%s\n" "$C_DIM" "$(format_time_remaining "$secs_left")" "$C_RESET"
            else
                printf "    Resetting now\n"
            fi
        fi
    else
        printf "    N/A\n"
    fi
}

# Show usage stats for all managed accounts
cmd_usage() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    local sequence
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))

    if [[ ${#sequence[@]} -eq 0 ]]; then
        echo "No accounts in sequence."
        exit 0
    fi

    printf "Usage Statistics:  %sgreen = use this%s · %syellow = moderate%s · %sred = almost full%s  (by weekly usage)\n" \
        "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_RED" "$C_RESET"

    local now
    now=$(date +%s)

    # urgency_entries collects "SCORE|account_num|email|remaining|hours_left" for recommendation
    local -a urgency_entries=()

    for account_num in "${sequence[@]}"; do
        local email is_active creds usage_json
        email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")
        is_active="false"
        [[ "$email" == "$current_email" ]] && is_active="true"

        # For the active account, prefer live credentials (may have been auto-refreshed)
        if [[ "$is_active" == "true" ]]; then
            creds=$(read_credentials)
            [[ -z "$creds" ]] && creds=$(read_account_credentials "$account_num" "$email")
        else
            creds=$(read_account_credentials "$account_num" "$email")
        fi

        if [[ -n "$creds" ]]; then
            # Pass account_num+email for inactive accounts so refreshed tokens
            # are written back to the backup (active account is managed by Claude Code)
            if [[ "$is_active" == "true" ]]; then
                usage_json=$(fetch_account_usage "$creds")
            else
                usage_json=$(fetch_account_usage "$creds" "$account_num" "$email")
            fi
        else
            usage_json=""
        fi

        display_account_usage "$account_num" "$email" "$is_active" "$usage_json"

        # Throttle: the usage API 429s on rapid sequential calls across accounts.
        sleep 2

        # Compute urgency score: (weekly % remaining) / (hours to reset)
        # Higher = more capacity expiring sooner = use this account now
        if [[ -n "$usage_json" ]] && ! jq -e '.error' <<<"$usage_json" >/dev/null 2>&1; then
            local s_util s_reset
            s_util=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty')
            s_reset=$(echo "$usage_json" | jq -r '.seven_day.resets_at // empty')
            if [[ -n "$s_util" && -n "$s_reset" ]]; then
                local remaining reset_ep hours_left score
                remaining=$(echo "$s_util" | jq '(100 - (. | round)) | if . < 0 then 0 else . end')
                reset_ep=$(parse_iso_to_epoch "$s_reset")
                hours_left=$(( (reset_ep - now) / 3600 ))
                [[ $hours_left -lt 1 ]] && hours_left=1
                score=$(( remaining * 1000 / hours_left ))
                urgency_entries+=("$(printf '%07d|%s|%s|%s|%s' "$score" "$account_num" "$email" "$remaining" "$hours_left")")
            fi
        fi
    done

    # Show recommendation sorted by urgency (highest first)
    if [[ ${#urgency_entries[@]} -gt 0 ]]; then
        printf "\n  %s→ Use in this order:%s\n" "$C_BOLD" "$C_RESET"
        local rank=1
        while IFS='|' read -r score acc em remaining hours_left; do
            local color
            color=$(usage_color "$(( 100 - remaining ))")
            printf "    %s%d. Account %s (%s)%s  —  %d%% weekly left, resets in %s\n" \
                "$color" "$rank" "$acc" "$em" "$C_RESET" \
                "$remaining" "$(format_time_remaining $(( hours_left * 3600 )))"
            (( rank++ ))
        done < <(printf '%s\n' "${urgency_entries[@]}" | sort -t'|' -k1 -rn -k2 -n)
    fi

    printf "\n"
}

# Switch to the highest-urgency account that still has 5-hour session capacity
cmd_switch_best() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    local sequence
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))

    if [[ ${#sequence[@]} -le 1 ]]; then
        echo "Error: Need at least 2 managed accounts to switch"
        exit 1
    fi

    local now
    now=$(date +%s)

    # Find active account number
    local active_num=""
    if [[ "$current_email" != "none" ]]; then
        active_num=$(jq -r --arg email "$current_email" \
            '.accounts | to_entries[] | select(.value.email == $email) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null)
    fi

    echo "Checking accounts..."

    local best_account="" best_email="" best_score=-1 best_remaining=0 best_hours=0

    for account_num in "${sequence[@]}"; do
        local email
        email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")

        local is_active=false
        [[ "$account_num" == "$active_num" ]] && is_active=true

        # Use live credentials for active account, backup for others
        local creds
        if $is_active; then
            creds=$(read_credentials)
        else
            creds=$(read_account_credentials "$account_num" "$email")
        fi
        if [[ -z "$creds" ]]; then
            printf "  Account %s (%s): no credentials\n" "$account_num" "$email"
            continue
        fi

        local usage_json
        if $is_active; then
            usage_json=$(fetch_account_usage "$creds")
        else
            usage_json=$(fetch_account_usage "$creds" "$account_num" "$email")
        fi

        if [[ -z "$usage_json" ]] || jq -e '.error' <<<"$usage_json" >/dev/null 2>&1; then
            local err
            err=$(echo "$usage_json" | jq -r '.error.message // "unavailable"' 2>/dev/null)
            printf "  Account %s (%s): %s\n" "$account_num" "$email" "$err"
            continue
        fi

        # Skip accounts with no 5-hour session capacity left
        local five_util five_percent
        five_util=$(echo "$usage_json" | jq -r '.five_hour.utilization // empty')
        five_percent=0
        [[ -n "$five_util" ]] && five_percent=$(echo "$five_util" | jq '. | round')
        if [[ $five_percent -ge 99 ]]; then
            printf "  Account %s (%s): 5h session full (%d%% used), skipping\n" \
                "$account_num" "$email" "$five_percent"
            continue
        fi

        # Compute urgency: weekly remaining / hours to reset
        local s_util s_reset remaining hours_left score
        s_util=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty')
        s_reset=$(echo "$usage_json" | jq -r '.seven_day.resets_at // empty')
        remaining=0; hours_left=1; score=0
        if [[ -n "$s_util" && -n "$s_reset" ]]; then
            remaining=$(echo "$s_util" | jq '(100 - (. | round)) | if . < 0 then 0 else . end')
            local reset_ep
            reset_ep=$(parse_iso_to_epoch "$s_reset")
            hours_left=$(( (reset_ep - now) / 3600 ))
            [[ $hours_left -lt 1 ]] && hours_left=1
            score=$(( remaining * 1000 / hours_left ))
        fi

        if $is_active; then
            printf "  Account %s (%s): %d%% session used, %d%% weekly left (active)\n" \
                "$account_num" "$email" "$five_percent" "$remaining"
        else
            printf "  Account %s (%s): %d%% session used, %d%% weekly left\n" \
                "$account_num" "$email" "$five_percent" "$remaining"
        fi

        # Prefer higher score; on a tie, prefer non-active account over active
        local prefer=false
        if [[ $score -gt $best_score ]]; then
            prefer=true
        elif [[ $score -eq $best_score && "$best_account" == "$active_num" && "$account_num" != "$active_num" ]]; then
            prefer=true
        fi
        if $prefer; then
            best_score=$score
            best_account=$account_num
            best_email=$email
            best_remaining=$remaining
            best_hours=$hours_left
        fi
    done

    if [[ -z "$best_account" ]]; then
        echo "No accounts available with 5-hour session capacity. Try again after a reset."
        exit 1
    fi

    if [[ "$best_account" == "$active_num" ]]; then
        printf "\nAlready on the best account — Account %s (%s), %d%% weekly left\n" \
            "$best_account" "$best_email" "$best_remaining"
        exit 0
    fi

    printf "\nSwitching to Account %s (%s) — %d%% weekly left, resets in %s\n" \
        "$best_account" "$best_email" "$best_remaining" \
        "$(format_time_remaining $(( best_hours * 3600 )))"

    perform_switch "$best_account"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi
    
    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi
    
    # wait_for_claude_close
    
    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))
    
    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done
    
    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"
    
    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local target_account
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        target_account="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi
        
        # Resolve email to account number
        target_account=$(resolve_account_identifier "$identifier")
        if [[ -z "$target_account" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi
    
    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi
    
    # wait_for_claude_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    
    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)
    
    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi
    
    # Step 3: Activate target account
    write_credentials "$target_creds"
    
    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi
    
    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi
    
    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    
    # Step 4: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Switched to Account-$target_account ($target_email)"
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
    
}

# Show usage
cmd_install_completion() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local comp_file="$script_dir/ccswitch.completion.bash"

    if [[ ! -f "$comp_file" ]]; then
        echo "Error: ccswitch.completion.bash not found next to ccswitch.sh"
        exit 1
    fi

    local line="source \"$comp_file\""
    local rc_file

    # Pick the right rc file
    if [[ -f "$HOME/.bashrc" ]]; then
        rc_file="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        rc_file="$HOME/.bash_profile"
    else
        rc_file="$HOME/.bashrc"
    fi

    if grep -qF "$comp_file" "$rc_file" 2>/dev/null; then
        echo "Completion already installed in $rc_file"
        return
    fi

    printf '\n# ccswitch tab completion\n%s\n' "$line" >> "$rc_file"
    echo "Installed completion in $rc_file"
    echo "Restart your shell or run: $line"
}

show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account                    Add current account to managed accounts"
    echo "  --remove-account <num|email>    Remove account by number or email"
    echo "  --list                           List all managed accounts"
    echo "  --usage                          Show usage stats for all managed accounts"
    echo "  --switch-best                    Switch to best account with 5h session capacity"
    echo "  --switch                         Rotate to next account in sequence"
    echo "  --switch-to <num|email>          Switch to specific account number or email"
    echo "  --install-completion             Install tab completion into shell rc file"
    echo "  --help                           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --add-account"
    echo "  $0 --list"
    echo "  $0 --switch"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --remove-account user@example.com"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    
    check_bash_version
    check_dependencies
    
    case "${1:-}" in
        --add-account)
            cmd_add_account
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --usage)
            cmd_usage
            ;;
        --switch-best)
            cmd_switch_best
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --install-completion)
            cmd_install_completion
            ;;
        --help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi