# Copyright 2026 Michael Fowler
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# code-agent-sandboxed.ps1  (v3 — full shell, multi-language, persistent workspace)
#
# An autonomous agent that ponders, picks its OWN goal (any medium: program, game,
# story, music, image, data...), and WORKS BY WRITING A SHELL SCRIPT (run.sh) that the
# sandbox executes. That gives it a full shell + any language it installs. It builds in a
# PERSISTENT /project folder and saves finished creations to /out.
#
# It starts with minimal power and must ASK ITS CREATOR for more (network, pip packages,
# apt tools, time, memory) — each request pauses for your y/n in this terminal.
#
# SAFETY (unchanged even at max power):
#   - Everything runs in a throwaway container (docker run --rm) in WSL.
#   - Only /project and /out are writable on your host; nothing else is reachable.
#   - Resource caps (--memory --cpus --pids-limit). Network OFF until you grant it.
#
# Run in YOUR terminal (it prompts you):  pwsh -NoProfile -File <thisfile>
# Stop: Ctrl+C

$ErrorActionPreference = "Stop"
$root      = "C:\Users\Micke\goose-test"
$ws        = Join-Path $root "agent-workspace"
$target    = Join-Path $ws "run.sh"        # the shell script the agent writes each turn
$projectDir= Join-Path $ws "project"       # PERSISTENT working dir (mounted rw at /project)
$outDir    = Join-Path $ws "output"        # artifacts for the creator (mounted rw at /out)
$goalFile  = Join-Path $ws "goal.txt"
$log       = Join-Path $ws "build-log.md"
# --- MODEL PROVIDER: "groq" (free cloud 70B) or "ollama" (local 14B) ---
$provider  = "groq"
$groqUrl   = "https://api.groq.com/openai/v1/chat/completions"
$model     = "llama-3.3-70b-versatile"   # groq: llama-3.3-70b-versatile   | ollama: qwen2.5-coder:14b-instruct-q3_K_M
$fixerModel= "llama-3.3-70b-versatile"   # (same for both roles)
$stuckThreshold = 2
$ollama    = "http://localhost:11434/api/generate"
$image     = "python:3.12-slim"
$maxIters  = 20
# WSL-visible paths (Windows C: is /mnt/c inside WSL)
$wsRun     = "/mnt/c/Users/Micke/goose-test/agent-workspace/run.sh"
$wsProject = "/mnt/c/Users/Micke/goose-test/agent-workspace/project"
$wsOut     = "/mnt/c/Users/Micke/goose-test/agent-workspace/output"

# ---- grants: start minimal; the agent must ask YOU to raise these ----
$script:grantNetwork  = $false
$script:grantPip      = @()   # python pip packages
$script:grantApt      = @()   # system tools (nodejs, gcc, ...)
$script:grantTimeoutS = 60
$script:grantMem      = "512m"
$script:grantCpus     = "1"
# ---- rut detection ----
$script:lastErrSig = ""
$script:stuckCount = 0

New-Item -ItemType Directory -Force -Path $ws, $projectDir, $outDir | Out-Null
# guard: if a previous docker mount auto-created run.sh as a DIRECTORY, remove it
if ((Test-Path $target) -and (Get-Item $target).PSIsContainer) { Remove-Item $target -Recurse -Force }
if (-not (Test-Path $log)) { "# Autonomous Agent (v3) — Build Log`r`n" | Out-File $log -Encoding utf8 }

function Ask-Model($prompt, $mdl = $model, $temp = 0.6) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            if ($provider -eq "groq") {
                $key = $env:GROQ_API_KEY
                if (-not $key) { throw "GROQ_API_KEY is not set. Run  setx GROQ_API_KEY your-key  then open a NEW terminal." }
                $body = @{ model=$mdl; messages=@(@{ role="user"; content=$prompt }); temperature=$temp } | ConvertTo-Json -Depth 6
                $headers = @{ Authorization = "Bearer $key" }
                $r = Invoke-RestMethod -Uri $groqUrl -Method Post -Body $body -Headers $headers -ContentType "application/json"
                return $r.choices[0].message.content
            } else {
                $body = @{ model=$mdl; prompt=$prompt; stream=$false; options=@{temperature=$temp; num_ctx=4096} } | ConvertTo-Json -Depth 4
                return (Invoke-RestMethod -Uri $ollama -Method Post -Body $body -ContentType "application/json").response
            }
        } catch {
            $msg = "$($_.Exception.Message)"
            if ($msg -match '429|rate limit|Too Many|503' -and $attempt -lt 4) {
                $wait = $attempt * 12
                Write-Host "  (rate limited — waiting ${wait}s, attempt $attempt/3)" -ForegroundColor DarkGray
                Start-Sleep -Seconds $wait; continue
            }
            throw
        }
    }
}

function Sandbox-State {
    $net = if ($script:grantNetwork) { "ON" } else { "OFF (no internet)" }
    $pip = if ($script:grantPip.Count) { $script:grantPip -join ', ' } else { "none" }
    $apt = if ($script:grantApt.Count) { $script:grantApt -join ', ' } else { "none (only python3 + sh preinstalled)" }
    "network=$net | pip pkgs=$pip | system tools=$apt | time=$($script:grantTimeoutS)s | mem=$($script:grantMem) | /project persists, /out for artifacts"
}

function Apply-Grant($cap) {
    if     ($cap -match '^\s*package:\s*(.+)') { $p = ($Matches[1].Trim() -replace '[^a-zA-Z0-9_.+\-\[\]=<>]',''); if($p){$script:grantPip += $p; $script:grantNetwork = $true} }
    elseif ($cap -match '^\s*apt:\s*(.+)')     { $p = ($Matches[1].Trim() -replace '[^a-zA-Z0-9_.+\-]','');       if($p){$script:grantApt += $p; $script:grantNetwork = $true} }
    elseif ($cap -match 'network') { $script:grantNetwork = $true }
    elseif ($cap -match 'time')    { $script:grantTimeoutS = [Math]::Min($script:grantTimeoutS * 3, 600) }
    elseif ($cap -match 'memory')  { $script:grantMem = "2g" }
}

function Request-Power($existing, $lastRun) {
    $r = Ask-Model @"
You are an autonomous agent in a sandbox. CURRENT powers:
$(Sandbox-State)

Your goal: $GOAL
Result of last run: $lastRun

If — and only if — you need MORE POWER, reply with EXACTLY:
REQUEST: <one of: network | package:PYPI_NAME | apt:SYSTEM_TOOL | time | memory>
REASON: <one short sentence why>
(package: = a python pip library. apt: = a system tool/language like nodejs, gcc, ghc.)
Otherwise reply with exactly: NONE
"@
    if ($r -match '(?im)^\s*REQUEST:\s*(.+)$') {
        $cap = $Matches[1].Trim()
        $reason = if ($r -match '(?im)^\s*REASON:\s*(.+)$') { $Matches[1].Trim() } else { "(none given)" }
        Write-Host "`n==================== THE AGENT REQUESTS MORE POWER ====================" -ForegroundColor Yellow
        Write-Host "  wants : $cap"    -ForegroundColor Yellow
        Write-Host "  reason: $reason" -ForegroundColor Yellow
        Write-Host "  (granting network / a package / an apt tool lets its code reach the internet)" -ForegroundColor DarkYellow
        $ans = Read-Host "  Grant this? (y/n)"
        Add-Content $log @("", "### POWER REQUEST: $cap", "reason: $reason", "decision: $ans")
        if ($ans -match '^(y|yes)$') { Apply-Grant $cap; Write-Host "  >> GRANTED. Now: $(Sandbox-State)" -ForegroundColor Green; return "Creator GRANTED '$cap'. Powers now: $(Sandbox-State)" }
        else { Write-Host "  >> DENIED." -ForegroundColor Red; return "Creator DENIED '$cap'. Work within current powers." }
    }
    return $null
}

function Extract-Code($text) {
    # grab the first fenced block regardless of language tag (bash/sh/python/...)
    $m = [regex]::Match($text, '(?s)```(?:[a-zA-Z0-9_+\-]+)?\s*(.*?)```')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $m2 = [regex]::Match($text, '(?s)---\s*BEGIN[^\r\n]*---\s*(.*?)\s*---\s*END')
    if ($m2.Success) { return $m2.Groups[1].Value.Trim() }
    $lines = $text -split "`n" | Where-Object { $_ -notmatch "^\s*(Here'?s|Sure|Certainly|Below|This (is|script)|The (script|code))" -and $_ -notmatch '^\s*---\s*(BEGIN|END)' }
    ($lines -join "`n").Trim()
}

function Err-Signature($out) {
    $m = [regex]::Matches($out, '(?m)^\s*(\w*Error|Exception|command not found|.*not found).*$')
    if ($m.Count) { return $m[$m.Count - 1].Value.Trim() }
    $tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($tail) { return $tail.Trim() } else { return "" }
}

function Senior-Fix($goal, $code, $err) {
    Ask-Model @"
You are a SENIOR engineer rescuing a stuck autonomous agent. It has failed REPEATEDLY
with the SAME error and cannot escape.

GOAL: $goal

THE STUCK run.sh:
$code

THE ERROR IT KEEPS HITTING:
$err

Do NOT patch line by line. Diagnose the ROOT cause, then write a COMPLETELY FRESH,
MINIMAL, correct run.sh that achieves the goal the simplest possible way. It runs with
'sh' in a container: python3 and sh are available; other tools only if already installed;
no keyboard/stdin, no GUI; it MUST terminate; save any artifact to /out.
Output ONLY the run.sh in one ``````bash fenced block. No prose.
"@ $fixerModel
}

function Judge-Success($goal, $output) {
    (Ask-Model @"
You are a STRICT, skeptical reviewer. Judge whether the GOAL was FULLY achieved — not
partially, not "close enough". Be harsh. Default to NO.

GOAL: $goal

What the program produced (stdout + any files it wrote):
$output

Answer NO if ANY of these is true:
- the goal is only PARTIALLY met, or a simpler/trivial version was built instead
- it is a stub, placeholder, hardcoded stand-in, or demo rather than the real thing
- a KEY property of the goal is missing (e.g. goal says "interactive" but nothing is
  actually interactive; goal says "a game/world" but it's a tiny script that only prints
  data; goal says "plays music" but no real audio was produced)
- it merely produced "related data" without delivering the actual experience described
- there is any error, "not found", timeout, or empty/near-empty result
Only answer YES if a demanding user who asked for EXACTLY this goal would be fully
satisfied with what was produced.

Answer with exactly one word first — YES or NO — then ONE sentence; if NO, name
specifically what is missing.
"@ $model 0.2).Trim()
}

function Project-Listing {
    $items = Get-ChildItem -LiteralPath $projectDir -Recurse -File -EA SilentlyContinue | Select-Object -First 40
    if ($items) { ($items | ForEach-Object { $_.FullName.Replace($projectDir, '/project') -replace '\\','/' }) -join "`n" }
    else { "(empty)" }
}

function Out-Summary {
    # summarize artifacts in /out so a silent file-creation still counts as success
    $files = Get-ChildItem -LiteralPath $outDir -File -EA SilentlyContinue
    if (-not $files) { return @{ text = ""; count = 0 } }
    $sb = "Artifacts written to /out:`n"
    foreach ($f in $files) {
        $sb += "- $($f.Name) ($($f.Length) bytes)`n"
        if ($f.Extension -match '\.(txt|md|json|csv|html|py)$' -and $f.Length -lt 3000) {
            $sb += "  contents:`n" + (Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue) + "`n"
        }
    }
    return @{ text = $sb; count = $files.Count }
}

function Run-In-Container {
    $net = if ($script:grantNetwork) { "bridge" } else { "none" }
    $pre = ""
    if ($script:grantApt.Count -gt 0) { $pre += "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq " + ($script:grantApt -join ' ') + " >/dev/null 2>&1; " }
    if ($script:grantPip.Count -gt 0) { $pre += "pip install --quiet --disable-pip-version-check " + ($script:grantPip -join ' ') + " 2>&1; " }
    $inner = "$pre timeout $($script:grantTimeoutS) sh /run.sh"
    $wslArgs = @("-d","Ubuntu","--","docker","run","--rm",
                 "--network",$net,
                 "--memory=$($script:grantMem)","--cpus=$($script:grantCpus)","--pids-limit=256",
                 "--workdir","/project",
                 "-v","${wsRun}:/run.sh:ro",
                 "-v","${wsProject}:/project",
                 "-v","${wsOut}:/out",
                 $image,"sh","-lc",$inner)
    $out = & wsl @wslArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $errMarker = $out -match 'Traceback|Error:|Exception|EOF when reading|SyntaxError|command not found'
    $empty = [string]::IsNullOrWhiteSpace($out)
    $art = Out-Summary
    # success = clean exit, no error text, AND it produced SOMETHING (stdout OR an artifact file)
    $ok = ($code -eq 0) -and (-not $errMarker) -and ((-not $empty) -or ($art.count -gt 0))
    @{ ok = $ok; out = $out.Trim(); code = $code; artifacts = $art.text }
}

# ---------- let the agent PONDER and choose its own goal ----------
if (-not (Test-Path $goalFile)) {
    Write-Host "Letting the agent ponder and choose whatever it wants to create..." -ForegroundColor Cyan
    $g = (Ask-Model @"
You are an autonomous agent with TOTAL creative freedom. Ponder, then choose ONE thing
you genuinely want to CREATE. It can be ANYTHING — a game, a story, music, an image, an
animation, a dataset, a poem, an invented tool, a simulation, a puzzle, a tiny language.
The CREATION is the point, not that it is software. You work in a sandbox with a full
shell; python3 is preinstalled and you may install other languages/tools on request.
You save your creation as a file (.wav, .png, .txt, .html, .json...).

HARD RULE — these are BANNED, do NOT choose them or anything close: fractals / Mandelbrot
/ Julia, generative or abstract art, Conway's Game of Life or any cellular automaton,
mazes, particle / fish / flocking simulations, ASCII art. Pick something genuinely
DIFFERENT. Surprise me.

Reply with ONE sentence describing what you want to create. No preamble.
"@ $model 1.4).Trim()
    Set-Content $goalFile $g -Encoding utf8
    Write-Host "`n>>> THE AGENT CHOSE: $g`n" -ForegroundColor Green
    Add-Content $log @("", "## Self-chosen goal", $g)
}
$GOAL = Get-Content $goalFile -Raw

$lastRun = "(no run yet)"
for ($i = 1; $i -le $maxIters; $i++) {
    $existing = if (Test-Path $target) { Get-Content $target -Raw } else { "(no run.sh yet)" }

    # 1) the agent may ask the creator for more power (can pause for your y/n)
    $grantNote = Request-Power $existing $lastRun

    # 2) generate / revise the shell script that builds the creation
    if ($script:stuckCount -ge $stuckThreshold) {
        Write-Host "[$(Get-Date -Format HH:mm:ss)] iter #$i — WORKER STUCK ($($script:stuckCount)x). Calling SENIOR FIXER..." -ForegroundColor Yellow
        Add-Content $log @("", "### >>> SENIOR FIXER invoked after $($script:stuckCount)x: $($script:lastErrSig)")
        $code = Extract-Code (Senior-Fix $GOAL $existing $script:lastErrSig)
        $script:stuckCount = 0; $script:lastErrSig = ""
    } else {
        $prompt = @"
You are an autonomous agent. YOUR GOAL (you chose this): $GOAL

Your sandbox powers: $(Sandbox-State)
$grantNote

You work by writing a shell script (run.sh) that the sandbox runs with 'sh'. You have a
FULL SHELL: run python3 (preinstalled), write files into /project (PERSISTS between runs
— build on earlier work), and use other languages/tools ONLY if granted (ask via the
power step: apt:NAME for system tools like nodejs/gcc, package:NAME for python pip libs).
Save finished creations (image .png, audio .wav, text .txt, data .json, web .html) to /out.

Files currently in your persistent /project:
$(Project-Listing)

Your current run.sh:
$existing

Result of running it:
$lastRun

Write the COMPLETE new run.sh. Typical pattern — write a program then run it:
  cat > /project/main.py << 'PYEOF'
  print("hello")
  PYEOF
  python3 /project/main.py
RULES: runs UNATTENDED (no keyboard/stdin, no GUI/display/audio device — save files
instead). It MUST terminate (no infinite loops; cap any simulation at fixed steps). Use
only granted tools. COMPILED binaries (C, C++, Rust, Go...) must be built AND run from
/tmp, e.g. 'gcc src.c -o /tmp/app && /tmp/app' — /project has no exec permission (Python
and scripts run fine anywhere). Output ONLY the run.sh in one ``````bash fenced block. No prose.
"@
        Write-Host "[$(Get-Date -Format HH:mm:ss)] iter #$i — generating..." -ForegroundColor Cyan
        $code = Extract-Code (Ask-Model $prompt)
    }
    if ([string]::IsNullOrWhiteSpace($code)) { Write-Host "empty reply" -ForegroundColor Yellow; continue }
    # write run.sh with UNIX line endings (LF) and no BOM — the Linux shell chokes on CRLF (\r)
    $codeLF = ($code -replace "`r`n", "`n") -replace "`r", "`n"
    [System.IO.File]::WriteAllText($target, $codeLF, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "wrote run.sh — executing in container (network=$(if($script:grantNetwork){'ON'}else{'off'}))..." -ForegroundColor DarkGray

    $r = Run-In-Container
    if ($r.code -eq 124) {
        $lastRun = "TIMED OUT: ran past the $($script:grantTimeoutS)s limit and was KILLED — infinite loop, never finishes. It MUST terminate: cap it at a FIXED number of steps, print results, then stop."
    } else {
        $lastRun = "EXIT $($r.code):`n$($r.out)`n$($r.artifacts)"
    }
    Write-Host "result: $(if($r.ok){'OK'}elseif($r.code -eq 124){'TIMEOUT'}else{'ERR('+$r.code+')'})" -ForegroundColor ($(if($r.ok){"Green"}else{"Red"}))
    if ($r.out) { Write-Host ($r.out) -ForegroundColor Gray }
    Add-Content -Path $log -Value @("", "## iter $i [$(if($r.ok){'OK'}else{'ERR'})] $(Get-Date -Format HH:mm:ss)", '```', $r.out, '```')

    if ($r.ok) {
        $script:stuckCount = 0; $script:lastErrSig = ""
        $verdict = Judge-Success $GOAL ($r.out + "`n" + $r.artifacts)
        Write-Host "judge: $verdict" -ForegroundColor Magenta
        Add-Content $log @("_judge: $verdict_")
        if ($verdict -match '^\s*YES') { Write-Host "`nGoal achieved — stopping." -ForegroundColor Green; break }
        $lastRun = "Ran without crashing but goal NOT met.`nOutput:`n$($r.out)`n$($r.artifacts)`nJudge: $verdict"
    } else {
        $sig = if ($r.code -eq 124) { "TIMEOUT/infinite-loop" } else { Err-Signature $r.out }
        if ($sig -and $sig -eq $script:lastErrSig) { $script:stuckCount++ } else { $script:stuckCount = 1; $script:lastErrSig = $sig }
        Write-Host "  (same-error streak: $($script:stuckCount); fixer triggers at $stuckThreshold)" -ForegroundColor DarkYellow
    }
    Start-Sleep -Seconds 2
}
Write-Host "`nDone. Script: $target  |  Project: $projectDir  |  Artifacts: $outDir" -ForegroundColor Green
