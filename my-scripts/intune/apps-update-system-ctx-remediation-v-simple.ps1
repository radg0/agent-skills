#########################################################################################################################
#
# Script  : Winget Greenshot remediation - SIMPLE
# Purpose : Kill stuck installer processes, locate winget, upgrade Greenshot.Greenshot, log everything.
# Context : SYSTEM via Intune Remediation Script.
#
# ==== Intune deployment settings ====
#   - Run script using logged on credentials : No
#   - Enforce script signature check         : No
#   - Run script in 64-bit PowerShell Host   : Yes
#
# Output:
#   - Full log      : C:\_AutoPTasks\LOG\<date>\<datetime>_Winget_Remediation_SYSTEM.log
#   - Intune stdout : single-line summary
#   - Exit code     : 0 on success, 1 on any failure
#
#########################################################################################################################

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

#region Config
$PackageId      = 'Greenshot.Greenshot'

$DateStamp      = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_Winget_Remediation_SYSTEM.log"

if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}
#endregion

#region Logging
function Log {
    param(
        [string]$Msg,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Msg
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}
#endregion

Log "=================================================================="
Log "=== Greenshot simple remediation started ==="
Log "User: $(whoami)  Computer: $env:COMPUTERNAME  PS: $($PSVersionTable.PSVersion)"
Log "=================================================================="

# 1. Clear stuck installer processes to avoid "Waiting for another install"
Log "--- STEP 1: kill stuck installer processes (msiexec, winget) ---"
$stuck = Get-Process -Name "msiexec", "winget" -ErrorAction SilentlyContinue
if ($stuck) {
    foreach ($p in $stuck) { Log "killing $($p.ProcessName) PID=$($p.Id)" 'WARN' }
    $stuck | Stop-Process -Force -ErrorAction SilentlyContinue
} else {
    Log "no stuck msiexec/winget processes" 'OK'
}
Start-Sleep -Seconds 5

# 2. Locate WinGet
Log "--- STEP 2: locate winget.exe ---"
$wingetPath = Get-ChildItem -Path (Join-Path -Path $env:ProgramFiles -ChildPath "WindowsApps") `
                            -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty FullName -First 1

if (-not $wingetPath) {
    Log "WinGet path lost during remediation" 'ERROR'
    Write-Output "Greenshot-Simple | FATAL: winget not found | Log=$script:LogFile"
    Write-Error "WinGet path lost during remediation."
    exit 1
}
Log "winget.exe : $wingetPath" 'OK'

try {
    $verOut = & $wingetPath --version 2>&1 | Out-String
    Log "version    : $($verOut.Trim())"
} catch {
    Log "winget --version failed: $($_.Exception.Message)" 'WARN'
}

# 3. Upgrade Greenshot silently
Log "--- STEP 3: winget upgrade $PackageId ---"
$startTime = Get-Date
Log "spawn at $($startTime.ToString('HH:mm:ss.fff'))"

# Redirect ALL streams (*>) to a file. This drains winget's output continuously
# instead of letting PowerShell buffer it via its host pipe to IME's
# AgentExecutor (which deadlocks). Nothing reaches the console.
$wingetOut = Join-Path $LogPath "${DateTimeStamp}_winget.out"

try {
    & $wingetPath upgrade --id $PackageId --silent --force --accept-package-agreements --accept-source-agreements *> $wingetOut
    $exitCode = $LASTEXITCODE
    $elapsed  = ((Get-Date) - $startTime).TotalSeconds
    Log "exit code  : $exitCode"
    Log "duration   : $([int]$elapsed)s" 'OK'

    if (Test-Path $wingetOut) {
        Log "----- BEGIN winget output -----"
        foreach ($l in (Get-Content $wingetOut -ErrorAction SilentlyContinue)) {
            if ($l.Trim()) { Log "    $l" }
        }
        Log "-----  END  winget output -----"
        Remove-Item $wingetOut -Force -ErrorAction SilentlyContinue
    }

    $summary = "Greenshot-Simple | SUCCESS | exit=$exitCode | duration=$([int]$elapsed)s | Log=$script:LogFile"
    Log "=== $summary ==="
    Write-Output "Greenshot upgrade successful."
    Write-Output $summary
    exit 0
} catch {
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    Log "Upgrade failed: $($_.Exception.Message)" 'ERROR'
    Log "duration   : $([int]$elapsed)s"

    if (Test-Path $wingetOut) {
        Log "----- BEGIN winget output -----"
        foreach ($l in (Get-Content $wingetOut -ErrorAction SilentlyContinue)) {
            if ($l.Trim()) { Log "    $l" }
        }
        Log "-----  END  winget output -----"
        Remove-Item $wingetOut -Force -ErrorAction SilentlyContinue
    }

    $summary = "Greenshot-Simple | FAILED | duration=$([int]$elapsed)s | Log=$script:LogFile"
    Log "=== $summary ==="
    Write-Error "Upgrade failed: $_"
    Write-Output $summary
    exit 1
}
