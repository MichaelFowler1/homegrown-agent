# Copyright 2026 Michael Fowler
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# code-agent.ps1 — a self-improving coding loop.
# The model WRITES code; the script RUNS it and feeds the real error back so the
# model fixes its own mistakes. Generate-then-commit + interpreter-as-teacher.
#
# Guardrails:
#  - Works only inside .\agent-workspace
#  - Runs generated code with python -I (isolated) and an 8s timeout
#  - No web access in this version (added later as a gated step)
#  - NOTE: Python is not folder-sandboxed; keep the GOAL to compute-and-print only.
#
# Run with PowerShell 7:  pwsh -NoProfile -File C:\Users\Micke\goose-test\code-agent.ps1
# Stop with Ctrl+C.

$ErrorActionPreference = "Stop"
$root     = "C:\Users\Micke\goose-test"
$ws       = Join-Path $root "agent-workspace"
$target   = Join-Path $ws "agent.py"
$log      = Join-Path $ws "build-log.md"
$model    = "hermes3:8b"
$ollama   = "http://localhost:11434/api/generate"
$maxIters = 12
$timeoutMs = 8000

$GOAL = @"
Build a single Python file, agent.py, that implements a TINY autonomous agent.
Requirements:
- It has a goal (e.g. reach a target number by choosing +1/-1/x2 style steps).
- It loops: sense current state, decide an action, apply it, print a trace line.
- It STOPS when the goal is reached or after at most 30 steps (no infinite loops).
- It only computes and prints. NO file access, NO network, NO os/subprocess use.
- Runs on plain Python 3 with the standard library only.
"@

New-Item -ItemType Directory -Force -Path $ws | Out-Null
if (-not (Test-Path $log)) { "# Code Agent Build Log`r`n" | Out-File $log -Encoding utf8 }
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { Write-Host "Python not found on PATH." -ForegroundColor Red; exit 1 }

function Ask-Model($prompt) {
    $body = @{ model = $model; prompt = $prompt; stream = $false;
               options = @{ temperature = 0.4 } } | ConvertTo-Json -Depth 4
    $r = Invoke-RestMethod -Uri $ollama -Method Post -Body $body -ContentType "application/json"
    return $r.response
}

function Extract-Code($text) {
    # pull code out of a ```python ... ``` fence if present, else use as-is
    $m = [regex]::Match($text, '(?s)```(?:python)?\s*(.*?)```')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $text.Trim()
}

$lastRun = "(no run yet — this is the first version)"

for ($i = 1; $i -le $maxIters; $i++) {
    $existing = if (Test-Path $target) { Get-Content $target -Raw } else { "(file does not exist yet)" }

    $prompt = @"
You are a Python coding agent. GOAL:
$GOAL

Here is the CURRENT agent.py:
--- BEGIN CURRENT ---
$existing
--- END CURRENT ---

Result of running the current version:
--- BEGIN RUN OUTPUT ---
$lastRun
--- END RUN OUTPUT ---

If there is an error above, FIX it. If it runs but does not fully meet the goal,
improve it. Output the COMPLETE contents of the new agent.py and nothing else.
Wrap the code in a single ```python code block.
"@

    Write-Host "`n[$(Get-Date -Format HH:mm:ss)] --- iteration #$i : asking model ---" -ForegroundColor Cyan
    $reply = Ask-Model $prompt
    $code  = Extract-Code $reply
    if ([string]::IsNullOrWhiteSpace($code)) { Write-Host "empty reply, skipping" -Yellow; continue }
    Set-Content -Path $target -Value $code -Encoding utf8
    Write-Host "wrote agent.py ($([regex]::Matches($code,"`n").Count + 1) lines). Running..." -ForegroundColor DarkGray

    # run it, isolated, with a timeout
    $outF = Join-Path $ws "run_out.txt"; $errF = Join-Path $ws "run_err.txt"
    $proc = Start-Process -FilePath $py -ArgumentList "-I", $target `
              -WorkingDirectory $ws -NoNewWindow -PassThru `
              -RedirectStandardOutput $outF -RedirectStandardError $errF
    if (-not $proc.WaitForExit($timeoutMs)) {
        $proc.Kill(); $stdout = ""; $stderr = "TIMED OUT after $($timeoutMs/1000)s (likely an infinite loop)."
    } else {
        $stdout = (Get-Content $outF -Raw -ErrorAction SilentlyContinue)
        $stderr = (Get-Content $errF -Raw -ErrorAction SilentlyContinue)
    }
    $ok = [string]::IsNullOrWhiteSpace($stderr)
    $lastRun = "STDOUT:`n$stdout`n`nSTDERR:`n$stderr"

    $status = if ($ok) { "OK" } else { "ERROR" }
    Write-Host "run result: $status" -ForegroundColor ($(if($ok){"Green"}else{"Red"}))
    if ($stdout) { Write-Host ($stdout.Trim() | Select-Object -First 1) -ForegroundColor Gray }
    if ($stderr) { Write-Host $stderr.Trim() -ForegroundColor DarkYellow }

    Add-Content -Path $log -Value @("", "## iter $i  [$status]  $(Get-Date -Format HH:mm:ss)",
        "``````", ($stdout + $stderr).Trim(), "``````")

    if ($ok -and $stdout -match 'reached|goal|done|success') {
        Write-Host "`nLooks like it reached its goal. Stopping." -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 2
}
Write-Host "`nFinished. Final program: $target" -ForegroundColor Green
