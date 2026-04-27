#########################################################################################################################
#
# Script  : Winget + Intune comprehensive diagnostic (read-only)
# Purpose : Capture every piece of state we need to diagnose why winget fails on a managed endpoint
#           (AppX package state, Windows App Runtime, Microsoft.Winget.Source, MSI mutex, AppLocker/WDAC,
#           pending reboot, event logs, network to MS CDN, live winget probe, IME activity).
# Context : SYSTEM via Intune (or interactive admin for quick local checks).
#
# ==== INTUNE DEPLOYMENT (simplest) ====
# Devices -> Scripts and remediations -> Platform scripts -> Add
#   Platform: Windows 10 and later
#   Script settings:
#     - Run this script using the logged on credentials : No
#     - Enforce script signature check                  : No
#     - Run script in 64-bit PowerShell Host            : Yes
#   Assignments: target a test group first.
#
# Output:
#   - Full log          : C:\_AutoPTasks\LOG\<date>\<datetime>_Winget_Diag_SYSTEM.log
#   - Intune stdout     : single-line summary, truncated to <2048 chars
#   - Exit code         : always 0 (so deployment shows "success")
#
#########################################################################################################################

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

#region Config / State

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$RootPath      = 'C:\_AutoPTasks'
$LogPath       = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_Winget_Diag_SYSTEM.log"

$script:Findings           = New-Object System.Collections.Generic.List[string]
$script:WingetExe          = $null
$script:LoggedOnUserProfile = $null

#endregion Config / State

#region Helpers

function Initialize-Folders {
    foreach ($p in @($RootPath, $LogPath)) {
        if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','SECTION')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

function Write-Section {
    param([string]$Title)
    Write-Log ('=' * 70) 'SECTION'
    Write-Log "  $Title" 'SECTION'
    Write-Log ('=' * 70) 'SECTION'
}

function Add-Finding {
    param([string]$Message)
    $script:Findings.Add($Message) | Out-Null
    Write-Log "FINDING -> $Message" 'WARN'
}

#endregion Helpers

#region Diagnostic sections

function Get-EnvironmentInfo {
    Write-Section 'ENVIRONMENT'
    Write-Log "Running as     : $(whoami)"
    Write-Log "ComputerName   : $env:COMPUTERNAME"
    Write-Log "PSVersion      : $($PSVersionTable.PSVersion)"
    Write-Log "Is 64-bit proc : $([Environment]::Is64BitProcess)"
    Write-Log "Is 64-bit OS   : $([Environment]::Is64BitOperatingSystem)"

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            Write-Log "OS             : $($os.Caption) $($os.Version) Build $($os.BuildNumber)"
            Write-Log "Last boot      : $($os.LastBootUpTime)"
            $uptime = (Get-Date) - $os.LastBootUpTime
            Write-Log "Uptime hours   : $([int]$uptime.TotalHours)"
        }
    } catch {}

    try {
        $logged = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        Write-Log "Logged-on user : $logged"
        if ($logged) {
            $sid = (New-Object System.Security.Principal.NTAccount($logged)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            Write-Log "Logged-on SID  : $sid"
            $script:LoggedOnUserProfile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
            Write-Log "User profile   : $script:LoggedOnUserProfile"
        }
    } catch {
        Write-Log "Could not resolve logged-on user: $($_.Exception.Message)" 'WARN'
    }
}

function Get-AppxInventory {
    Write-Section 'APPX PACKAGES (winget dependencies + related)'

    $targets = @(
        'Microsoft.DesktopAppInstaller',
        'Microsoft.Winget.Source',
        'Microsoft.WindowsAppRuntime.1.8',
        'Microsoft.WindowsAppRuntime.1.7',
        'Microsoft.WindowsAppRuntime.1.6',
        'Microsoft.VCLibs.140.00',
        'Microsoft.VCLibs.140.00.UWPDesktop',
        'Microsoft.UI.Xaml.2.8',
        'Microsoft.UI.Xaml.2.7',
        'Microsoft.WindowsStore',
        'Microsoft.CompanyPortal'
    )

    foreach ($name in $targets) {
        $pkgs = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
        if ($pkgs.Count -eq 0) {
            Write-Log "$name : NOT INSTALLED"
            if ($name -eq 'Microsoft.Winget.Source') {
                Add-Finding 'Microsoft.Winget.Source AppX is missing (winget search fails with 0x8A15000F)'
            }
            elseif ($name -eq 'Microsoft.DesktopAppInstaller') {
                Add-Finding 'Microsoft.DesktopAppInstaller AppX is missing (winget unavailable)'
            }
            continue
        }
        foreach ($p in $pkgs) {
            Write-Log ("{0,-45} v{1,-22} [{2}] arch={3} signed={4}" -f $p.Name, $p.Version, $p.Status, $p.Architecture, $p.SignatureKind)
            if ($p.Status -ne 'Ok') {
                Add-Finding "Bad AppX status: $($p.Name) v$($p.Version) = $($p.Status)"
            }
            Write-Log "   Path : $($p.InstallLocation)"
            if ($p.PackageUserInformation) {
                foreach ($u in $p.PackageUserInformation) {
                    Write-Log "   User : $($u.UserSecurityId) -> $($u.InstallState)"
                }
            }
        }
    }

    Write-Log '--- All WindowsAppRuntime variants ---'
    $runtime = @(Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsAppRuntime.*' -ErrorAction SilentlyContinue)
    foreach ($p in $runtime) {
        Write-Log ("{0,-55} v{1,-22} [{2}]" -f $p.Name, $p.Version, $p.Status)
    }
}

function Get-AppxRegistrationBySid {
    # Verify which users (including SYSTEM) have winget's critical AppX packages
    # actually registered. If SYSTEM doesn't have Microsoft.DesktopAppInstaller,
    # winget running as SYSTEM (via IME) cannot activate WindowsPackageManagerServer
    # via COM and will hang on "Waiting for another install/uninstall".
    Write-Section 'APPX REGISTRATION BY USER (critical: SYSTEM must have DesktopAppInstaller)'

    $sids = New-Object System.Collections.Generic.List[string]
    try {
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $s = Split-Path $_.Name -Leaf
                if ($s -match '^S-1-') { $sids.Add($s) | Out-Null }
            }
    } catch {}
    foreach ($wellKnown in @('S-1-5-18','S-1-5-19','S-1-5-20')) {
        if (-not $sids.Contains($wellKnown)) { $sids.Add($wellKnown) | Out-Null }
    }

    $critical = @('Microsoft.DesktopAppInstaller','Microsoft.Winget.Source','Microsoft.WindowsAppRuntime.1.8')

    foreach ($sid in $sids) {
        $account = '(unresolved)'
        try {
            $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
        } catch {}
        Write-Log ("--- {0}  ({1}) ---" -f $sid, $account)

        foreach ($pkgName in $critical) {
            $pkg = Get-AppxPackage -User $sid -Name $pkgName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pkg) {
                Write-Log ("   {0,-40} : v{1} [{2}]" -f $pkgName, $pkg.Version, $pkg.Status)
            }
            else {
                Write-Log ("   {0,-40} : NOT REGISTERED" -f $pkgName) 'WARN'
                if ($sid -eq 'S-1-5-18' -and $pkgName -eq 'Microsoft.DesktopAppInstaller') {
                    Add-Finding 'DesktopAppInstaller NOT registered for SYSTEM (S-1-5-18) - winget COM activation will fail/hang'
                }
                elseif ($sid -eq 'S-1-5-18' -and $pkgName -eq 'Microsoft.Winget.Source') {
                    Add-Finding 'Microsoft.Winget.Source NOT registered for SYSTEM - winget sources will be rebuilt in-memory every call'
                }
            }
        }
    }
}

function Get-WingetBinaryState {
    Write-Section 'WINGET BINARY'

    $wa = 'C:\Program Files\WindowsApps'
    if (-not (Test-Path $wa)) {
        Write-Log "WindowsApps folder missing: $wa" 'ERROR'
        Add-Finding 'C:\Program Files\WindowsApps missing (no AppX packages can be registered)'
        return
    }

    $folders = @(Get-ChildItem $wa -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue)
    Write-Log "DesktopAppInstaller folders in WindowsApps: $($folders.Count)"
    foreach ($f in $folders) {
        Write-Log "   $($f.Name)  (modified $($f.LastWriteTime))"
    }

    $main = $folders | Where-Object { $_.Name -match '_(x64|x86|arm64)__8wekyb3d8bbwe$' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($main) {
        $script:WingetExe = Join-Path $main.FullName 'winget.exe'
        Write-Log "Selected winget: $script:WingetExe"
        Write-Log "winget.exe exists: $(Test-Path $script:WingetExe)"
    } else {
        Write-Log 'No main DesktopAppInstaller folder (x64/x86/arm64) found' 'ERROR'
        Add-Finding 'No main DesktopAppInstaller folder (x64/x86/arm64) in WindowsApps'
    }
}

function Get-ServicesState {
    Write-Section 'SERVICES'
    $names = 'msiserver','TrustedInstaller','AppXSvc','ClipSVC','StateRepository','DoSvc','BITS','wuauserv','IntuneManagementExtension','AppReadiness','Appinfo'
    foreach ($n in $names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) {
            Write-Log ("{0,-30} Status={1,-10} StartType={2}" -f $s.Name, $s.Status, $s.StartType)
        } else {
            Write-Log "$n : not found"
        }
    }
}

function Get-ProcessesState {
    Write-Section 'RELATED RUNNING PROCESSES'

    $names = 'msiexec','winget','WindowsPackageManagerServer','AppInstaller','AppInstallerCLI','AgentExecutor','IntuneManagementExtension','TrustedInstaller','wsappx'

    $any = $false
    foreach ($n in $names) {
        $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { continue }
        $any = $true
        foreach ($p in $procs) {
            $cmd = '(no cmdline)'
            $parent = '?'
            try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
                if ($cim) {
                    if ($cim.CommandLine) {
                        $cmd = $cim.CommandLine.Trim()
                        if ($cmd.Length -gt 250) { $cmd = $cmd.Substring(0, 250) + '...' }
                    }
                    $parent = $cim.ParentProcessId
                }
            } catch {}
            Write-Log "$($p.ProcessName) PID=$($p.Id) Session=$($p.SessionId) Parent=$parent"
            Write-Log "   cmd: $cmd"
        }
    }
    if (-not $any) { Write-Log 'None of the tracked processes are running' }
}

function Get-MsiState {
    Write-Section 'WINDOWS INSTALLER STATE'

    # _MSIExecute mutex probe
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
        if ($m.WaitOne(3000)) {
            Write-Log '_MSIExecute mutex: exists, acquirable -> NOT held' 'OK'
            $m.ReleaseMutex()
        } else {
            Write-Log '_MSIExecute mutex: exists, HELD by someone' 'WARN'
            Add-Finding '_MSIExecute mutex is currently held (an install is in progress)'
        }
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        Write-Log '_MSIExecute mutex: does not exist (MSI idle since boot)'
    } catch {
        Write-Log "_MSIExecute probe failed: $($_.Exception.Message)" 'WARN'
    } finally {
        if ($m) { $m.Dispose() }
    }

    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Rollback\Scripts'
    )) {
        if (-not (Test-Path $key)) { Write-Log "$key : not present"; continue }
        $item = Get-Item -Path $key -ErrorAction SilentlyContinue
        if ($item) {
            Write-Log "$key : $($item.ValueCount) value(s)"
            if ($item.ValueCount -gt 0) {
                Add-Finding "Stale MSI marker in $key ($($item.ValueCount) values)"
            }
        }
    }

    try {
        $rbfCount = @(Get-ChildItem -Path 'C:\Windows\Installer' -Filter '*.rbf' -Force -ErrorAction SilentlyContinue).Count
        Write-Log "C:\Windows\Installer\*.rbf : $rbfCount file(s)"
        if ($rbfCount -gt 0) { Add-Finding "$rbfCount pending MSI rollback (.rbf) files" }
    } catch {}
}

function Get-RebootPendingState {
    Write-Section 'PENDING REBOOT FLAGS'
    $flags = @{
        'CBS RebootPending'   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'CBS PackagesPending' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
        'WU RebootRequired'   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
    foreach ($k in $flags.Keys) {
        $present = Test-Path $flags[$k]
        Write-Log "$k : $present"
        if ($present) { Add-Finding "Pending reboot: $k" }
    }
    try {
        $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfro) {
            Write-Log "PendingFileRenameOperations : $($pfro.Count) entries"
            Add-Finding "PendingFileRenameOperations has $($pfro.Count) entries"
        } else {
            Write-Log 'PendingFileRenameOperations : none'
        }
    } catch {}
}

function Get-EventsDiagnostic {
    Write-Section 'EVENT LOGS'

    $sources = @(
        @{ Log = 'Application';                                               Provider = 'MsiInstaller'; Count = 10 }
        @{ Log = 'Microsoft-Windows-AppXDeployment-Server/Operational';       Provider = $null;         Count = 20 }
        @{ Log = 'Microsoft-Windows-AppXDeployment/Operational';              Provider = $null;         Count = 10 }
        @{ Log = 'Microsoft-Windows-AppLocker/Packaged app-Deployment';       Provider = $null;         Count = 15 }
        @{ Log = 'Microsoft-Windows-AppLocker/Packaged app-Execution';        Provider = $null;         Count = 10 }
        @{ Log = 'Microsoft-Windows-AppInstaller/Admin';                      Provider = $null;         Count = 10 }
        @{ Log = 'Microsoft-Windows-AppInstaller/Operational';                Provider = $null;         Count = 10 }
        @{ Log = 'Microsoft-Windows-CodeIntegrity/Operational';               Provider = $null;         Count = 10 }
    )

    foreach ($cfg in $sources) {
        $filter = @{ LogName = $cfg.Log }
        if ($cfg.Provider) { $filter['ProviderName'] = $cfg.Provider }

        $events = $null
        try { $events = Get-WinEvent -FilterHashtable $filter -MaxEvents $cfg.Count -ErrorAction SilentlyContinue } catch {}

        $label = if ($cfg.Provider) { "$($cfg.Log) [$($cfg.Provider)]" } else { $cfg.Log }
        if (-not $events) {
            Write-Log "$label : no events or log not enabled"
            continue
        }

        Write-Log "--- $label (last $($cfg.Count)) ---"
        foreach ($e in $events) {
            $msg = ''
            if ($e.Message) { $msg = ($e.Message -split "`r?`n")[0].Trim() }
            if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 250) + '...' }
            Write-Log "$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) Id=$($e.Id) [$($e.LevelDisplayName)] : $msg"

            if ($cfg.Log -match 'AppLocker' -and $msg -match 'Winget|DesktopAppInstaller|WindowsAppRuntime|was prevented|was blocked') {
                Add-Finding "AppLocker event: Id=$($e.Id) msg='$msg'"
            }
            if ($cfg.Log -match 'CodeIntegrity' -and $msg -match 'blocked|violated|did not pass') {
                Add-Finding "CodeIntegrity event: Id=$($e.Id) msg='$msg'"
            }
        }
    }
}

function Get-SecurityPosture {
    Write-Section 'SECURITY / CODE INTEGRITY / APPLOCKER / ASR'

    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
        if ($dg) {
            Write-Log "DeviceGuard CI status (kernel)    : $($dg.CodeIntegrityPolicyEnforcementStatus)  (0=off,1=audit,2=enforced)"
            Write-Log "DeviceGuard CI status (user-mode) : $($dg.UsermodeCodeIntegrityPolicyEnforcementStatus)"
            Write-Log "DeviceGuard VBS status            : $($dg.VirtualizationBasedSecurityStatus)"
            Write-Log "DeviceGuard Services Running      : $($dg.SecurityServicesRunning -join ',')"
            # Kernel-mode CI enforcement is the Windows 11 Enterprise default and does
            # not block user-mode installers like winget. Only flag when usermode is
            # enforced (CI user-mode = 2), which would actually block arbitrary EXEs.
            if ($dg.UsermodeCodeIntegrityPolicyEnforcementStatus -ge 2) {
                Add-Finding "WDAC user-mode enforced (usermode=$($dg.UsermodeCodeIntegrityPolicyEnforcementStatus)) - will block unsigned installers"
            }
        }
    } catch { Write-Log "DeviceGuard query failed: $($_.Exception.Message)" 'WARN' }

    try {
        $policy = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
        if ($policy -and $policy.RuleCollections) {
            foreach ($rc in $policy.RuleCollections) {
                $ruleCount = 0
                try { $ruleCount = @($rc).Count } catch {}
                if ($ruleCount -eq 0) { try { $ruleCount = $rc.Count } catch {} }
                Write-Log ("AppLocker {0,-8} EnforcementMode={1,-20} Rules={2}" -f $rc.RuleCollectionType, $rc.EnforcementMode, $ruleCount)
                if ($rc.RuleCollectionType -eq 'Appx' -and $rc.EnforcementMode -ne 'NotConfigured' -and $ruleCount -gt 0) {
                    Add-Finding "AppLocker Appx collection is '$($rc.EnforcementMode)' with $ruleCount rule(s)"
                }
            }
        } else {
            Write-Log 'AppLocker: no effective policy'
        }
    } catch { Write-Log "AppLocker query failed: $($_.Exception.Message)" 'WARN' }

    try {
        $p = Get-MpPreference -ErrorAction SilentlyContinue
        if ($p -and $p.AttackSurfaceReductionRules_Ids) {
            Write-Log '--- ASR rules ---'
            for ($i = 0; $i -lt $p.AttackSurfaceReductionRules_Ids.Count; $i++) {
                $id = $p.AttackSurfaceReductionRules_Ids[$i]
                $act = $p.AttackSurfaceReductionRules_Actions[$i]
                $actName = switch ($act) { 0 {'Disabled'} 1 {'Block'} 2 {'Audit'} 6 {'Warn'} default {"Unknown($act)"} }
                Write-Log "   $id -> $actName"
            }
        }
    } catch { Write-Log "ASR query failed: $($_.Exception.Message)" 'WARN' }
}

function Get-NetworkDiagnostic {
    Write-Section 'NETWORK'

    $targets = @(
        'cdn.winget.microsoft.com',
        'storeedgefd.dsx.mp.microsoft.com',
        'dl.delivery.mp.microsoft.com'
    )
    foreach ($t in $targets) {
        try {
            $r = Test-NetConnection -ComputerName $t -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue
            Write-Log "TCP 443 -> $t : $r"
            if (-not $r) { Add-Finding "Network: cannot reach $t:443" }
        } catch { Write-Log "$t test error: $($_.Exception.Message)" 'WARN' }
    }

    try {
        $proxy = (netsh winhttp show proxy) 2>&1
        Write-Log "WinHTTP : $($proxy -join ' | ')"
    } catch {}
}

function Get-WingetInternalLogs {
    Write-Section 'WINGET INTERNAL LOGS'

    $candidates = @('C:\Windows\System32\config\systemprofile\AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState')
    if ($script:LoggedOnUserProfile) {
        $candidates += (Join-Path $script:LoggedOnUserProfile 'AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState')
    }

    foreach ($base in $candidates) {
        Write-Log "--- LocalState: $base ---"
        if (-not (Test-Path $base)) { Write-Log '  (does not exist)'; continue }

        try {
            $files = Get-ChildItem $base -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            Write-Log "  $($files.Count) file(s) in LocalState"
            $files | Select-Object -First 30 | ForEach-Object {
                Write-Log ("    {0,10}B  {1}  {2}" -f $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $_.FullName)
            }
        } catch {}

        $diag = Join-Path $base 'DiagOutputDir'
        if (Test-Path $diag) {
            $latest = Get-ChildItem $diag -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                Write-Log "  Latest diag log: $($latest.Name) ($($latest.Length) bytes)"
                try {
                    $tail = Get-Content $latest.FullName -Tail 80 -ErrorAction SilentlyContinue
                    foreach ($line in $tail) { Write-Log "    $line" }
                } catch { Write-Log "  (tail failed: $($_.Exception.Message))" 'WARN' }
            }
        }
    }
}

function Test-WingetLive {
    Write-Section 'WINGET LIVE TEST (with timeout)'

    if (-not $script:WingetExe -or -not (Test-Path $script:WingetExe)) {
        Write-Log 'winget binary unavailable; skipping live tests' 'WARN'
        return
    }

    $tests = @(
        @{ Label = '--version';              Args = @('--version');              Timeout = 30 },
        @{ Label = 'source list';            Args = @('source','list');          Timeout = 30 },
        @{ Label = 'search Notepad++';       Args = @('search','Notepad++','--disable-interactivity'); Timeout = 60 }
    )

    foreach ($t in $tests) {
        Write-Log "--- winget $($t.Label) ---"
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath $script:WingetExe -ArgumentList $t.Args -PassThru -WindowStyle Hidden `
                                  -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

            if (-not $proc.WaitForExit($t.Timeout * 1000)) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                Write-Log "  TIMED OUT after $($t.Timeout)s" 'ERROR'
                Add-Finding ("winget $($t.Label) hung (>{0}s)" -f $t.Timeout)
            } else {
                # After a timed WaitForExit, stdout/stderr streams may not be fully
                # flushed and ExitCode can read as $null. Calling WaitForExit() without
                # timeout forces stream drain and makes ExitCode reliable.
                $proc.WaitForExit()
                $exitCode = $proc.ExitCode
                Write-Log "  ExitCode: $exitCode"
                $so = try { Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue } catch { '' }
                $se = try { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } catch { '' }
                if ($so) { foreach ($l in ($so -split "`r?`n")) { if ($l.Trim()) { Write-Log "  stdout: $l" } } }
                if ($se) { foreach ($l in ($se -split "`r?`n")) { if ($l.Trim()) { Write-Log "  stderr: $l" 'WARN' } } }
                if ($exitCode -ne $null -and $exitCode -ne 0) {
                    Add-Finding "winget $($t.Label) failed (exit=$exitCode)"
                }
            }
        } catch { Write-Log "Live test error: $($_.Exception.Message)" 'ERROR' }
        finally { Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue }
    }
}

function Get-IntuneAgentInfo {
    Write-Section 'INTUNE MANAGEMENT EXTENSION'

    $imeLog   = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log'
    $agentLog = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log'

    foreach ($l in @($imeLog, $agentLog)) {
        if (Test-Path $l) {
            $fi = Get-Item $l
            Write-Log "$l ($([math]::Round($fi.Length/1KB,1)) KB @ $($fi.LastWriteTime))"
        } else {
            Write-Log "$l : missing"
        }
    }

    if (Test-Path $agentLog) {
        Write-Log '--- AgentExecutor.log tail (40 lines) ---'
        try { Get-Content $agentLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "  $_" } } catch {}
    }
}

#endregion Diagnostic sections

#region Main

try {
    Initialize-Folders
    Write-Log '=== Winget comprehensive diagnostic started ==='
    Write-Log "Log file: $script:LogFile"

    Get-EnvironmentInfo
    Get-AppxInventory
    Get-AppxRegistrationBySid
    Get-WingetBinaryState
    Get-ServicesState
    Get-ProcessesState
    Get-MsiState
    Get-RebootPendingState
    Get-EventsDiagnostic
    Get-SecurityPosture
    Get-NetworkDiagnostic
    Get-WingetInternalLogs
    Test-WingetLive
    Get-IntuneAgentInfo

    Write-Log '=== Winget comprehensive diagnostic finished ==='
}
catch {
    Write-Log "Fatal diagnostic error: $($_.Exception.Message)" 'ERROR'
    Add-Finding "Fatal diagnostic error: $($_.Exception.Message)"
}

# Single-line summary for Intune stdout (truncated to stay under 2048 chars)
$summary = if ($script:Findings.Count -gt 0) {
    $uniq = $script:Findings | Select-Object -Unique
    "DiagIssues($($uniq.Count)) | " + (($uniq | Select-Object -First 6) -join ' | ')
} else {
    'DiagClean | No issues detected'
}
if ($summary.Length -gt 1900) { $summary = $summary.Substring(0, 1900) + '...' }

Write-Log "Summary: $summary"
Write-Output "$summary | Log=$script:LogFile"
exit 0

#endregion Main
