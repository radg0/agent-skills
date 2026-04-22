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

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')]
        [string]$Level = 'INFO'
    )

    $prefix = "[{0}] [{1}]" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level
    Write-Host "$prefix $Message"
}

function Get-WingetPath {

    $WindowsApps = "C:\Program Files\WindowsApps"

    if (-not (Test-Path $WindowsApps)) {
        throw "WindowsApps folder not found."
    }

    $wingetFolder = Get-ChildItem $WindowsApps -Directory -Filter "Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe" |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $wingetFolder) {
        throw "Microsoft.DesktopAppInstaller package not found."
    }

    $wingetPath = Join-Path $wingetFolder.FullName "winget.exe"

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

function Get-WingetUpgradeablePackages {

    param(
        [string]$WingetPath
    )

    $output = & $WingetPath list `
        --upgrade-available `
        --source winget `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        throw "winget list failed with exit code $LASTEXITCODE"
    }

    return $output
}

#endregion Functions

#region Main

try {

    Write-Log "Winget detection script started"
    Write-Log "Execution context : $(whoami)"
    Write-Log "Running in 64-bit PowerShell : $([Environment]::Is64BitProcess)"

    $WingetPath = Get-WingetPath
    Write-Log "Winget located at : $WingetPath" "OK"

    $UpgradeableOutput = Get-WingetUpgradeablePackages -WingetPath $WingetPath

    $UpgradeNeeded = $false
    $MandatoryMissing = $false

    foreach ($App in $Applications) {

        $PackageId = $App.Id
        $DisplayName = $App.Name
        $Mandatory = $App.Mandatory

        Write-Log "Checking application : $DisplayName [$PackageId]"

        $isInstalled = Test-WingetPackageInstalled -WingetPath $WingetPath -PackageId $PackageId

        if (-not $isInstalled) {

            if ($Mandatory) {
                Write-Log "$DisplayName is mandatory but NOT installed" "WARN"
                $MandatoryMissing = $true
            }
            else {
                Write-Log "$DisplayName not installed (optional)" "INFO"
            }

            continue
        }

        Write-Log "$DisplayName is installed" "OK"

        if ($UpgradeableOutput -match [regex]::Escape($PackageId)) {

            Write-Log "Upgrade available for $DisplayName" "WARN"
            $UpgradeNeeded = $true

        }
        else {

            Write-Log "No upgrade available for $DisplayName" "OK"

        }
    }

    if ($MandatoryMissing -or $UpgradeNeeded) {

        if ($MandatoryMissing) {
            Write-Log "At least one mandatory application is missing" "WARN"
        }

        if ($UpgradeNeeded) {
            Write-Log "At least one application requires upgrade" "WARN"
        }

        Write-Log "Remediation required" "WARN"
        exit 1

    }

    Write-Log "All checks passed - No remediation required" "OK"
    exit 0

}
catch {

    Write-Log "Fatal error : $($_.Exception.Message)" "ERROR"
    exit 1

}

#endregion Main