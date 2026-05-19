# ccswitch.ps1 - Multi-Account Switcher for Claude Code (Windows)
# PowerShell 5.1+  |  No external dependencies

# ── Configuration ─────────────────────────────────────────────────────────────
$BackupDir    = Join-Path $HOME ".claude-switch-backup"
$SequenceFile = Join-Path $BackupDir "sequence.json"

# ── ANSI colors ───────────────────────────────────────────────────────────────
$ESC      = [char]27
$useColor = $false
if (-not [Console]::IsOutputRedirected) {
    # Windows Terminal, VS Code, ConEmu, or PS7+
    if ($env:WT_SESSION -or $env:TERM_PROGRAM -or ($env:ConEmuANSI -eq "ON") -or
        ($PSVersionTable.PSVersion.Major -ge 7)) {
        $useColor = $true
    } else {
        # Try to enable VT100 on classic conhost (Windows 10+)
        try {
            $t = Add-Type -PassThru -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class Win32Con {
    [DllImport("kernel32")] public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
            $h = $t::GetStdHandle(-11); $m = [uint32]0
            $t::GetConsoleMode($h, [ref]$m) | Out-Null
            $useColor = $t::SetConsoleMode($h, ($m -bor 4))
        } catch { }
    }
}
if ($useColor) {
    $C_GREEN = "${ESC}[32m"; $C_YELLOW = "${ESC}[33m"; $C_RED = "${ESC}[31m"
    $C_BOLD  = "${ESC}[1m";  $C_DIM    = "${ESC}[2m";  $C_RESET = "${ESC}[0m"
} else {
    $C_GREEN = $C_YELLOW = $C_RED = $C_BOLD = $C_DIM = $C_RESET = ""
}

# ── Path helpers ──────────────────────────────────────────────────────────────
function Get-ClaudeConfigPath {
    $primary  = Join-Path $HOME ".claude\.claude.json"
    $fallback = Join-Path $HOME ".claude.json"
    if (Test-Path $primary) {
        try {
            $j = Get-Content $primary -Raw | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains "oauthAccount") { return $primary }
        } catch { }
    }
    return $fallback
}

function Get-UtcNow { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }

# ── Safe JSON write ───────────────────────────────────────────────────────────
function Write-JsonSafe {
    param([string]$Path, [object]$Content)
    $json = $Content | ConvertTo-Json -Depth 20
    $null = $json | ConvertFrom-Json   # validate
    $tmp  = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    Move-Item -Force -Path $tmp -Destination $Path
}

# ── sequence.json ─────────────────────────────────────────────────────────────
function Read-SequenceFile {
    if (-not (Test-Path $SequenceFile)) { return $null }
    Get-Content $SequenceFile -Raw | ConvertFrom-Json
}

function Write-SequenceFile { param([object]$Data); Write-JsonSafe -Path $SequenceFile -Content $Data }

function Initialize-Directories {
    New-Item -ItemType Directory -Force -Path $BackupDir                         | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir "configs")      | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir "credentials")  | Out-Null
}

function Initialize-SequenceFile {
    if (Test-Path $SequenceFile) { return }
    $init = [PSCustomObject]@{
        activeAccountNumber = $null
        lastUpdated         = Get-UtcNow
        sequence            = @()
        accounts            = [PSCustomObject]@{}
    }
    Write-JsonSafe -Path $SequenceFile -Content $init
}

# ── Account helpers ───────────────────────────────────────────────────────────
function Get-CurrentAccount {
    $p = Get-ClaudeConfigPath
    if (-not (Test-Path $p)) { return "none" }
    try {
        $email = (Get-Content $p -Raw | ConvertFrom-Json).oauthAccount.emailAddress
        if ($email) { return $email }
    } catch { }
    return "none"
}

function Test-Email { param([string]$e); $e -match '^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$' }

function Get-NextAccountNumber {
    $seq = Read-SequenceFile
    if (-not $seq) { return 1 }
    $keys = @($seq.accounts.PSObject.Properties.Name | ForEach-Object { [int]$_ })
    if ($keys.Count -eq 0) { return 1 }
    return (($keys | Measure-Object -Maximum).Maximum) + 1
}

function Test-AccountExists {
    param([string]$Email)
    $seq = Read-SequenceFile
    if (-not $seq) { return $false }
    foreach ($p in $seq.accounts.PSObject.Properties) { if ($p.Value.email -eq $Email) { return $true } }
    return $false
}

function Resolve-AccountIdentifier {
    param([string]$Identifier)
    if ($Identifier -match '^\d+$') { return $Identifier }
    $seq = Read-SequenceFile
    if (-not $seq) { return "" }
    foreach ($p in $seq.accounts.PSObject.Properties) { if ($p.Value.email -eq $Identifier) { return $p.Name } }
    return ""
}

# ── Credentials (file-based) ──────────────────────────────────────────────────
function Read-Credentials {
    $p = Join-Path $HOME ".claude\.credentials.json"
    if (Test-Path $p) { return Get-Content $p -Raw }
    return ""
}

function Write-Credentials {
    param([string]$Creds)
    $dir = Join-Path $HOME ".claude"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir ".credentials.json"), $Creds, [System.Text.Encoding]::UTF8)
}

function Read-AccountCredentials {
    param([string]$Num, [string]$Email)
    $p = Join-Path $BackupDir "credentials\.claude-credentials-$Num-$Email.json"
    if (Test-Path $p) { return Get-Content $p -Raw }
    return ""
}

function Write-AccountCredentials {
    param([string]$Num, [string]$Email, [string]$Creds)
    $p = Join-Path $BackupDir "credentials\.claude-credentials-$Num-$Email.json"
    [System.IO.File]::WriteAllText($p, $Creds, [System.Text.Encoding]::UTF8)
}

function Read-AccountConfig {
    param([string]$Num, [string]$Email)
    $p = Join-Path $BackupDir "configs\.claude-config-$Num-$Email.json"
    if (Test-Path $p) { return Get-Content $p -Raw }
    return ""
}

function Write-AccountConfig {
    param([string]$Num, [string]$Email, [string]$Config)
    $p = Join-Path $BackupDir "configs\.claude-config-$Num-$Email.json"
    [System.IO.File]::WriteAllText($p, $Config, [System.Text.Encoding]::UTF8)
}

# ── Process detection ─────────────────────────────────────────────────────────
function Test-ClaudeRunning {
    $null -ne (Get-Process -Name "claude" -ErrorAction SilentlyContinue)
}

# ── Time helpers ──────────────────────────────────────────────────────────────
function ConvertTo-UnixEpoch {
    param([string]$Timestamp)
    try { return [DateTimeOffset]::Parse($Timestamp).ToUnixTimeSeconds() } catch { return 0 }
}

function Format-TimeRemaining {
    param([long]$TotalSeconds)
    $d = [int]($TotalSeconds / 86400); $h = [int](($TotalSeconds % 86400) / 3600); $m = [int](($TotalSeconds % 3600) / 60)
    $ds = if ($d -eq 1) {"day"} else {"days"}; $hs = if ($h -eq 1) {"hour"} else {"hours"}; $ms = if ($m -eq 1) {"minute"} else {"minutes"}
    if ($d -gt 0)    { if ($h -gt 0) {"$d $ds and $h $hs"} else {"$d $ds"} }
    elseif ($h -gt 0){ if ($m -gt 0) {"$h $hs and $m $ms"} else {"$h $hs"} }
    else             { "$m $ms" }
}

# ── Usage rendering ───────────────────────────────────────────────────────────
function Get-UsageColor {
    param([int]$Pct)
    if ($Pct -ge 80) { $C_RED } elseif ($Pct -ge 50) { $C_YELLOW } else { $C_GREEN }
}

function Write-ProgressBar {
    param([int]$Pct, [string]$Color = "")
    $w = 50; $f = [Math]::Min([Math]::Max([int]($Pct * $w / 100), 0), $w)
    $bar = ("$([char]0x2588)" * $f) + (" " * ($w - $f))
    Write-Host ("    {0}{1}{2}  {3}% used" -f $Color, $bar, $C_RESET, $Pct)
}

# ── Usage API ────────────────────────────────────────────────────────────────
function Invoke-UsageApi {
    param([string]$CredsJson, [string]$AccountNum = "", [string]$Email = "")

    $creds       = $CredsJson | ConvertFrom-Json
    $accessToken = $creds.claudeAiOauth.accessToken
    $expiresAt   = [long]$creds.claudeAiOauth.expiresAt
    if (-not $accessToken) { return $null }

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    if ($expiresAt -le $nowMs -and $AccountNum -and $Email) {
        $configPath = Get-ClaudeConfigPath
        $origCreds  = Read-Credentials
        $origConfig = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { "" }

        Write-Credentials -Creds $CredsJson

        $targetConfig = Read-AccountConfig -Num $AccountNum -Email $Email
        if ($targetConfig -and $origConfig) {
            try {
                $tc = $targetConfig | ConvertFrom-Json; $oc = $origConfig | ConvertFrom-Json
                $oc.oauthAccount = $tc.oauthAccount
                Write-JsonSafe -Path $configPath -Content $oc
            } catch { }
        }

        & claude auth status 2>&1 | Out-Null

        $credPath = Join-Path $HOME ".claude\.credentials.json"
        if (Test-Path $credPath) {
            $refreshed = Get-Content $credPath -Raw
            $newExpiry = [long]($refreshed | ConvertFrom-Json).claudeAiOauth.expiresAt
            if ($newExpiry -gt $nowMs) {
                $accessToken = ($refreshed | ConvertFrom-Json).claudeAiOauth.accessToken
                Write-AccountCredentials -Num $AccountNum -Email $Email -Creds $refreshed
            }
        }

        if ($origCreds) { Write-Credentials -Creds $origCreds }
        if ($origConfig) {
            try { Write-JsonSafe -Path $configPath -Content ($origConfig | ConvertFrom-Json) } catch { }
        }
    }

    $ver = "2.0.0"
    try { $ver = (& claude --version 2>&1) -replace '.*?(\d+\.\d+\.\d+).*','$1' } catch { }

    try {
        return Invoke-RestMethod `
            -Uri     "https://api.anthropic.com/api/oauth/usage" `
            -Method  GET `
            -Headers @{
                Authorization  = "Bearer $accessToken"
                "anthropic-beta" = "oauth-2025-04-20"
                "Content-Type"   = "application/json"
                "User-Agent"     = "claude-code/$ver"
            } `
            -TimeoutSec 10 -ErrorAction Stop
    } catch {
        try { return ($_.ErrorDetails.Message | ConvertFrom-Json) } catch { return $null }
    }
}

function Show-AccountUsage {
    param([string]$Num, [string]$Email, [bool]$IsActive, $Data)

    $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $s7Util = if ($Data) { $Data.seven_day.utilization } else { $null }
    $s7Pct  = if ($null -ne $s7Util) { [int][Math]::Round([double]$s7Util) } else { -1 }
    $hdr    = if ($s7Pct -ge 0) { Get-UsageColor -Pct $s7Pct } else { "" }
    $label  = if ($IsActive) { " (active)" } else { "" }

    Write-Host ""
    Write-Host ("  {0}{1}Account {2}: {3}{4}{5}" -f $hdr, $C_BOLD, $Num, $Email, $label, $C_RESET)

    if (-not $Data) { Write-Host "    No credentials available"; return }

    if ($Data.PSObject.Properties.Name -contains "error") {
        $msg = if ($Data.error.message) { $Data.error.message } else { "unknown error" }
        Write-Host ("    {0}Unable to fetch usage: {1}{2}" -f $C_DIM, $msg, $C_RESET)
        return
    }

    # 5-hour session
    $f5Util  = $Data.five_hour.utilization
    $f5Reset = $Data.five_hour.resets_at
    $f5Pct   = if ($null -ne $f5Util) { [int][Math]::Round([double]$f5Util) } else { -1 }
    Write-Host ""; Write-Host "    Current session"
    if ($f5Pct -ge 0) {
        Write-ProgressBar -Pct $f5Pct -Color (Get-UsageColor -Pct $f5Pct)
        if ($f5Reset) {
            $secs = (ConvertTo-UnixEpoch $f5Reset) - $now
            if ($secs -gt 0) { Write-Host ("    {0}Resets in {1}{2}" -f $C_DIM, (Format-TimeRemaining $secs), $C_RESET) } else { Write-Host "    Resetting now" }
        }
    } else { Write-Host "    N/A" }

    # 7-day window
    $s7Reset = $Data.seven_day.resets_at
    Write-Host ""; Write-Host "    Current week (all models)"
    if ($s7Pct -ge 0) {
        Write-ProgressBar -Pct $s7Pct -Color (Get-UsageColor -Pct $s7Pct)
        if ($s7Reset) {
            $secs = (ConvertTo-UnixEpoch $s7Reset) - $now
            if ($secs -gt 0) { Write-Host ("    {0}Resets in {1}{2}" -f $C_DIM, (Format-TimeRemaining $secs), $C_RESET) } else { Write-Host "    Resetting now" }
        }
    } else { Write-Host "    N/A" }
}

# ── Commands ──────────────────────────────────────────────────────────────────
function Invoke-AddAccount {
    Initialize-Directories; Initialize-SequenceFile
    $email = Get-CurrentAccount
    if ($email -eq "none") { Write-Host "Error: No active Claude account. Log in first." -ForegroundColor Red; exit 1 }
    if (Test-AccountExists $email) { Write-Host "Account $email is already managed."; return }

    $num         = Get-NextAccountNumber
    $creds       = Read-Credentials
    if (-not $creds) { Write-Host "Error: No credentials found for current account" -ForegroundColor Red; exit 1 }
    $configPath  = Get-ClaudeConfigPath
    $config      = Get-Content $configPath -Raw
    $uuid        = ($config | ConvertFrom-Json).oauthAccount.accountUuid

    Write-AccountCredentials -Num $num -Email $email -Creds $creds
    Write-AccountConfig      -Num $num -Email $email -Config $config

    $seq = Read-SequenceFile
    $seq.accounts | Add-Member -NotePropertyName "$num" -NotePropertyValue ([PSCustomObject]@{
        email = $email; uuid = $uuid; added = Get-UtcNow
    }) -Force
    $seq.sequence            = @($seq.sequence) + @([int]$num)
    $seq.activeAccountNumber = [int]$num
    $seq.lastUpdated         = Get-UtcNow
    Write-SequenceFile $seq
    Write-Host "Added Account $num : $email"
}

function Invoke-RemoveAccount {
    param([string]$Identifier)
    if (-not $Identifier) { Write-Host "Usage: ccswitch --remove-account <num|email>"; exit 1 }
    if (-not (Test-Path $SequenceFile)) { Write-Host "Error: No accounts managed yet" -ForegroundColor Red; exit 1 }

    $num = Resolve-AccountIdentifier $Identifier
    if (-not $num) { Write-Host "Error: No account found: $Identifier" -ForegroundColor Red; exit 1 }

    $seq  = Read-SequenceFile
    $info = $seq.accounts.PSObject.Properties[$num]
    if (-not $info) { Write-Host "Error: Account-$num does not exist" -ForegroundColor Red; exit 1 }
    $email = $info.Value.email

    if ("$($seq.activeAccountNumber)" -eq "$num") {
        Write-Host "Warning: Account-$num ($email) is currently active" -ForegroundColor Yellow
    }

    $confirm = Read-Host "Permanently remove Account-$num ($email)? [y/N]"
    if ($confirm -notmatch '^[yY]$') { Write-Host "Cancelled"; return }

    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $BackupDir "credentials\.claude-credentials-$num-$email.json")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $BackupDir "configs\.claude-config-$num-$email.json")

    $seq.accounts.PSObject.Properties.Remove("$num")
    $seq.sequence    = @($seq.sequence | Where-Object { $_ -ne [int]$num })
    $seq.lastUpdated = Get-UtcNow
    Write-SequenceFile $seq
    Write-Host "Account-$num ($email) removed"
}

function Invoke-List {
    if (-not (Test-Path $SequenceFile)) {
        Write-Host "No accounts managed yet."
        Invoke-FirstRunSetup
        return
    }
    $currentEmail = Get-CurrentAccount
    $seq          = Read-SequenceFile
    $activeNum    = ""
    if ($currentEmail -ne "none") {
        foreach ($p in $seq.accounts.PSObject.Properties) {
            if ($p.Value.email -eq $currentEmail) { $activeNum = $p.Name; break }
        }
    }
    Write-Host "Accounts:"
    foreach ($n in $seq.sequence) {
        $acct  = $seq.accounts.PSObject.Properties["$n"].Value
        $label = if ("$n" -eq "$activeNum") { " (active)" } else { "" }
        Write-Host ("  {0}: {1}{2}" -f $n, $acct.email, $label)
    }
}

function Invoke-FirstRunSetup {
    $email = Get-CurrentAccount
    if ($email -eq "none") { Write-Host "No active Claude account. Log in first."; return }
    $r = Read-Host "No managed accounts. Add current account ($email)? [Y/n]"
    if ($r -match '^[nN]$') { Write-Host "Run 'ccswitch --add-account' later."; return }
    Invoke-AddAccount
}

function Invoke-Usage {
    if (-not (Test-Path $SequenceFile)) { Write-Host "Error: No accounts managed yet" -ForegroundColor Red; exit 1 }
    $currentEmail = Get-CurrentAccount
    $seq          = Read-SequenceFile
    $sequence     = @($seq.sequence)
    if ($sequence.Count -eq 0) { Write-Host "No accounts in sequence."; return }

    Write-Host ("Usage Statistics:  {0}green = use this{1} · {2}yellow = moderate{3} · {4}red = almost full{5}  (by weekly usage)" `
        -f $C_GREEN, $C_RESET, $C_YELLOW, $C_RESET, $C_RED, $C_RESET)

    $now     = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $urgency = @()

    foreach ($n in $sequence) {
        $email    = $seq.accounts.PSObject.Properties["$n"].Value.email
        $isActive = ($email -eq $currentEmail)
        if ($isActive) {
            $live  = Read-Credentials
            $creds = if ($live) { $live } else { Read-AccountCredentials "$n" $email }
        } else {
            $creds = Read-AccountCredentials "$n" $email
        }
        $data     = if ($creds) {
            if ($isActive) { Invoke-UsageApi $creds } else { Invoke-UsageApi $creds "$n" $email }
        } else { $null }

        Show-AccountUsage -Num "$n" -Email $email -IsActive $isActive -Data $data

        if ($data -and -not ($data.PSObject.Properties.Name -contains "error")) {
            $su = $data.seven_day.utilization; $sr = $data.seven_day.resets_at
            if ($null -ne $su -and $sr) {
                $rem   = [int][Math]::Max(100 - [int][Math]::Round([double]$su), 0)
                $hrs   = [int][Math]::Max(((ConvertTo-UnixEpoch $sr) - $now) / 3600, 1)
                $score = [int]($rem * 1000 / $hrs)
                $urgency += [PSCustomObject]@{ Score=$score; Num="$n"; Email=$email; Rem=$rem; Hrs=$hrs }
            }
        }
    }

    if ($urgency.Count -gt 0) {
        Write-Host ""; Write-Host ("  {0}→ Use in this order:{1}" -f $C_BOLD, $C_RESET)
        $rank = 1
        foreach ($e in ($urgency | Sort-Object Score -Descending)) {
            $col = Get-UsageColor -Pct (100 - $e.Rem)
            Write-Host ("    {0}{1}. Account {2} ({3}){4}  —  {5}% weekly left, resets in {6}" `
                -f $col, $rank, $e.Num, $e.Email, $C_RESET, $e.Rem, (Format-TimeRemaining ($e.Hrs * 3600)))
            $rank++
        }
    }
    Write-Host ""
}

function Invoke-SwitchBest {
    if (-not (Test-Path $SequenceFile)) { Write-Host "Error: No accounts managed yet" -ForegroundColor Red; exit 1 }
    $currentEmail = Get-CurrentAccount
    $seq          = Read-SequenceFile
    $sequence     = @($seq.sequence)
    if ($sequence.Count -le 1) { Write-Host "Error: Need at least 2 accounts to switch" -ForegroundColor Red; exit 1 }

    $activeNum = ""
    if ($currentEmail -ne "none") {
        foreach ($p in $seq.accounts.PSObject.Properties) { if ($p.Value.email -eq $currentEmail) { $activeNum = $p.Name; break } }
    }

    Write-Host "Checking accounts..."
    $now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $best = $null

    foreach ($n in $sequence) {
        $email    = $seq.accounts.PSObject.Properties["$n"].Value.email
        $isActive = ("$n" -eq "$activeNum")
        $creds    = if ($isActive) { Read-Credentials } else { Read-AccountCredentials "$n" $email }
        if (-not $creds) { Write-Host ("  Account {0} ({1}): no credentials" -f $n, $email); continue }

        $data = if ($isActive) { Invoke-UsageApi $creds } else { Invoke-UsageApi $creds "$n" $email }
        if (-not $data -or ($data.PSObject.Properties.Name -contains "error")) {
            $msg = if ($data) { $data.error.message } else { "unavailable" }
            Write-Host ("  Account {0} ({1}): {2}" -f $n, $email, $msg); continue
        }

        $f5u = $data.five_hour.utilization
        $f5p = if ($null -ne $f5u) { [int][Math]::Round([double]$f5u) } else { 0 }
        if ($f5p -ge 99) { Write-Host ("  Account {0} ({1}): 5h session full ({2}% used), skipping" -f $n, $email, $f5p); continue }

        $su = $data.seven_day.utilization; $sr = $data.seven_day.resets_at
        $rem = 0; $hrs = 1; $score = 0
        if ($null -ne $su -and $sr) {
            $rem   = [int][Math]::Max(100 - [int][Math]::Round([double]$su), 0)
            $hrs   = [int][Math]::Max(((ConvertTo-UnixEpoch $sr) - $now) / 3600, 1)
            $score = [int]($rem * 1000 / $hrs)
        }

        $sfx = if ($isActive) { " (active)" } else { "" }
        Write-Host ("  Account {0} ({1}): {2}% session used, {3}% weekly left{4}" -f $n, $email, $f5p, $rem, $sfx)

        $prefer = (-not $best) -or ($score -gt $best.Score) -or
                  ($score -eq $best.Score -and $best.Num -eq $activeNum -and "$n" -ne $activeNum)
        if ($prefer) { $best = [PSCustomObject]@{ Num="$n"; Email=$email; Score=$score; Rem=$rem; Hrs=$hrs } }
    }

    if (-not $best) { Write-Host "No accounts with 5h capacity. Try after a reset."; exit 1 }
    if ($best.Num -eq $activeNum) {
        Write-Host ("Already on the best account — Account {0} ({1}), {2}% weekly left" -f $best.Num, $best.Email, $best.Rem)
        return
    }

    Write-Host ("Switching to Account {0} ({1}) — {2}% weekly left, resets in {3}" `
        -f $best.Num, $best.Email, $best.Rem, (Format-TimeRemaining ($best.Hrs * 3600)))
    Invoke-PerformSwitch $best.Num
}

function Invoke-Switch {
    if (-not (Test-Path $SequenceFile)) { Write-Host "Error: No accounts managed yet" -ForegroundColor Red; exit 1 }
    $email = Get-CurrentAccount
    if ($email -eq "none") { Write-Host "Error: No active Claude account" -ForegroundColor Red; exit 1 }

    if (-not (Test-AccountExists $email)) {
        Write-Host "Notice: Active account '$email' was not managed."
        Invoke-AddAccount
        $seq = Read-SequenceFile
        Write-Host "Added as Account-$($seq.activeAccountNumber). Run '--switch' again."
        return
    }

    $seq      = Read-SequenceFile
    $active   = $seq.activeAccountNumber
    $sequence = @($seq.sequence)

    $idx = 0
    for ($i = 0; $i -lt $sequence.Count; $i++) { if ($sequence[$i] -eq $active) { $idx = $i; break } }
    $next = "$($sequence[($idx + 1) % $sequence.Count])"
    Invoke-PerformSwitch $next
}

function Invoke-SwitchTo {
    param([string]$Identifier)
    if (-not $Identifier) { Write-Host "Usage: ccswitch --switch-to <num|email>"; exit 1 }
    if (-not (Test-Path $SequenceFile)) { Write-Host "Error: No accounts managed yet" -ForegroundColor Red; exit 1 }

    $target = Resolve-AccountIdentifier $Identifier
    if (-not $target) { Write-Host "Error: No account found: $Identifier" -ForegroundColor Red; exit 1 }
    $seq = Read-SequenceFile
    if (-not $seq.accounts.PSObject.Properties[$target]) {
        Write-Host "Error: Account-$target does not exist" -ForegroundColor Red; exit 1
    }
    Invoke-PerformSwitch $target
}

function Invoke-PerformSwitch {
    param([string]$Target)
    $seq           = Read-SequenceFile
    $currentNum    = "$($seq.activeAccountNumber)"
    $targetEmail   = $seq.accounts.PSObject.Properties[$Target].Value.email
    $currentEmail  = Get-CurrentAccount
    $configPath    = Get-ClaudeConfigPath

    # Backup current
    $curCreds  = Read-Credentials
    $curConfig = Get-Content $configPath -Raw
    Write-AccountCredentials -Num $currentNum  -Email $currentEmail -Creds $curCreds
    Write-AccountConfig      -Num $currentNum  -Email $currentEmail -Config $curConfig

    # Load target
    $tgtCreds  = Read-AccountCredentials -Num $Target -Email $targetEmail
    $tgtConfig = Read-AccountConfig      -Num $Target -Email $targetEmail
    if (-not $tgtCreds -or -not $tgtConfig) {
        Write-Host "Error: Missing backup data for Account-$Target" -ForegroundColor Red; exit 1
    }

    # Activate
    Write-Credentials -Creds $tgtCreds
    $tc = $tgtConfig | ConvertFrom-Json
    if (-not $tc.oauthAccount) { Write-Host "Error: Invalid oauthAccount in backup" -ForegroundColor Red; exit 1 }

    $cc = $curConfig | ConvertFrom-Json
    $cc.oauthAccount = $tc.oauthAccount
    Write-JsonSafe -Path $configPath -Content $cc

    # Update state
    $seq.activeAccountNumber = [int]$Target
    $seq.lastUpdated         = Get-UtcNow
    Write-SequenceFile $seq

    Write-Host "Switched to Account-$Target ($targetEmail)"
    Invoke-List
    Write-Host ""
    Write-Host "Please restart Claude Code to use the new authentication."
    Write-Host ""
}

function Show-Help {
    Write-Host "Multi-Account Switcher for Claude Code"
    Write-Host "Usage: ccswitch [COMMAND]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  --add-account                   Add current account to managed accounts"
    Write-Host "  --remove-account <num|email>   Remove account by number or email"
    Write-Host "  --list                          List all managed accounts"
    Write-Host "  --usage                         Show usage stats for all managed accounts"
    Write-Host "  --switch-best                   Switch to best account with 5h session capacity"
    Write-Host "  --switch                        Rotate to next account in sequence"
    Write-Host "  --switch-to <num|email>         Switch to specific account"
    Write-Host "  --help                          Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  ccswitch --add-account"
    Write-Host "  ccswitch --list"
    Write-Host "  ccswitch --switch"
    Write-Host "  ccswitch --switch-to 2"
    Write-Host "  ccswitch --switch-to user@example.com"
    Write-Host "  ccswitch --remove-account user@example.com"
}

# ── Main ──────────────────────────────────────────────────────────────────────
# No param() block: $args receives raw strings, so --switch-to passes through unchanged.
$cmd = if ($args.Count -ge 1) { $args[0] } else { "" }
$id  = if ($args.Count -ge 2) { $args[1] } else { "" }

switch ($cmd) {
    "--add-account"    { Invoke-AddAccount }
    "--remove-account" { Invoke-RemoveAccount $id }
    "--list"           { Invoke-List }
    "--usage"          { Invoke-Usage }
    "--switch-best"    { Invoke-SwitchBest }
    "--switch"         { Invoke-Switch }
    "--switch-to"      { Invoke-SwitchTo $id }
    "--help"           { Show-Help }
    ""                 { Show-Help }
    default            { Write-Host "Error: Unknown command '$cmd'" -ForegroundColor Red; Show-Help; exit 1 }
}
