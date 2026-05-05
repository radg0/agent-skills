#########################################################################################################################
#
# Script  : AutoCAD 2018 License Server Remediation
# Purpose : Rename C:\ProgramData\Autodesk\CLM\LGS\001J1_2018.0.0.F\licpath.lic to licpath.lic.old
#           and ensure ADSKFLEX_LICENSE_FILE machine variable points to the network license server.
# Context : SYSTEM
# Notes   : Uses [Environment]::SetEnvironmentVariable(..., 'Machine') exclusively.
#           NEVER writes to HKLM:\...\Session Manager\Environment via New-Item / Set-ItemProperty
#           because New-Item -Force on that key wipes Path, PSModulePath, TEMP, etc.
#
#           Rename uses Move-Item -Force: licpath.lic.old is overwritten if present. The goal is
#           that licpath.lic must NOT exist after the run — historical .old contents are not
#           preserved across multiple remediations (one rollback file is enough).
#
#           If AutoCAD 2018 is not installed (no licpath.lic / .old in $LicDir), the script no-ops
#           and exits 0 — consistent with the detection logic.
#
#########################################################################################################################

#region Configuration

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_AutoCAD2018License_Remediation_SYSTEM.log"

$VarName     = 'ADSKFLEX_LICENSE_FILE'
$LicenseSpec = '27000@chnmtusblic5.csding.corp'

$LicDir = 'C:\ProgramData\Autodesk\CLM\LGS\001J1_2018.0.0.F'
$LicPath = Join-Path $LicDir 'licpath.lic'
$LicOld  = Join-Path $LicDir 'licpath.lic.old'

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

function Send-EnvironmentBroadcast {

    # Idempotent: only define the P/Invoke type once per AppDomain
    if (-not ('AdskEnv.NativeMethods' -as [type])) {
        Add-Type -Namespace AdskEnv -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }

    $HWND_BROADCAST   = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    [UIntPtr]$result  = [UIntPtr]::Zero

    [void][AdskEnv.NativeMethods]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment',
        $SMTO_ABORTIFHUNG, 5000, [ref]$result)
}

function Test-AutoCAD2018Installed {
    if (-not (Test-Path -Path $LicDir)) { return $false }
    if (Test-Path -Path $LicPath)       { return $true }
    return [bool](Get-ChildItem -Path $LicDir -Filter 'licpath.lic.old*' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

#endregion Functions

#region Main

try {

    Initialize-Folders

    Write-Log "AutoCAD 2018 license remediation script started"
    Write-Log "Execution context : $(whoami)"
    Write-Log "Target env value  : $LicenseSpec"
    Write-Log "License directory : $LicDir"

    if (-not (Test-AutoCAD2018Installed)) {
        $status = "Skipped | AutoCAD 2018 not installed — nothing to remediate"
        Write-Log $status 'INFO'
        Write-Output $status
        exit 0
    }

    # Step 1 — rename licpath.lic -> licpath.lic.old. Move-Item -Force overwrites any
    # existing .old so licpath.lic never persists after this step.
    if (Test-Path -Path $LicPath) {
        if (Test-Path -Path $LicOld) {
            Write-Log "Existing licpath.lic.old will be overwritten" 'INFO'
        }
        Move-Item -Path $LicPath -Destination $LicOld -Force
        Write-Log "Renamed licpath.lic -> licpath.lic.old" 'OK'
    }
    else {
        Write-Log "licpath.lic already absent (already remediated previously)" 'INFO'
    }

    # Defensive check — if for any reason licpath.lic still exists, fail loud
    if (Test-Path -Path $LicPath) {
        throw "licpath.lic still present after rename: $LicPath"
    }

    # Step 2 — ensure machine env var is set to the expected value
    $previous = [Environment]::GetEnvironmentVariable($VarName, 'Machine')
    if ([string]::IsNullOrWhiteSpace($previous)) {
        Write-Log "Previous env value: <not set>"
    } else {
        Write-Log "Previous env value: $previous"
    }

    if ($previous -ne $LicenseSpec) {
        [Environment]::SetEnvironmentVariable($VarName, $LicenseSpec, 'Machine')
        Write-Log "Machine variable written : $VarName = $LicenseSpec" 'OK'

        Send-EnvironmentBroadcast
        Write-Log "WM_SETTINGCHANGE broadcasted" 'OK'
    }
    else {
        Write-Log "Env var already correct, no change" 'INFO'
    }

    # Step 3 — verify final state
    $verify = [Environment]::GetEnvironmentVariable($VarName, 'Machine')
    $licStillThere = Test-Path -Path $LicPath

    if ($licStillThere) {
        $err = "RemediationFailed | licpath.lic still present after rename attempt"
        Write-Log $err 'ERROR'
        Write-Output $err
        exit 1
    }

    if ($verify -ne $LicenseSpec) {
        $err = "RemediationFailed | post-write env value '$verify' != expected '$LicenseSpec'"
        Write-Log $err 'ERROR'
        Write-Output $err
        exit 1
    }

    $status = "Remediated | licpath.lic renamed, $VarName='$verify'"
    Write-Log $status 'OK'
    Write-Output $status
    exit 0

}
catch {

    $err = "RemediationError | $($_.Exception.Message)"
    Write-Log $err 'ERROR'
    Write-Output $err
    exit 1

}

#endregion Main
