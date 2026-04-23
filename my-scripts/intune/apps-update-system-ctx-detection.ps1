#########################################################################################################################
#
# Script : Winget Application Upgrade Detection
# Purpose : Detect whether specific applications have an available upgrade using Winget
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
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_Winget_Detection_SYSTEM.log"

# Applications to evaluate (machine-wide apps only)
$Applications = @(
    @{
        Id = 'Greenshot.Greenshot'
        Name = 'Greenshot'
        Mandatory = $true
    },
    @{
        Id = 'Devolutions.RemoteDesktopManager'
        Name = 'dotnetxvd8'
        Mandatory = $false
    },
    @{
        Id = 'Notepad++.Notepad++'
        Name = 'Notepad++'
        Mandatory = $false
    }
    #@{
    #    Id = 'Microsoft.DotNet.SDK.8'
    #    Name = 'dotnet 8'
    #    Mandatory = $false
    #},
    #@{
    #    Id = 'Microsoft.DotNet.SDK.9'
    #    Name = 'dotnet 9'
    #    Mandatory = $false
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

function Test-WingetPackageInstalled {

    param(
        [string]$WingetPath,
        [string]$PackageId
    )

    $output = & $WingetPath list `
        --id $PackageId `
        --exact `
        --source winget `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return ($output -match [regex]::Escape($PackageId))
}

function Test-WingetUpgradeAvailable {

    param(
        [string]$WingetPath,
        [string]$PackageId
    )

    $output = & $WingetPath list `
        --id $PackageId `
        --exact `
        --upgrade-available `
        --source winget `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return ($output -match [regex]::Escape($PackageId))
}

#endregion Functions

#region Main

$MandatoryMissing = New-Object System.Collections.Generic.List[string]
$UpgradeNeeded    = New-Object System.Collections.Generic.List[string]

try {

    Initialize-Folders

    Write-Log "Winget detection script started"
    Write-Log "Execution context : $(whoami)"
    Write-Log "Running in 64-bit PowerShell : $([Environment]::Is64BitProcess)"

    $WingetPath = Get-WingetPath
    Write-Log "Winget located at : $WingetPath" 'OK'

    foreach ($App in $Applications) {

        $PackageId   = $App.Id
        $DisplayName = $App.Name
        $Mandatory   = $App.Mandatory

        Write-Log "Checking application : $DisplayName [$PackageId]"

        $isInstalled = Test-WingetPackageInstalled -WingetPath $WingetPath -PackageId $PackageId

        if (-not $isInstalled) {

            if ($Mandatory) {
                Write-Log "$DisplayName is mandatory but NOT installed" 'WARN'
                $MandatoryMissing.Add($DisplayName) | Out-Null
            }
            else {
                Write-Log "$DisplayName not installed (optional)" 'INFO'
            }

            continue
        }

        Write-Log "$DisplayName is installed" 'OK'

        if (Test-WingetUpgradeAvailable -WingetPath $WingetPath -PackageId $PackageId) {
            Write-Log "Upgrade available for $DisplayName" 'WARN'
            $UpgradeNeeded.Add($DisplayName) | Out-Null
        }
        else {
            Write-Log "No upgrade available for $DisplayName" 'OK'
        }
    }

    $parts = @()
    if ($MandatoryMissing.Count) { $parts += "MandatoryMissing: $($MandatoryMissing -join ',')" }
    if ($UpgradeNeeded.Count)    { $parts += "Upgrades: $($UpgradeNeeded -join ',')" }

    if ($parts.Count) {
        $status = "NonCompliant | " + ($parts -join ' | ')
        Write-Log $status 'WARN'
        Write-Output $status
        exit 1
    }

    $status = 'Compliant | All apps up to date'
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
