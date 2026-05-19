# ccswitch.completion.ps1 - Tab completion for ccswitch
# Add to your $PROFILE:
#   . "C:\path\to\ccswitch.completion.ps1"

$_ccswitchSeqFile = Join-Path $HOME ".claude-switch-backup\sequence.json"

Register-ArgumentCompleter -Native -CommandName @('ccswitch', 'ccswitch.ps1', 'ccswitch.bat') -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $seqFile = Join-Path $HOME ".claude-switch-backup\sequence.json"
    $cmds = @('--add-account','--remove-account','--list','--usage',
              '--switch-best','--switch','--switch-to','--help','--install-completion')

    # Find the last fully-typed token before the current word
    $elements   = @($commandAst.CommandElements | Select-Object -Skip 1)
    $prevToken  = if ($elements.Count -ge 2) { $elements[-2].ToString() } elseif ($elements.Count -eq 1 -and $wordToComplete -eq '') { $elements[-1].ToString() } else { "" }

    $accountFlags = @('--switch-to', '--remove-account')
    if ($prevToken -in $accountFlags) {
        if (Test-Path $seqFile) {
            try {
                $seq = Get-Content $seqFile -Raw | ConvertFrom-Json
                foreach ($p in $seq.accounts.PSObject.Properties) {
                    $num   = $p.Name
                    $email = $p.Value.email
                    foreach ($val in @($num, $email)) {
                        if ($val -like "$wordToComplete*") {
                            [System.Management.Automation.CompletionResult]::new(
                                $val, "$num: $email", 'ParameterValue', $email)
                        }
                    }
                }
            } catch {}
        }
    } else {
        $cmds | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
    }
}
