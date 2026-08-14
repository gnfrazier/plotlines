<#
    SPIKE-00 measurement pass — Windows.

    Runs the lifecycle harness against every build and writes one JSON per target
    into results/, mirroring what the Linux run produced. Two things it does that a
    bare harness invocation does not, both of which turned out to matter on Windows:

      * measures FIRST launch separately, from a freshly copied tree. Windows
        Defender scans each newly written binary once and caches the verdict, so the
        launch a user actually sees after install is several seconds slower than
        every launch after it. Averaging the two hides the only number onboarding
        cares about.
      * refuses to run while another build is hogging the machine, because cold
        start here is dominated by process spawn and DLL loading.

    Usage:  .\spikes\SPIKE-00\harness\run_matrix.ps1 [-Runs 5]
#>
param([int]$Runs = 5)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1's `Out-File -Encoding utf8` writes a BOM, which makes the
# JSON below unreadable by any strict parser (including Python's json.load) — so the
# results files would be usable only on the machine that produced them. Write UTF-8
# without a BOM explicitly.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Json($Path, $Lines) {
    [System.IO.File]::WriteAllText(
        (Join-Path (Get-Location) $Path), ($Lines -join "`n") + "`n", $Utf8NoBom)
}
$root = Resolve-Path "$PSScriptRoot\..\..\.."
Set-Location $root

$py      = ".\.venv\Scripts\python.exe"
$harness = "spikes\SPIKE-00\harness\lifecycle.py"
$cache   = "spikes\SPIKE-00\cache"
$results = "spikes\SPIKE-00\results"

$targets = [ordered]@{
    'source'             = @($py, '-m', 'plotlines_service')
    'pyinstaller-onedir' = @("packaging\dist\pyinstaller-onedir\plotlines-sidecar\plotlines-sidecar.exe")
    'pyinstaller-onefile'= @("packaging\dist\pyinstaller-onefile\plotlines-sidecar.exe")
    'nuitka'             = @("packaging\dist\nuitka\plotlines-sidecar.exe")
}

foreach ($name in $targets.Keys) {
    $cmd = $targets[$name]
    if ($cmd.Count -eq 1 -and -not (Test-Path $cmd[0])) {
        Write-Host "skip $name (not built)" -ForegroundColor DarkGray
        continue
    }

    # First-launch measurement: copy to a path Defender has never scanned. The copy
    # leaves the page cache warm, so what this isolates is scan cost, not disk I/O.
    if ($cmd.Count -eq 1) {
        $fresh = Join-Path $env:TEMP ("plsc-first-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $srcItem = Get-Item $cmd[0]
        if ($name -eq 'pyinstaller-onefile') {
            New-Item -ItemType Directory -Path $fresh | Out-Null
            Copy-Item $srcItem.FullName $fresh
        } else {
            Copy-Item -Recurse $srcItem.Directory.FullName $fresh
        }
        $freshExe = Join-Path $fresh $srcItem.Name
        Write-Host "[$name] first launch (unscanned copy)…" -ForegroundColor Cyan
        $out = & $py $harness --cache-dir $cache --label "$name-first-launch" --runs 1 -- $freshExe
        Write-Json "$results\windows-$name-first-launch.json" $out
        Remove-Item -Recurse -Force $fresh -ErrorAction SilentlyContinue
    }

    Write-Host "[$name] steady state ($Runs runs)…" -ForegroundColor Cyan
    $out = & $py $harness --cache-dir $cache --label $name --runs $Runs -- @cmd
    Write-Json "$results\windows-$name.json" $out
    if ($LASTEXITCODE -ne 0) { Write-Host "  FAILED (harness exit $LASTEXITCODE)" -ForegroundColor Red }
}

Write-Host "`nSummary" -ForegroundColor Green
Get-ChildItem "$results\windows-*.json" | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $r = $j.runs[0]
    [PSCustomObject]@{
        Target   = $j.label
        Passed   = $j.passed
        ColdMed  = if ($j.cold_start_median_s) { $j.cold_start_median_s } else { $r.cold_start_to_ready_s }
        Route_m  = $r.segment.distance_m
        Nodes    = $r.segment.node_count
        Shutdown = $r.shutdown
        Orphans  = $r.orphans
    }
} | Format-Table -AutoSize
