<#
Intune Proactive — SAFE Remediation (no detection, always runs)
- Avoids hanging: timeouts around service actions and wsreset
- Cleans IME caches + Delivery Optimization cache
- Optional aggressive process kill and AppX re-register are disabled by default (safe)
- Logs to: C:\_AutoPTasks\Log-Remediation\Intune-Remediation-Clean-YYYY-MM-DD.log

Recommended Intune settings:
- Run in 64-bit PowerShell: Yes
- Run using logged-on credentials: Optional (SYSTEM is fine)
#>

$ErrorActionPreference = "Continue"

# -----------------------------
# Logging
# -----------------------------
$LogDir  = "C:\_AutoPTasks\Log-Remediation"
$DateStr = (Get-Date).ToString("yyyy-MM-dd")
$LogFile = Join-Path $LogDir ("Intune-Remediation-Clean-{0}.log" -f $DateStr)

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
    Write-Output $line
}

# -----------------------------
# Toggles (SAFE defaults)
# -----------------------------
$KillStuckInstallerProcesses = $true  # SAFE default: do not kill processes
$EnableHardResetAppX         = $true  # SAFE default: do not re-register AppX
$ClearDOAlways               = $true   # SAFE: clearing DO cache is usually harmless and effective
$ServiceActionTimeoutSeconds = 20
$WsResetTimeoutSeconds       = 25

# -----------------------------
# Helpers (timeouts)
# -----------------------------
function Invoke-WithTimeout {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
        [string]$Description = "Operation"
    )

    $job = $null
    try {
        $job = Start-Job -ScriptBlock $ScriptBlock
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Write-Log "$Description timed out after $TimeoutSeconds seconds." "WARN"
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            return $false
        }

        # Drain job output/errors (best effort)
        try { Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null } catch {}
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        return $true
    } catch {
        Write-Log ("$Description failed: {0}" -f $_.Exception.Message) "ERROR"
        try {
            if ($job) {
                Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {}
        return $false
    }
}

function Try-RestartServiceSafe {
    param(
        [Parameter(Mandatory=$true)][string]$Name
    )

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service not found: $Name" "WARN"
        return
    }

    Invoke-WithTimeout -TimeoutSeconds $ServiceActionTimeoutSeconds -Description "Restart service $Name" -ScriptBlock {
        param($svcName)
        Restart-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }.GetNewClosure() | Out-Null
}

function Safe-RemoveChildren {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Log "Path not found: $Path" "INFO"
        return
    }

    try {
        $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
        if ($items -and $items.Count -gt 0) {
            Write-Log "Cleaning folder: $Path (items: $($items.Count))" "INFO"
            $items | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned: $Path" "INFO"
        } else {
            Write-Log "No files found in: $Path" "INFO"
        }
    } catch {
        Write-Log ("Failed to clean {0}: {1}" -f $Path, $_.Exception.Message) "ERROR"
    }
}

# -----------------------------
# Start
# -----------------------------
Write-Log "=== START SAFE Remediation: IME + Store/DO cleanup ===" "INFO"
Write-Log ("Running as: {0}\{1} | PowerShell: {2}" -f $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion) "INFO"

# -----------------------------
# 1) Restart key services (safe with timeout)
# -----------------------------
$services = @(
    "IntuneManagementExtension",  # IME
    "DoSvc",                      # Delivery Optimization
    "AppXSvc",                    # AppX Deployment
    "ClipSVC"                     # Store licensing
)

foreach ($s in $services) {
    Write-Log "Attempting service restart: $s" "INFO"
    Try-RestartServiceSafe -Name $s
}

# -----------------------------
# 2) Optional: kill stuck installer processes (disabled by default)
# -----------------------------
if ($KillStuckInstallerProcesses) {
    Write-Log "Aggressive mode enabled: stopping potentially stuck processes." "WARN"
    $procs = @("AppInstaller","WinStore.App","Microsoft.StorePurchaseApp","wsappx")
    foreach ($p in $procs) {
        try {
            Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log "Stopped process (if running): $p" "INFO"
        } catch {
            Write-Log ("Failed stopping process {0}: {1}" -f $p, $_.Exception.Message) "WARN"
        }
    }
} else {
    Write-Log "Process kill disabled (safe default)." "INFO"
}

# -----------------------------
# 3) Clean IME caches
# -----------------------------
Write-Log "Cleaning IME caches..." "INFO"

$imeTargets = @(
    "C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Incoming",
    "C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Staging",
    "C:\Windows\IMECache"
)

foreach ($p in $imeTargets) {
    Safe-RemoveChildren -Path $p
}

# -----------------------------
# 4) Clean Delivery Optimization cache (safe)
# -----------------------------
$doCache = "C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache"
Write-Log "Cleaning Delivery Optimization cache..." "INFO"

Invoke-WithTimeout -TimeoutSeconds 25 -Description "DO cache cleanup" -ScriptBlock {
    param($cachePath, $clearAlways)

    # Stop service to release locks
    Stop-Service -Name DoSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (Test-Path $cachePath) {
        if ($clearAlways) {
            Get-ChildItem -Path $cachePath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Service -Name DoSvc -ErrorAction SilentlyContinue
}.GetNewClosure() | Out-Null

if (Test-Path $doCache) {
    Write-Log "DO cache cleanup attempted: $doCache" "INFO"
} else {
    Write-Log "DO cache path not found: $doCache" "INFO"
}

# -----------------------------
# 5) wsreset (best effort, with timeout)
# -----------------------------
$wsreset = "$env:windir\System32\wsreset.exe"
if (Test-Path $wsreset) {
    Write-Log "Running wsreset.exe (best effort)..." "INFO"

    Invoke-WithTimeout -TimeoutSeconds $WsResetTimeoutSeconds -Description "wsreset" -ScriptBlock {
        param($exePath)
        # /quiet is not always honored on all builds; keep it but don't rely on it
        Start-Process -FilePath $exePath -ArgumentList "/quiet" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
    }.GetNewClosure() | Out-Null

    Write-Log "wsreset attempted." "INFO"
} else {
    Write-Log "wsreset.exe not found." "WARN"
}

# -----------------------------
# 6) Optional: Hard reset AppX (disabled by default)
# -----------------------------
if ($EnableHardResetAppX) {
    Write-Log "Hard reset AppX enabled (heavier). Re-registering Store/AppInstaller/CompanyPortal..." "WARN"

    $packages = @("Microsoft.WindowsStore","Microsoft.DesktopAppInstaller","Microsoft.CompanyPortal")

    Invoke-WithTimeout -TimeoutSeconds 60 -Description "AppX re-register" -ScriptBlock {
        param($pkgList)
        foreach ($pkg in $pkgList) {
            $pkgs = Get-AppxPackage -AllUsers -Name $pkg -ErrorAction SilentlyContinue
            if ($pkgs) {
                foreach ($p in $pkgs) {
                    if ($p.InstallLocation) {
                        $manifest = Join-Path $p.InstallLocation "AppxManifest.xml"
                        if (Test-Path $manifest) {
                            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        }
    }.GetNewClosure() | Out-Null

    Write-Log "Hard reset AppX attempted." "INFO"
} else {
    Write-Log "Hard reset AppX disabled (safe default)." "INFO"
}

# -----------------------------
# 7) Final IME restart to trigger re-evaluation (safe)
# -----------------------------
Write-Log "Final restart of IntuneManagementExtension (to trigger re-evaluation)..." "INFO"
Try-RestartServiceSafe -Name "IntuneManagementExtension"

Write-Log "=== END Remediation. Next: user Sync in Company Portal + retry install. ===" "INFO"
Write-Log ("Log file: {0}" -f $LogFile) "INFO"

exit 0
