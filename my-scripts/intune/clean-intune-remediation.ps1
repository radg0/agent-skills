<#
Intune Proactive — AGGRESSIVE Remediation (no detection, always runs)
- Avoids hanging: timeouts around service actions and wsreset
- Cleans IME caches + Delivery Optimization caches (both DO locations)
- Bounces wuauserv / BITS / DoSvc around the WU+DO cache wipe
- Optional: wipes C:\Windows\SoftwareDistribution\Download (WU-reset, off by default)
- Aggressive process kill and AppX re-register are ENABLED by default
  (set $KillStuckInstallerProcesses / $EnableHardResetAppX to $false for safe mode)
- Structured log:  C:\_AutoPTasks\Log-Remediation\Intune-Remediation-Clean-YYYY-MM-DD.log
- Transcript:     C:\_AutoPTasks\Log-Remediation\Intune-Remediation-Transcript-YYYY-MM-DD.log
- Intune stdout: one single summary line (portal truncates at 2048 chars)

Recommended Intune settings:
- Run in 64-bit PowerShell: Yes
- Run using logged-on credentials: Optional (SYSTEM is fine)

SYSTEM context (intentional - do not flag in reviews):
- This script is deployed as NT AUTHORITY\SYSTEM via Intune Proactive Remediations.
- wsreset.exe and Add-AppxPackage -Register have limited per-user effect when
  invoked from SYSTEM (they touch the SYSTEM profile / provisioned packages,
  not the logged-on user's AppX hive). This is accepted by design.
- This script handles system-side plumbing (IME caches, DO cache, services,
  provisioned registrations). User-side recovery is completed by the end user
  running Company Portal -> Sync + retry install.
- When run BY IME (deployed remediation), restarting IntuneManagementExtension
  breaks the result-reporting callback and the portal action stays Pending.
  We detect the parent process and skip IME restarts in that case.
#>

$ErrorActionPreference = "Continue"

# -----------------------------
# Logging
# -----------------------------
$LogDir         = "C:\_AutoPTasks\Log-Remediation"
$DateStr        = (Get-Date).ToString("yyyy-MM-dd")
$LogFile        = Join-Path $LogDir ("Intune-Remediation-Clean-{0}.log"      -f $DateStr)
$TranscriptFile = Join-Path $LogDir ("Intune-Remediation-Transcript-{0}.log" -f $DateStr)

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# Transcript captures cmdlet errors/warnings/verbose that Write-Log would miss.
# Intune only sees stdout (first 2048 chars), so we do NOT echo Write-Log lines there.
try { Start-Transcript -Path $TranscriptFile -Append -Force | Out-Null } catch {}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# -----------------------------
# Toggles (AGGRESSIVE defaults - flip to $false for safe mode)
# -----------------------------
$KillStuckInstallerProcesses = $true   # AGGRESSIVE: kill Store/AppX processes (may disrupt in-flight installs)
$EnableHardResetAppX         = $true   # AGGRESSIVE: re-register Store/AppInstaller/CompanyPortal
$ClearDOAlways               = $true   # SAFE: clearing DO caches is usually harmless and effective
$ClearWUDownloadCache        = $false  # HEAVIER: also wipe C:\Windows\SoftwareDistribution\Download (WU-reset)
$ServiceActionTimeoutSeconds = 20
$WsResetTimeoutSeconds       = 25
$WUDOCleanupTimeoutSeconds   = 90      # wuauserv stop can be slow when WU has pending transactions

# -----------------------------
# Helpers (timeouts)
# -----------------------------
function Invoke-WithTimeout {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
        [string]$Description = "Operation",
        # Start-Job runs in a separate PowerShell process: variables from the
        # caller's scope are NOT visible inside $ScriptBlock (closures don't
        # survive the process boundary). All inputs MUST be passed explicitly.
        [object[]]$ArgumentList = @(),
        # Process names to kill if the job times out. Stop-Job does not
        # reliably kill grandchildren (e.g. wsreset.exe launched via
        # Start-Process -Wait), so we clean them up here to avoid orphans.
        [string[]]$OrphanProcessNames = @()
    )

    $job = $null
    try {
        $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Write-Log "$Description timed out after $TimeoutSeconds seconds." "WARN"
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null

            foreach ($pn in $OrphanProcessNames) {
                try {
                    $orphans = Get-Process -Name $pn -ErrorAction SilentlyContinue
                    if ($orphans) {
                        $orphans | Stop-Process -Force -ErrorAction SilentlyContinue
                        Write-Log "Killed orphan process after timeout: $pn" "WARN"
                    }
                } catch {}
            }
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

    Invoke-WithTimeout `
        -TimeoutSeconds $ServiceActionTimeoutSeconds `
        -Description "Restart service $Name" `
        -ArgumentList $Name `
        -ScriptBlock {
            param($svcName)
            Restart-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        } | Out-Null
}

function Test-RunningUnderIME {
    # Returns $true when the script is executed by the Intune Management
    # Extension (via AgentExecutor.exe). In that context, restarting the
    # IntuneManagementExtension service kills the result-reporting callback:
    # the portal action stays "Pending" forever even though the script
    # completed successfully. Callers should skip IME restarts in that case.
    # When launched via PsExec / manually, the parent is powershell/cmd/PsExec
    # and restarting IME is fine (and desirable for full cleanup).
    try {
        $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
        if (-not $parentId) { return $false }
        $parentName = (Get-Process -Id $parentId -ErrorAction SilentlyContinue).Name
        return @("AgentExecutor","IntuneManagementExtension") -contains $parentName
    } catch {
        return $false
    }
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
$mode = if ($KillStuckInstallerProcesses -or $EnableHardResetAppX) { "AGGRESSIVE" } else { "SAFE" }
Write-Log ("=== START {0} Remediation: IME + Store/DO cleanup ===" -f $mode) "INFO"
Write-Log ("Running as: {0}\{1} | PowerShell: {2}" -f $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion) "INFO"

$UnderIME = Test-RunningUnderIME
if ($UnderIME) {
    Write-Log "Parent process is IME/AgentExecutor -> IntuneManagementExtension restarts will be SKIPPED (avoids breaking the portal result callback)." "WARN"
} else {
    Write-Log "Parent process is not IME -> IntuneManagementExtension will be restarted as usual." "INFO"
}

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
    if ($UnderIME -and $s -eq "IntuneManagementExtension") {
        Write-Log "Skipping restart of $s (running under IME - would break result callback)." "INFO"
        continue
    }
    Write-Log "Attempting service restart: $s" "INFO"
    Try-RestartServiceSafe -Name $s
}

# -----------------------------
# 2) Kill stuck installer processes (enabled by default, gated by toggle)
# -----------------------------
if ($KillStuckInstallerProcesses) {
    Write-Log "Aggressive mode enabled: stopping potentially stuck processes." "WARN"
    # Do NOT include "wsappx" here: it hosts AppXSvc and ClipSVC, and killing
    # it can corrupt the AppX deployment queue for any install in flight. The
    # AppXSvc restart earlier in this script is the safer way to bounce it.
    $procs = @("AppInstaller","WinStore.App","Microsoft.StorePurchaseApp")
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
# 4) Clean Delivery Optimization + Windows Update caches
# -----------------------------
# Two DO cache locations exist depending on who initiated the download:
#   - ProgramData\...\DeliveryOptimization\Cache  -> generic DO (Store, Intune Win32 via DO)
#   - SoftwareDistribution\DeliveryOptimization\Cache -> DO for wuauserv-initiated downloads
# We clean BOTH and bounce wuauserv/BITS/DoSvc together, matching the manual
# procedure that unblocks Company Portal installs on real endpoints.
$doCacheProgramData = "C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache"
$doCacheWU          = "C:\Windows\SoftwareDistribution\DeliveryOptimization\Cache"
$wuDownload         = "C:\Windows\SoftwareDistribution\Download"

Write-Log "Cleaning WU + DO caches (bouncing wuauserv / BITS / DoSvc)..." "INFO"

Invoke-WithTimeout `
    -TimeoutSeconds $WUDOCleanupTimeoutSeconds `
    -Description "WU + DO cache cleanup" `
    -ArgumentList @($doCacheProgramData, $doCacheWU, $wuDownload, $ClearDOAlways, $ClearWUDownloadCache) `
    -ScriptBlock {
        param($doPath1, $doPath2, $wuDownloadPath, $clearDO, $clearWU)

        # Stop order: wuauserv first (it drives BITS/DoSvc for updates), then
        # the transports. Reverse order on restart so dependencies are up
        # before dependents try to bind.
        foreach ($s in "wuauserv","BITS","DoSvc") {
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2

        if ($clearDO) {
            foreach ($p in @($doPath1, $doPath2)) {
                if (Test-Path $p) {
                    Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if ($clearWU -and (Test-Path $wuDownloadPath)) {
            Get-ChildItem -Path $wuDownloadPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        foreach ($s in "DoSvc","BITS","wuauserv") {
            Start-Service -Name $s -ErrorAction SilentlyContinue
        }
    } | Out-Null

foreach ($p in @($doCacheProgramData, $doCacheWU)) {
    if (Test-Path $p) {
        Write-Log "DO cache cleanup attempted: $p" "INFO"
    } else {
        Write-Log "DO cache path not found: $p" "INFO"
    }
}
if ($ClearWUDownloadCache) {
    Write-Log "WU Download folder cleanup attempted: $wuDownload" "INFO"
} else {
    Write-Log "WU Download folder preserved (toggle off)." "INFO"
}

# -----------------------------
# 5) wsreset (best effort, with timeout)
# -----------------------------
$wsreset = "$env:windir\System32\wsreset.exe"
if (Test-Path $wsreset) {
    Write-Log "Running wsreset.exe (best effort)..." "INFO"

    Invoke-WithTimeout `
        -TimeoutSeconds $WsResetTimeoutSeconds `
        -Description "wsreset" `
        -ArgumentList $wsreset `
        -OrphanProcessNames @("wsreset") `
        -ScriptBlock {
            param($exePath)
            # /quiet is not always honored on all builds; keep it but don't rely on it
            Start-Process -FilePath $exePath -ArgumentList "/quiet" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        } | Out-Null

    Write-Log "wsreset attempted." "INFO"
} else {
    Write-Log "wsreset.exe not found." "WARN"
}

# -----------------------------
# 6) Hard reset AppX (enabled by default, gated by toggle)
# -----------------------------
if ($EnableHardResetAppX) {
    Write-Log "Hard reset AppX enabled (heavier). Re-registering Store/AppInstaller/CompanyPortal..." "WARN"

    $packages = @("Microsoft.WindowsStore","Microsoft.DesktopAppInstaller","Microsoft.CompanyPortal")

    # ,$packages wraps the array as a single argument so the job receives the
    # whole list (Start-Job -ArgumentList otherwise unrolls arrays).
    Invoke-WithTimeout `
        -TimeoutSeconds 60 `
        -Description "AppX re-register" `
        -ArgumentList (,$packages) `
        -ScriptBlock {
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
        } | Out-Null

    Write-Log "Hard reset AppX attempted." "INFO"
} else {
    Write-Log "Hard reset AppX disabled (safe default)." "INFO"
}

# -----------------------------
# 7) Final IME restart to trigger re-evaluation (skipped under IME)
# -----------------------------
if ($UnderIME) {
    Write-Log "Skipping final IntuneManagementExtension restart (running under IME - the service handles re-evaluation on its next cycle)." "INFO"
} else {
    Write-Log "Final restart of IntuneManagementExtension (to trigger re-evaluation)..." "INFO"
    Try-RestartServiceSafe -Name "IntuneManagementExtension"
}

Write-Log "=== END Remediation. Next: user closes Company Portal, reopens it, runs Sync, then retries install. ===" "INFO"
Write-Log ("Log file: {0}" -f $LogFile) "INFO"

try { Stop-Transcript | Out-Null } catch {}

# Single-line status for the Intune portal (stdout is truncated to 2048 chars).
Write-Output ("IntuneRemediation: completed. Log={0}" -f $LogFile)

exit 0
