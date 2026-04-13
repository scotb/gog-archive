
param(
    [switch]$Download,
    [switch]$DownloadAll,
    [switch]$Repair,
    [switch]$ListAll,
    [switch]$Tty,
    [switch]$ShowAllOutput,
    [switch]$VerboseLog,
    [string]$GameName,
    [switch]$ExactMatch
)

$logFile = "gog-sync.log"

Set-Location "C:\gog-archive"

# Output relevant info for analysis
$mode = if ($ListAll) { 'ListAll' } elseif ($DownloadAll) { 'DownloadAll' } elseif ($Download) { 'Download' } elseif ($Repair) { 'Repair' } else { 'ListUpdated' }
$downloadDir = '/downloads'
$threads = '8'

$startTime    = Get-Date
$startTimeFmt = $startTime.ToString("MM/dd/yyyy HH:mm:ss")

$dockerArgs = @('run', '--rm')
if ($Tty) { $dockerArgs += '-t' }
$dockerArgs += 'gogrepo'

$lgogArgs = @('lgogdownloader')
if ($ListAll) {
    $lgogArgs += '--list'
} elseif ($DownloadAll) {
    $lgogArgs += '--download'
} elseif ($Download) {
    $lgogArgs += '--download'
    $lgogArgs += '--updated'
} elseif ($Repair) {
    $lgogArgs += '--repair'
    $lgogArgs += '--download'
} else {
    $lgogArgs += '--list'
    $lgogArgs += '--updated'
}
$gamePattern = $null
if ($GameName) {
    if ($ExactMatch) {
        $gamePattern = "^$GameName$"
    } else {
        $gamePattern = $GameName
    }
    $lgogArgs += '--game'
    $lgogArgs += $gamePattern
}
$lgogArgs += '--directory'; $lgogArgs += $downloadDir
$lgogArgs += '--threads'; $lgogArgs += $threads

$fullArgs = $dockerArgs + $lgogArgs

# Append a timestamped line to the log file
function Write-Log($line) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$ts] $line"
}

# Run header — only emit lines for active/non-default values
$headerLines = @("==== GOG Sync Run Start: $startTimeFmt ====", "Mode: $mode")
if ($GameName)      { $headerLines += "Game: $GameName$(if ($ExactMatch) { ' (exact)' })" }
if ($ShowAllOutput) { $headerLines += "ShowAllOutput: true" }
if ($VerboseLog)    { $headerLines += "VerboseLog: true" }
if ($Tty)           { $headerLines += "TTY: true" }
foreach ($line in $headerLines) {
    Write-Host $line
    Write-Log $line
}
Write-Log "Running command: docker-compose $($fullArgs -join ' ')"

$completeCount = 0
$errorCount    = 0
$warnCount     = 0
$lastTotalTime = [DateTime]::MinValue
$tuiBlock      = [System.Collections.Generic.List[string]]::new()

if ($ListAll -or ($lgogArgs -contains '--list')) {
    # List mode: show everything on console and log
    cmd /c "docker-compose $($fullArgs -join ' ')" |
        ForEach-Object {
            $line = $_ -replace '\x1B\[[0-9;?]*[A-Za-z]', ''
            if ($line -match 'Getting product data|Getting game names|Getting game info') { return }
            if ($line.Trim().Length -eq 0) { return }
            Write-Host $line
            Write-Log $line
        }
} elseif ($ShowAllOutput) {
    # Console: show all output after basic noise filtering
    # Log: same but TUI progress blocks (thread status + progress bars + Total lines) are excluded
    cmd /c "docker-compose $($fullArgs -join ' ')" |
        ForEach-Object {
            $line = $_ -replace '\x1B\[[0-9;?]*[A-Za-z]', ''
            if ($line -match 'Getting product data|Getting game names|Getting game info') { return }
            if ($line.Trim().Length -eq 0) { return }
            Write-Host $line
            $isTuiLine = ($line -match '^#[0-9]+\s') -or ($line -match '^\s*[0-9]+%\s') -or ($line -match '^Total:')
            if (-not $isTuiLine) { Write-Log $line }
            if ($line -match 'Download complete:|Repairing file:') { $completeCount++ }
            elseif ($line -imatch '\berror\b') { $errorCount++ }
            elseif ($line -imatch '\bwarning\b') { $warnCount++ }
        }
} else {
    # Default mode (--verbose-log also uses this path):
    # Console: file completions, throttled Total heartbeat (~30s), errors, warnings
    # Log: all output except TUI progress blocks, with timestamps
    cmd /c "docker-compose $($fullArgs -join ' ')" |
        ForEach-Object {
            $line = $_ -replace '\x1B\[[0-9;?]*[A-Za-z]', ''
            $line = $line -replace '\r', ''
            if ($line -match 'Getting product data|Getting game names|Getting game info') { return }
            if ($line.Trim().Length -eq 0) { return }
            $ts = "[$(Get-Date -Format 'HH:mm:ss')]"
            if ($line -match 'Download complete:|Repairing file:') {
                Write-Host "$ts $line"
                Add-Content -Path $logFile -Value $line
                $completeCount++
            } elseif ($line -match '^#0[\s:]') {
                # Start of a new TUI block — reset accumulator
                $tuiBlock.Clear(); $tuiBlock.Add($line) | Out-Null
            } elseif ($tuiBlock.Count -gt 0 -and $line -notmatch '^Total:') {
                # Inside a TUI block — accumulate thread header/progress lines
                $tuiBlock.Add($line) | Out-Null
            } elseif ($line -match '^Total:') {
                $now = Get-Date
                if (($now - $lastTotalTime).TotalSeconds -ge 30 -and $tuiBlock.Count -gt 0) {
                    Write-Host "$ts --- TUI Status Snapshot ---"
                    $tuiBlock | ForEach-Object { Write-Host $_ }
                    Write-Host $line
                    Write-Host "------------------"
                    $lastTotalTime = $now
                }
                $tuiBlock.Clear()
            } elseif ($line -imatch '\berror\b') {
                Write-Host "$ts [ERROR] $line"
                Write-Log "[ERROR] $line"
                $errorCount++
            } elseif ($line -imatch '\bwarning\b') {
                Write-Host "$ts [WARN] $line"
                Write-Log "[WARN] $line"
                $warnCount++
            }
        }
}

$endTime    = Get-Date
$elapsed    = $endTime - $startTime
$elapsedStr = $elapsed.ToString('hh\:mm\:ss\.fff')
$endTimeFmt = $endTime.ToString("MM/dd/yyyy HH:mm:ss")

$summaryLine = "==== Summary: $completeCount file(s) completed, $errorCount error(s), $warnCount warning(s) ===="
$endLine     = "==== GOG Sync Run End: $endTimeFmt (Elapsed: $elapsedStr) ===="
Write-Host $summaryLine; Write-Log $summaryLine
Write-Host $endLine;     Write-Log $endLine