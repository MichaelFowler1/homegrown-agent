# ponder-build.ps1 — the model generates, the SCRIPT commits.
# Fills autonomous-agents.md one placeholder at a time by calling Ollama directly.
# No Goose CLI, no command-line prompt passing -> no quoting bugs, guaranteed edits.
# Stop with Ctrl+C. Re-run any time; it resumes at the next empty section.

$ErrorActionPreference = "Stop"
$workdir  = "C:\Users\Micke\goose-test"
$doc      = Join-Path $workdir "autonomous-agents.md"
$journal  = Join-Path $workdir "build-journal.md"
$model    = "hermes3:8b"
$ollama   = "http://localhost:11434/api/generate"
$sleepSec = 5

function Get-Content-FromModel($label) {
    $prompt = @"
You are writing one section of a reference document titled "Autonomous Agents".
Write 2 to 4 clear, factual sentences for the section titled: "$label".
Output ONLY the sentences as plain prose. No heading, no bullets, no preamble,
no quotation marks, no "Sure" or "Here is". Just the content.
"@
    $body = @{ model = $model; prompt = $prompt; stream = $false;
               options = @{ temperature = 0.7 } } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri $ollama -Method Post -Body $body -ContentType "application/json"
    # tidy the model's text into one clean paragraph
    $t = $resp.response.Trim()
    $t = $t -replace '^"|"$', '' -replace "`r?`n+", ' ' -replace '\s{2,}', ' '
    return $t.Trim()
}

if (-not (Test-Path $journal)) { "# Build Journal`r`n" | Out-File $journal -Encoding utf8 }

for ($i = 1; $i -le 100; $i++) {
    $lines = Get-Content $doc
    # find the first line still holding a placeholder
    $idx = -1
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match 'to be written') { $idx = $k; break }
    }
    if ($idx -eq -1) {
        Write-Host "`nDocument complete — no placeholders left." -ForegroundColor Green
        break
    }

    $line = $lines[$idx]
    if ($line -match '^\s*-\s*(.+?)\s*_\(to be written\)_') {
        # a bullet item: "- Label _(to be written)_"
        $label   = $Matches[1].Trim()
        $content = Get-Content-FromModel $label
        $lines[$idx] = "- **${label}:** $content"
    } else {
        # a section body: placeholder sits under the nearest "## Heading"
        $label = "this section"
        for ($h = $idx; $h -ge 0; $h--) {
            if ($lines[$h] -match '^##\s+(.+)') { $label = $Matches[1].Trim(); break }
        }
        $content = Get-Content-FromModel $label
        $lines[$idx] = $content
    }

    Set-Content -Path $doc -Value $lines -Encoding utf8
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] filled: $label" -ForegroundColor Cyan
    Add-Content -Path $journal -Value ("", "## $ts  filled: $label", $content, "")

    Start-Sleep -Seconds $sleepSec
}
