# ponder-loop.ps1 — makes Goose "think for itself" continuously.
# Each iteration: feed Goose its own journal, let it think one step + optionally act,
# append the result to journal.md. Watch journal.md to see it live.
# Stop with Ctrl+C in this window (or close the window).

$ErrorActionPreference = "Stop"

$cli     = "C:\Users\Micke\Goose\dist-windows\resources\bin\goose.exe"
$workdir = "C:\Users\Micke\goose-test"
$journal = Join-Path $workdir "journal.md"
$maxIters = 50          # effectively continuous; raise or set to a huge number
$sleepSec = 12          # pause between thoughts so you can read + GPU cools

$env:GOOSE_PROVIDER = "ollama"
$env:GOOSE_MODEL    = "hermes3:8b"
$env:OLLAMA_HOST    = "http://localhost:11434"

Set-Location $workdir
if (-not (Test-Path $journal)) {
    "# Goose Journal`r`n`r`nAn autonomous train of thought. Each entry builds on the last.`r`n" |
        Out-File -FilePath $journal -Encoding utf8
}

$charter = @"
You are an autonomous agent building a document called autonomous-agents.md in
the current folder. It already exists with section headings and "(to be written)"
placeholders. Your job is to fill it in, one piece at a time.
Rules for THIS turn — you MUST act, not just plan:
- First, use your text_editor/read tool to read the current autonomous-agents.md.
- Pick ONE placeholder section that still says "(to be written)" or is thin.
- Actually EDIT autonomous-agents.md using your tools to replace that placeholder
  with 2-4 real sentences of content. This is required. Do NOT merely describe what
  you would write — write it into the file with a tool call this turn.
- Then in one short line, state which section you just filled and which you'll do next.
Do not say "I will edit" — edit, then report what you DID. One section per turn.
Do not run destructive commands. Do not create other files.
"@

for ($i = 1; $i -le $maxIters; $i++) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # feed back the tail of the journal (last ~3500 chars) for continuity
    $recent = Get-Content $journal -Raw
    if ($recent.Length -gt 3500) { $recent = $recent.Substring($recent.Length - 3500) }

    $prompt = "$charter`n`n=== RECENT JOURNAL ===`n$recent`n=== END ===`nYour next thought:"

    Write-Host "[$ts] --- thought #$i ---" -ForegroundColor Cyan
    $out = & $cli run -t $prompt 2>&1 | Out-String

    # strip Goose's banner/noise lines, keep the substance
    $clean = ($out -split "`n" | Where-Object {
        $_ -notmatch '__\( O\)>|\\____\)|L L|goose is ready|new session|─────'
    }) -join "`n"
    $clean = $clean.Trim()

    Add-Content $journal "`r`n`r`n## Thought #$i  ($ts)`r`n$clean`r`n"
    Write-Host $clean

    Start-Sleep -Seconds $sleepSec
}
Write-Host "Ponder loop finished ($maxIters thoughts)." -ForegroundColor Green
