# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A single-file Bash script (`ccswitch.sh`) for managing and switching between multiple Claude Code accounts. The entire tool lives in one script with no build system, no package manager, and no tests.

## Requirements

- Bash 4.4+
- `jq` (JSON processor)

## Running the Script

```bash
# Make executable (first time only)
chmod +x ccswitch.sh

# Run directly
./ccswitch.sh --help
./ccswitch.sh --list
./ccswitch.sh --add-account
./ccswitch.sh --usage                    # Show 5-hour and weekly usage for all accounts
./ccswitch.sh --switch
./ccswitch.sh --switch-to <num|email>
./ccswitch.sh --remove-account <num|email>
```

## Architecture

The entire logic is in `ccswitch.sh`. Key design decisions:

**Storage layout** (`~/.claude-switch-backup/`):
- `sequence.json` — master index: account list, sequence order, and active account number
- `configs/` — per-account copies of `~/.claude/.claude.json` (or `~/.claude.json`)
- `credentials/` — per-account credentials (Linux/WSL only; macOS uses Keychain)

**Platform branching**: `detect_platform()` returns `macos`, `linux`, or `wsl`. Credential read/write functions (`read_credentials`, `write_credentials`, `read_account_credentials`, `write_account_credentials`) branch on this to use either macOS `security` keychain or files at `~/.claude/.credentials.json`.

**Config file location**: `get_claude_config_path()` checks `~/.claude/.claude.json` first (verifying it has a valid `oauthAccount`), then falls back to `~/.claude.json`.

**Switch operation** (`perform_switch`): backs up current account's live credentials + config → restores target account's backed-up credentials + config → merges only the `oauthAccount` field into the current config (preserving all other settings like themes/preferences) → updates `sequence.json`.

**Account identity**: accounts are identified by an auto-incrementing integer key in `sequence.json`. All backup files are named `<num>-<email>`.

**Safe JSON writes**: `write_json()` writes to a temp file, validates with `jq`, then atomically moves it into place with `chmod 600`.

**Root guard**: the script refuses to run as root unless inside a container (detected via `/proc/1/cgroup`, `/.dockerenv`, mount info, or `$CONTAINER` env var).

**Usage stats API**: `--usage` calls `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. Returns `five_hour.{utilization, resets_at}` and `seven_day.{utilization, resets_at}`. The required beta header was reverse-engineered from the Claude binary (`CP="oauth-2025-04-20"` constant). Inactive accounts use backup credentials; if their OAuth tokens have expired, the API returns a 401 with a user-facing message. **Cloudflare blocks requests without `User-Agent: claude-code/<version>`** — omitting it causes silent 429s regardless of token validity.
