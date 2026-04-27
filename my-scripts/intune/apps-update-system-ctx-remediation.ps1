#########################################################################################################################
#
# Script : Winget Application Upgrade Remediation
# Purpose : Install mandatory missing applications and upgrade specific applications using Winget
# Context : SYSTEM
#
#########################################################################################################################

#region Configuration

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_Winget_Remediation_SYSTEM.log"

# Applications to process (machine-wide apps only)
# Mandatory         = install if missing
# ProcessNames      = processes that should be stopped before install/upgrade (wildcards ok)
# InstallerOverride = custom installer switches (bypasses winget manifest silent switches).
#                     Required for Inno Setup apps (Greenshot) that can freeze in SYSTEM
#                     context with default --silent. Leave unset to use manifest defaults.
# TimeoutSeconds    = per-app timeout for install/upgrade (defaults to 600s if unset)
$Applications = @(
    @{
        Id = 'Greenshot.Greenshot'
        Name = 'Greenshot'
        Mandatory = $true
        ProcessNames = @('greenshot')
        InstallerOverride = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CLOSEAPPLICATIONS'
    },
    @{
        Id = 'Devolutions.RemoteDesktopManager'
        Name = 'dotnetxvd8'
        Mandatory = $false
        ProcessNames = @('RemoteDesktopManager*')
        TimeoutSeconds = 1200
    },
    @{
        Id = 'Notepad++.Notepad++'
        Name = 'Notepad++'
        Mandatory = $false
        ProcessNames = @('notepad++')
    }
    #@{
    #    Id = 'Microsoft.DotNet.SDK.8'
    #    Name = 'dotnet 8'
    #    Mandatory = $false
    #    ProcessNames = @('dotnet')
    #},
    #@{
    #    Id = 'Microsoft.DotNet.SDK.9'
    #    Name = 'dotnet 9'
    #    Mandatory = $false
    #    ProcessNames = @('dotnet')
    #}
)

#endregion Configuration

#region Functions

function Initialize-Folders {
    foreach ($Path in @($RootPath, $LogPath)) {
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
}

function Get-WingetPath {
    $WindowsApps = 'C:\Program Files\WindowsApps'

    if (-not (Test-Path $WindowsApps)) {
        throw "WindowsApps folder not found."
    }

    $wingetFolder = Get-ChildItem $WindowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $wingetFolder) {
        throw "Microsoft.DesktopAppInstaller package not found."
    }

    $wingetPath = Join-Path $wingetFolder.FullName 'winget.exe'

    if (-not (Test-Path $wingetPath)) {
        throw "winget.exe not found."
    }

    return $wingetPath
}

function Repair-WingetForSystem {
    # The winget hang ("Waiting for another install/uninstall to complete...") is
    # almost never about MSI. The real cause on managed endpoints is a failed COM
    # activation of WindowsPackageManagerServer.exe when the AppX package
    # Microsoft.DesktopAppInstaller is not registered for the SYSTEM principal.
    # We:
    #   1. Kill any leftover winget / WindowsPackageManagerServer hanging from a
    #      previous failed run (their stale handles can block a new attempt).
    #   2. Re-register DesktopAppInstaller (and Winget.Source if available) from
    #      the AppxManifest.xml present under C:\Program Files\WindowsApps.
    #      Running as SYSTEM, Add-AppxPackage -Register registers for the SYSTEM
    #      principal, which is what COM activation needs.
    Write-Log "Pre-flight: cleaning up stale winget processes" 'INFO'
    Get-Process -Name 'winget','WindowsPackageManagerServer' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
            Write-Log "Stopped stale process $($_.ProcessName) PID=$($_.Id)" 'WARN'
        } catch {
            Write-Log "Could not stop $($_.ProcessName) PID=$($_.Id): $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Log "Pre-flight: ensuring DesktopAppInstaller is registered for SYSTEM" 'INFO'
    foreach ($pkgFilter in @('Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe','Microsoft.Winget.Source_*_neutral_*__8wekyb3d8bbwe')) {
        $folders = @(Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Filter $pkgFilter -ErrorAction SilentlyContinue |
                     Sort-Object Name -Descending | Select-Object -First 1)
        foreach ($f in $folders) {
            $manifest = Join-Path $f.FullName 'AppxManifest.xml'
            if (-not (Test-Path $manifest)) { continue }
            try {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                Write-Log "Registered $($f.Name)" 'OK'
            } catch {
                Write-Log "Could not register $($f.Name): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Ensure-MsiServiceRunning {
    # Winget acquires the Windows Installer _MSIExecute mutex before any install
    # (even non-MSI installers like Inno Setup / NSIS), and the mutex is only
    # created when msiserver is actually running. If msiserver is Stopped and
    # SCM auto-start is slow/broken, winget hangs on "Waiting for another
    # install/uninstall to complete..." indefinitely. Pre-starting the service
    # removes the dependency on auto-start.
    $svc = Get-Service -Name 'msiserver' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "msiserver service not found - winget install/upgrade will likely hang" 'ERROR'
        return $false
    }
    if ($svc.Status -eq 'Running') {
        Write-Log "msiserver already running" 'OK'
        return $true
    }
    try {
        Write-Log "Starting msiserver (current status: $($svc.Status))" 'WARN'
        Start-Service -Name 'msiserver' -ErrorAction Stop
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name 'msiserver' -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') {
            Write-Log "msiserver started successfully" 'OK'
            return $true
        }
        Write-Log "msiserver status after start attempt: $($svc.Status)" 'WARN'
        return $false
    }
    catch {
        Write-Log "Failed to start msiserver: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Wait-ForInstallerIdle {
    # Heuristic: msiexec.exe count <= 1 means only the MSI service is running (idle).
    # > 1 means another install/uninstall is holding the Windows Installer mutex.
    # Returns $true when idle, $false if still busy at deadline.
    param(
        [int]$TimeoutSeconds = 120,
        [int]$PollIntervalSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($true) {
        $msiexecs = @(Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue)
        if ($msiexecs.Count -le 1) {
            return $true
        }

        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) {
            return $false
        }

        Write-Log "Windows Installer busy ($($msiexecs.Count) msiexec processes); waiting (${remaining}s remaining)" 'WARN'
        Start-Sleep -Seconds ([Math]::Min($PollIntervalSeconds, [Math]::Max(1, $remaining)))
    }
}

function Stop-ApplicationProcesses {
    param(
        [string[]]$ProcessNames
    )

    if (-not $ProcessNames -or $ProcessNames.Count -eq 0) {
        return
    }

    foreach ($procName in $ProcessNames) {
        try {
            $running = Get-Process -Name $procName -ErrorAction SilentlyContinue

            if (-not $running) {
                Write-Log "Process '$procName' not running"
                continue
            }

            foreach ($proc in $running) {
                Write-Log "Stopping process '$($proc.ProcessName)' PID=$($proc.Id) SessionId=$($proc.SessionId)" 'WARN'

                taskkill /PID $proc.Id /F /T | Out-Null
                Start-Sleep -Seconds 5

                if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
                    Write-Log "Process PID=$($proc.Id) still running after stop attempt" 'WARN'
                }
                else {
                    Write-Log "Process PID=$($proc.Id) stopped successfully" 'OK'
                }
            }
        }
        catch {
            Write-Log "Failed to stop process '$procName' : $($_.Exception.Message)" 'WARN'
        }
    }
}

function Test-WingetPackageInstalled {
    param(
        [string]$WingetPath,
        [string]$PackageId
    )

    $output = & $WingetPath list --id $PackageId --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        return $false
    }

    return ($output -match [regex]::Escape($PackageId))
}

function Test-WingetUpgradeAvailable {
    param(
        [string]$WingetPath,
        [string]$PackageId
    )

    $output = & $WingetPath list --id $PackageId --exact --upgrade-available --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return ($output -match [regex]::Escape($PackageId))
}

function Get-MsiStuckStateDiagnostic {
    # Broad diagnostic for any blocker of a winget install: MSI mutex holders,
    # Windows App SDK / AppX / IME processes that serialize installs, service
    # states, stale registry markers, pending reboot, recent MsiInstaller events.
    # Runs DURING the hang so we capture live state, not a stale snapshot.
    $diag = New-Object System.Collections.Generic.List[string]

    # LIVE _MSIExecute mutex probe - tells us if winget is actually waiting on MSI
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
        if ($m.WaitOne(500)) {
            $diag.Add("_MSIExecute mutex: exists, acquirable (NOT held) - winget is NOT really waiting on MSI mutex") | Out-Null
            $m.ReleaseMutex()
        } else {
            $diag.Add("_MSIExecute mutex: exists, HELD - winget is genuinely waiting on MSI") | Out-Null
        }
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $diag.Add("_MSIExecute mutex: does not exist - winget CANNOT be waiting on a non-existent mutex") | Out-Null
    } catch {
        $diag.Add("_MSIExecute probe error: $($_.Exception.Message)") | Out-Null
    } finally {
        if ($m) { $m.Dispose() }
    }

    # WindowsPackageManagerServer: winget's COM server. Absent during hang = COM activation failed.
    $wpms = @(Get-Process -Name 'WindowsPackageManagerServer' -ErrorAction SilentlyContinue)
    if ($wpms.Count -eq 0) {
        $diag.Add("WindowsPackageManagerServer: NOT running - winget likely hung on COM activation") | Out-Null
    } else {
        foreach ($p in $wpms) {
            $age = try { [int]((Get-Date) - $p.StartTime).TotalSeconds } catch { -1 }
            $diag.Add("WindowsPackageManagerServer PID=$($p.Id) Session=$($p.SessionId) StartedAgoSec=$age") | Out-Null
        }
    }

    # Hung winget liveness: if CPU is not growing across calls, it's passively blocked
    $wp = @(Get-Process -Name 'winget' -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($wp) {
        $cpu = try { [math]::Round($wp.CPU, 2) } catch { 'n/a' }
        $diag.Add("winget PID=$($wp.Id) Threads=$($wp.Threads.Count) Handles=$($wp.HandleCount) CPU=${cpu}s") | Out-Null
    }

    # Critical: is DesktopAppInstaller registered for SYSTEM? If not, winget as
    # SYSTEM can't activate its COM server (WindowsPackageManagerServer) and
    # hangs forever showing the misleading "Waiting for another install" message.
    # Get-AppxPackage -User accepts S-1-5-18 OR 'NT AUTHORITY\SYSTEM' depending on
    # Windows build; try both and tolerate terminating errors.
    foreach ($pkgName in @('Microsoft.DesktopAppInstaller','Microsoft.Winget.Source')) {
        $found = $null
        foreach ($userId in @('NT AUTHORITY\SYSTEM','S-1-5-18')) {
            try {
                $found = Get-AppxPackage -User $userId -Name $pkgName -ErrorAction Stop | Select-Object -First 1
                break
            } catch {}
        }
        if ($found) {
            $diag.Add("$pkgName for SYSTEM: v$($found.Version) [$($found.Status)]") | Out-Null
        } else {
            $diag.Add("$pkgName for SYSTEM: NOT REGISTERED") | Out-Null
        }
    }

    # msiexec processes (always log count, even 0)
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) {
            $diag.Add("msiexec: 0 processes running") | Out-Null
        }
        else {
            foreach ($p in $procs) {
                $cmd = if ($p.CommandLine) { $p.CommandLine.Trim() } else { '(no command line)' }
                if ($cmd.Length -gt 200) { $cmd = $cmd.Substring(0, 200) + '...' }
                $diag.Add("msiexec PID=$($p.ProcessId) Parent=$($p.ParentProcessId) : $cmd") | Out-Null
            }
        }
    } catch {
        $diag.Add("msiexec enumeration failed: $($_.Exception.Message)") | Out-Null
    }

    # Install-related processes that can serialize with winget outside of MSI
    try {
        $names = 'AgentExecutor','IntuneManagementExtension','WinGet','AppInstaller','AppInstallerCLI','WindowsPackageManagerServer','TrustedInstaller'
        $running = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        foreach ($p in $running) {
            $cmd = '(no cmdline)'
            try {
                $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
                if ($cim -and $cim.CommandLine) {
                    $cmd = $cim.CommandLine.Trim()
                    if ($cmd.Length -gt 200) { $cmd = $cmd.Substring(0, 200) + '...' }
                }
            } catch {}
            $diag.Add("$($p.ProcessName) PID=$($p.Id) : $cmd") | Out-Null
        }
    } catch {}

    # Service states
    try {
        $services = Get-Service -Name 'msiserver','TrustedInstaller','AppXSvc','IntuneManagementExtension' -ErrorAction SilentlyContinue
        foreach ($s in $services) {
            $diag.Add("Service $($s.Name) : $($s.Status)") | Out-Null
        }
    } catch {}

    # Pending reboot indicators (classic MSI blockers)
    $rebootKeys = @{
        'CBS RebootPending'       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'WU RebootRequired'       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'CBS PackagesPending'     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
    }
    foreach ($k in $rebootKeys.Keys) {
        if (Test-Path $rebootKeys[$k]) {
            $diag.Add("Pending reboot flag : $k ($($rebootKeys[$k]))") | Out-Null
        }
    }
    try {
        $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pfro.PendingFileRenameOperations) {
            $diag.Add("Pending reboot flag : PendingFileRenameOperations ($($pfro.PendingFileRenameOperations.Count) entries)") | Out-Null
        }
    } catch {}

    # Stale Installer registry markers
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Rollback\Scripts'
    )) {
        if (Test-Path $key) {
            try {
                $item = Get-Item -Path $key -ErrorAction SilentlyContinue
                if ($item -and $item.ValueCount -gt 0) {
                    $diag.Add("Registry marker: $key has $($item.ValueCount) value(s)") | Out-Null
                }
            } catch {}
        }
    }

    # Rollback files (indicate crashed MSI transaction)
    try {
        $rbfCount = @(Get-ChildItem -Path 'C:\Windows\Installer' -Filter '*.rbf' -Force -ErrorAction SilentlyContinue).Count
        if ($rbfCount -gt 0) {
            $diag.Add("Rollback files : $rbfCount *.rbf files in C:\Windows\Installer") | Out-Null
        }
    } catch {}

    # Last 3 MsiInstaller events - reveal what MSI was last doing
    try {
        $events = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='MsiInstaller'} -MaxEvents 3 -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            $msg = ($e.Message -split "`r?`n")[0].Trim()
            if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) + '...' }
            $diag.Add("MsiEvent $($e.Id) @ $($e.TimeCreated.ToString('HH:mm:ss')) : $msg") | Out-Null
        }
    } catch {}

    return $diag
}

function Read-FileShared {
    # Shared read so we can poll a file that winget is still writing to.
    param([string]$Path)

    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $content = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $content
    } catch {
        return ''
    }
}

function Invoke-WingetProcess {
    param(
        [string]$WingetPath,
        [string]$Arguments,
        [string]$OperationLabel,
        [string]$PackageId,
        [int]$TimeoutSeconds,
        [int]$WaitingStateMaxSeconds = 60,
        [int]$PollIntervalMs = 5000
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process -FilePath $WingetPath `
                                 -ArgumentList $Arguments `
                                 -PassThru `
                                 -WindowStyle Hidden `
                                 -RedirectStandardOutput $stdoutFile `
                                 -RedirectStandardError  $stderrFile

        $deadline      = (Get-Date).AddSeconds($TimeoutSeconds)
        $waitingSince  = $null
        $stuckDetected = $false
        $exited        = $false

        while ((Get-Date) -lt $deadline) {
            if ($process.WaitForExit($PollIntervalMs)) {
                $exited = $true
                break
            }

            $tail = Read-FileShared -Path $stdoutFile
            if ($tail.Length -gt 1000) { $tail = $tail.Substring($tail.Length - 1000) }

            if ($tail -match 'Waiting for another install') {
                if (-not $waitingSince) {
                    $waitingSince = Get-Date
                    Write-Log "winget waiting for install lock [$PackageId] (will abort if stuck >${WaitingStateMaxSeconds}s)" 'WARN'
                    foreach ($line in Get-MsiStuckStateDiagnostic) {
                        Write-Log "Stuck-state diagnostic (at wait start) : $line" 'WARN'
                    }
                }
                elseif (((Get-Date) - $waitingSince).TotalSeconds -ge $WaitingStateMaxSeconds) {
                    Write-Log "winget stuck in 'Waiting' state >${WaitingStateMaxSeconds}s for $PackageId - aborting" 'ERROR'
                    foreach ($line in Get-MsiStuckStateDiagnostic) {
                        Write-Log "Stuck-state diagnostic (at abort) : $line" 'ERROR'
                    }
                    $stuckDetected = $true
                    break
                }
            }
            else {
                $waitingSince = $null
            }
        }

        if (-not $exited) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 500
        }

        $stdoutContent = try { [System.IO.File]::ReadAllText($stdoutFile) } catch { '' }
        $stderrContent = try { [System.IO.File]::ReadAllText($stderrFile) } catch { '' }

        if ($stdoutContent.Trim()) { Write-Log "$OperationLabel stdout [$PackageId] : $($stdoutContent.Trim())" }
        if ($stderrContent.Trim()) { Write-Log "$OperationLabel stderr [$PackageId] : $($stderrContent.Trim())" 'WARN' }

        if ($stuckDetected) {
            throw "winget $OperationLabel aborted: stuck in MSI 'Waiting' state for $PackageId (likely orphaned MSI lock from a prior failed install)"
        }

        if (-not $exited) {
            throw "winget $OperationLabel timed out after $TimeoutSeconds seconds for package $PackageId"
        }

        return @{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutContent
            Stderr   = $stderrContent
        }
    }
    finally {
        Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WingetInstall {
    param(
        [string]$WingetPath,
        [string]$PackageId,
        [string]$Override,
        [int]$TimeoutSeconds = 600
    )

    # --scope machine intentionally kept: new installs should be machine-wide.
    $arguments = "install --id `"$PackageId`" --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"

    if ($Override) {
        $arguments += " --override `"$Override`""
    }

    return Invoke-WingetProcess -WingetPath $WingetPath -Arguments $arguments `
                                -OperationLabel 'install' -PackageId $PackageId `
                                -TimeoutSeconds $TimeoutSeconds
}

function Invoke-WingetUpgrade {
    param(
        [string]$WingetPath,
        [string]$PackageId,
        [string]$Override,
        [int]$TimeoutSeconds = 600
    )

    # --scope machine omitted on upgrade: forcing it can conflict when the existing
    # install is user-scope, and winget matches the existing scope automatically.
    $arguments = "upgrade --id `"$PackageId`" --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"

    if ($Override) {
        $arguments += " --override `"$Override`""
    }

    return Invoke-WingetProcess -WingetPath $WingetPath -Arguments $arguments `
                                -OperationLabel 'upgrade' -PackageId $PackageId `
                                -TimeoutSeconds $TimeoutSeconds
}
#endregion Functions

#region Main

$RemediationFailed = $false
$FatalMsg          = $null
$Installed         = New-Object System.Collections.Generic.List[string]
$Upgraded          = New-Object System.Collections.Generic.List[string]
$FailedOps         = New-Object System.Collections.Generic.List[string]

try {
    Initialize-Folders

    Write-Log "Winget remediation script started"
    Write-Log "Execution context : $(whoami)"
    Write-Log "Running in 64-bit PowerShell : $([Environment]::Is64BitProcess)"

    $WingetPath = Get-WingetPath
    Write-Log "Winget located at : $WingetPath" 'OK'

    # Pre-flight: make sure msiserver is Running and that DesktopAppInstaller is
    # registered for SYSTEM. The latter is what actually unblocks the winget COM
    # activation - the "Waiting for another install/uninstall to complete..."
    # message is winget's misleading fallback when its COM server fails to start.
    Ensure-MsiServiceRunning | Out-Null
    Repair-WingetForSystem

    foreach ($App in $Applications) {
        $PackageId         = $App.Id
        $DisplayName       = $App.Name
        $Mandatory         = $App.Mandatory
        $ProcessNames      = $App.ProcessNames
        $InstallerOverride = $App.InstallerOverride
        $AppTimeout        = if ($App.TimeoutSeconds) { [int]$App.TimeoutSeconds } else { 600 }

        Write-Log "Processing application : $DisplayName [$PackageId] (timeout=${AppTimeout}s)"

        $isInstalled = Test-WingetPackageInstalled -WingetPath $WingetPath -PackageId $PackageId

        if (-not $isInstalled) {
            if (-not $Mandatory) {
                Write-Log "$DisplayName not installed (optional) - skipped" 'INFO'
                continue
            }

            Write-Log "$DisplayName is mandatory but not installed - installation required" 'WARN'

            try {
                Stop-ApplicationProcesses -ProcessNames $ProcessNames

                if (-not (Wait-ForInstallerIdle)) {
                    Write-Log "Skipping install of $DisplayName : Windows Installer remained busy (will retry next Intune cycle)" 'WARN'
                    $FailedOps.Add("$DisplayName(install=msi-busy)") | Out-Null
                    $RemediationFailed = $true
                    continue
                }

                Write-Log "Starting winget install for $DisplayName"
                $install = Invoke-WingetInstall -WingetPath $WingetPath -PackageId $PackageId -Override $InstallerOverride -TimeoutSeconds $AppTimeout
                Write-Log "Winget install finished for $DisplayName with exit code $($install.ExitCode)"

                if ($install.ExitCode -eq 0) {
                    $Installed.Add($DisplayName) | Out-Null
                    Write-Log "Installation successful for $DisplayName" 'OK'
                }
                else {
                    $FailedOps.Add("$DisplayName(install=$($install.ExitCode))") | Out-Null
                    Write-Log "Installation failed for $DisplayName - ExitCode=$($install.ExitCode)" 'ERROR'
                    $RemediationFailed = $true
                }
            }
            catch {
                $msg = $_.Exception.Message
                $tag = if ($msg -match 'stuck in MSI') { 'msi-stuck' }
                       elseif ($msg -match 'timed out') { 'timeout' }
                       else { 'err' }
                $FailedOps.Add("$DisplayName(install=$tag)") | Out-Null
                Write-Log "Error while installing $DisplayName : $msg" 'ERROR'
                $RemediationFailed = $true
            }

            continue
        }

        Write-Log "$DisplayName is installed" 'OK'

        if (Test-WingetUpgradeAvailable -WingetPath $WingetPath -PackageId $PackageId) {
            Write-Log "Upgrade available for $DisplayName" 'WARN'

            try {
                Stop-ApplicationProcesses -ProcessNames $ProcessNames

                if (-not (Wait-ForInstallerIdle)) {
                    Write-Log "Skipping upgrade of $DisplayName : Windows Installer remained busy (will retry next Intune cycle)" 'WARN'
                    $FailedOps.Add("$DisplayName(upgrade=msi-busy)") | Out-Null
                    $RemediationFailed = $true
                    continue
                }

                Write-Log "Starting winget upgrade for $DisplayName"
                $upgrade = Invoke-WingetUpgrade -WingetPath $WingetPath -PackageId $PackageId -Override $InstallerOverride -TimeoutSeconds $AppTimeout
                Write-Log "Winget upgrade finished for $DisplayName with exit code $($upgrade.ExitCode)"

                if ($upgrade.ExitCode -eq 0) {
                    $Upgraded.Add($DisplayName) | Out-Null
                    Write-Log "Upgrade successful for $DisplayName" 'OK'
                }
                else {
                    $FailedOps.Add("$DisplayName(upgrade=$($upgrade.ExitCode))") | Out-Null
                    Write-Log "Upgrade failed for $DisplayName - ExitCode=$($upgrade.ExitCode)" 'ERROR'
                    $RemediationFailed = $true
                }
            }
            catch {
                $msg = $_.Exception.Message
                $tag = if ($msg -match 'stuck in MSI') { 'msi-stuck' }
                       elseif ($msg -match 'timed out') { 'timeout' }
                       else { 'err' }
                $FailedOps.Add("$DisplayName(upgrade=$tag)") | Out-Null
                Write-Log "Error while upgrading $DisplayName : $msg" 'ERROR'
                $RemediationFailed = $true
            }
        }
        else {
            Write-Log "No upgrade available for $DisplayName" 'OK'
        }
    }
}
catch {
    $FatalMsg = $_.Exception.Message
    Write-Log "Fatal error : $FatalMsg" 'ERROR'
    $RemediationFailed = $true
}

# Build single-line status for Intune stdout
$parts = @()
if ($Installed.Count) { $parts += "Installed: $($Installed -join ',')" }
if ($Upgraded.Count)  { $parts += "Upgraded: $($Upgraded -join ',')" }
if ($FailedOps.Count) { $parts += "Failed: $($FailedOps -join ',')" }
if ($FatalMsg)        { $parts += "Fatal: $FatalMsg" }
if (-not $parts.Count) { $parts = @('NoAction') }

$summary = $parts -join ' | '

if ($RemediationFailed) {
    Write-Log "Script completed with errors" 'ERROR'
    Write-Output "RemediateError | $summary"
    exit 1
}

Write-Log "Script completed successfully" 'OK'
Write-Output "Remediated | $summary"
exit 0

#endregion Main
