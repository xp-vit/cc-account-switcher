# Multi-Account Switcher for Claude Code

A tool to manage and switch between multiple Claude Code accounts on macOS, Linux, WSL, and Windows.

## Features

- **Multi-account management**: Add, remove, and list Claude Code accounts
- **Quick switching**: Switch between accounts with simple commands
- **Smart switching**: `--switch-best` picks the account with the most remaining capacity
- **Usage stats**: `--usage` shows 5-hour session and weekly utilization for every account
- **Tab completion**: First-class shell completion for commands and account IDs
- **Cross-platform**: macOS / Linux / WSL via `ccswitch.sh` — Windows via `ccswitch.ps1` / `ccswitch.bat`
- **Secure storage**: macOS Keychain or restricted files (Linux/WSL/Windows)
- **Settings preservation**: Only switches authentication — themes, settings, and preferences stay unchanged

---

## Installation

### macOS / Linux / WSL

```bash
curl -O https://raw.githubusercontent.com/hathi/cc-account-switcher/main/ccswitch.sh
chmod +x ccswitch.sh
```

**Dependencies**: Bash 4.4+ and `jq`

```bash
brew install jq          # macOS
sudo apt install jq      # Ubuntu/Debian
```

### Windows (PowerShell)

Download `ccswitch.ps1` and `ccswitch.bat` (and `ccswitch.completion.ps1` for tab completion).

No external dependencies — uses PowerShell built-ins (`Invoke-RestMethod`, `ConvertFrom-Json`).

Run from any terminal:
```
ccswitch --list
```

Or explicitly:
```
.\ccswitch.ps1 --list
```

---

## Usage

### First-time setup

1. **Log into Claude Code** with your first account
2. Add it: `./ccswitch.sh --add-account`
3. Log out, log into Claude Code with your second account
4. Add it: `./ccswitch.sh --add-account`
5. Switch: `./ccswitch.sh --switch`
6. **Restart Claude Code** after every switch

### Commands

| Command | Description |
|---|---|
| `--add-account` | Add the currently logged-in account |
| `--remove-account <num\|email>` | Remove an account by number or email |
| `--list` | List all managed accounts |
| `--usage` | Show 5-hour session and weekly usage for all accounts |
| `--switch` | Rotate to the next account in sequence |
| `--switch-to <num\|email>` | Switch to a specific account |
| `--switch-best` | Auto-switch to the account with the most remaining capacity |
| `--install-completion` | Install tab completion into your shell profile |
| `--help` | Show help |

### Examples

```bash
./ccswitch.sh --add-account
./ccswitch.sh --list
./ccswitch.sh --usage
./ccswitch.sh --switch
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com
./ccswitch.sh --switch-best
./ccswitch.sh --remove-account user2@example.com
```

> **After every switch:** restart Claude Code to use the new authentication.

---

## Tab Completion

### PowerShell (Windows)

```powershell
.\ccswitch.ps1 --install-completion
```

Adds a line to your `$PROFILE`. Restart PowerShell (or dot-source the profile). Then:

```
ccswitch --sw<TAB>          →  --switch  --switch-best  --switch-to
ccswitch --switch-to <TAB>  →  1  user@example.com  2  other@example.com
```

### Bash (macOS / Linux / WSL)

```bash
./ccswitch.sh --install-completion
```

Appends a `source` line to `~/.bashrc`. Restart your shell or `source ~/.bashrc`. Then:

```
./ccswitch.sh --sw<TAB>          →  --switch  --switch-best  --switch-to
./ccswitch.sh --switch-to <TAB>  →  1  user@example.com  2  other@example.com
```

Manual setup (both platforms): source the completion file from your profile:
```bash
source /path/to/ccswitch.completion.bash   # bash
. /path/to/ccswitch.completion.ps1         # PowerShell
```

---

## How It Works

Backup location: `~/.claude-switch-backup/`

```
~/.claude-switch-backup/
  sequence.json           — master index (account list, order, active account)
  configs/                — per-account copy of ~/.claude/.claude.json
  credentials/            — per-account credentials (Linux/WSL/Windows)
```

macOS stores credentials in Keychain instead of files.

**Switch operation:**
1. Back up current account's live credentials and config
2. Restore target account's backed-up credentials and config
3. Merge only the `oauthAccount` field into the current config (preserving all other settings)
4. Update `sequence.json`

---

## Usage Stats (`--usage`)

Calls `GET https://api.anthropic.com/api/oauth/usage` with your stored OAuth token.
Shows a progress bar for the current 5-hour session and the rolling 7-day window,
plus a "Use in this order" recommendation sorted by urgency (most capacity expiring soonest).

`--switch-best` uses the same data to auto-switch to the optimal account.

---

## Troubleshooting

**"No active Claude account"** — make sure you're logged in to Claude Code before running `--add-account`.

**"Missing backup data"** — the account was removed or never fully added. Run `--add-account` while logged in as that account.

**Claude Code doesn't recognize the new account** — restart Claude Code after switching (`--list` should show the new active account).

**Windows: ExecutionPolicy error** — the `.bat` launcher passes `-ExecutionPolicy Bypass` automatically. If running `.ps1` directly: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`.

---

## Uninstall

```bash
rm -rf ~/.claude-switch-backup
rm ccswitch.sh ccswitch.completion.bash   # or ccswitch.ps1 / ccswitch.bat on Windows
```

Your current Claude Code login remains active.

---

## Security

- macOS: credentials in Keychain
- Linux / WSL / Windows: credentials in files with mode 600
- The script refuses to run as root (unless in a container)

## License

MIT — see [LICENSE](LICENSE)
