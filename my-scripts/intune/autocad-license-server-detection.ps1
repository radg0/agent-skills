#########################################################################################################################
#
# Script  : AutoCAD 2018 License Server Detection
# Purpose : Detect machines that still have the original licpath.lic for AutoCAD 2018
#           and/or a missing/wrong ADSKFLEX_LICENSE_FILE machine variable.
# Context : SYSTEM
# Notes   : AutoCAD 2018 install indicator = presence of either licpath.lic or licpath.lic.old in
#           C:\ProgramData\Autodesk\CLM\LGS\001J1_2018.0.0.F\
#           If neither file is there, AutoCAD 2018 is not installed → script reports Compliant
#           (not applicable, no work to do).
#           Compliance requires both: licpath.lic renamed away AND env var set to expected value.
#
#########################################################################################################################

#region Configuration

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_AutoCAD2018License_Detection_SYSTEM.log"

$VarName       = 'ADSKFLEX_LICENSE_FILE'
$ExpectedValue = '27000@chnmtusblic5.csding.corp'

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

#endregion Functions

#region Main

try {

    Initialize-Folders

    Write-Log "AutoCAD 2018 license detection script started"
    Write-Log "Execution context : $(whoami)"
    Write-Log "Expected env value: $ExpectedValue"

    $hasLic = Test-Path -Path $LicPath
    $hasOld = Test-Path -Path $LicOld -PathType Leaf -ErrorAction SilentlyContinue

    # Also detect timestamped backups (licpath.lic.old.<datetime>) from prior remediations
    $hasOldAny = $false
    if (Test-Path -Path $LicDir) {
        $hasOldAny = [bool](Get-ChildItem -Path $LicDir -Filter 'licpath.lic.old*' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    $autocadInstalled = $hasLic -or $hasOldAny
    Write-Log "licpath.lic present     : $hasLic"
    Write-Log "licpath.lic.old* present: $hasOldAny"
    Write-Log "AutoCAD 2018 detected   : $autocadInstalled"

    if (-not $autocadInstalled) {
        $status = "Compliant | AutoCAD 2018 not installed (no licpath.lic in $LicDir)"
        Write-Log $status 'OK'
        Write-Output $status
        exit 0
    }

    if ($hasLic) {
        $status = "NonCompliant | licpath.lic still present at $LicPath (must be renamed to .old)"
        Write-Log $status 'WARN'
        Write-Output $status
        exit 1
    }

    $current = [Environment]::GetEnvironmentVariable($VarName, 'Machine')

    if ([string]::IsNullOrWhiteSpace($current)) {
        $status = "NonCompliant | $VarName not set at Machine scope"
        Write-Log $status 'WARN'
        Write-Output $status
        exit 1
    }

    Write-Log "Current env value : $current"

    if ($current -ne $ExpectedValue) {
        $status = "NonCompliant | $VarName='$current' (expected '$ExpectedValue')"
        Write-Log $status 'WARN'
        Write-Output $status
        exit 1
    }

    $status = "Compliant | licpath.lic renamed and $VarName='$current'"
    Write-Log $status 'OK'
    Write-Output $status
    exit 0

}
catch {

    $err = "DetectError | $($_.Exception.Message)"
    Write-Log $err 'ERROR'
    Write-Output $err
    exit 1

}

#endregion Main
