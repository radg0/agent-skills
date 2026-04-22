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

$RootPath      = 'C:\_AutoPTasks'
$LogPath       = Join-Path $RootPath "LOG\$DateStamp"
$TranscriptLog = Join-Path $LogPath "${DateTimeStamp}_Winget_Remediation_SYSTEM.log"

# Applications to process (machine-wide apps only)
# Mandatory    = install if missing
# ProcessNames = processes that should be stopped before install/upgrade
$Applications = @(
    @{
        Id = 'Greenshot.Greenshot'
        Name = 'Greenshot'
        Mandatory = $true
        ProcessNames = @('greenshot')
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

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')]
        [string]$Level = 'INFO'
    )

    $prefix = "[{0}] [{1}]" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level
    Write-Host "$prefix $Message"
}

function Initialize-Folders {
    foreach ($Path in @($RootPath, $LogPath)) {
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
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

function Get-WingetUpgradeablePackages {
    param(
        [string]$WingetPath
    )

    $output = & $WingetPath list --upgrade-available --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "winget list --upgrade-available failed with exit code $exitCode. Output: $output"
    }

    return $output
}

function Invoke-WingetInstall {
    param(
        [string]$WingetPath,
        [string]$PackageId
    )

    $arguments = "install --id `"$PackageId`" --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"

    $process = Start-Process -FilePath $WingetPath `
                             -ArgumentList $arguments `
                             -Wait `
                             -PassThru `
                             -WindowStyle Hidden

    return @{
        ExitCode = $process.ExitCode
        Output   = "No console output captured"
    }
}

function Invoke-WingetUpgrade {
    param(
        [string]$WingetPath,
        [string]$PackageId,
        [int]$TimeoutSeconds = 300
    )

    $arguments = "upgrade --id `"$PackageId`" --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"

    $process = Start-Process -FilePath $WingetPath `
                             -ArgumentList $arguments `
                             -PassThru `
                             -WindowStyle Hidden

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw "winget upgrade timed out after $TimeoutSeconds seconds for package $PackageId"
    }

    return @{
        ExitCode = $process.ExitCode
        Output   = "No console output captured"
    }
}
#endregion Functions

#region Main

$global:RemediationFailed = $false
$Results = New-Object System.Collections.Generic.List[object]

try {
    Initialize-Folders
    Start-Transcript -Path $TranscriptLog -Force | Out-Null

    Write-Log "Winget remediation script started"
    Write-Log "Execution context : $(whoami)"
    Write-Log "Running in 64-bit PowerShell : $([Environment]::Is64BitProcess)"

    $WingetPath = Get-WingetPath
    Write-Log "Winget located at : $WingetPath" 'OK'

    $UpgradeableOutput = Get-WingetUpgradeablePackages -WingetPath $WingetPath

    foreach ($App in $Applications) {
        $PackageId    = $App.Id
        $DisplayName  = $App.Name
        $Mandatory    = $App.Mandatory
        $ProcessNames = $App.ProcessNames

        Write-Log "Processing application : $DisplayName [$PackageId]"

        $result = [ordered]@{
            Id               = $PackageId
            Name             = $DisplayName
            Mandatory        = $Mandatory
            Installed        = $false
            UpgradeAvailable = $false
            Action           = ''
            Success          = $false
            ExitCode         = $null
            Note             = ''
        }

        $isInstalled = Test-WingetPackageInstalled -WingetPath $WingetPath -PackageId $PackageId
        $result.Installed = $isInstalled

        if (-not $isInstalled) {
            if (-not $Mandatory) {
                $result.Note = 'Not installed (optional)'
                Write-Log "$DisplayName not installed (optional) - skipped" 'INFO'
                $Results.Add([pscustomobject]$result) | Out-Null
                continue
            }

            Write-Log "$DisplayName is mandatory but not installed - installation required" 'WARN'
            $result.Action = 'Install'

            try {
                Stop-ApplicationProcesses -ProcessNames $ProcessNames

                Write-Log "Starting winget install for $DisplayName"
                $install = Invoke-WingetInstall -WingetPath $WingetPath -PackageId $PackageId
                Write-Log "Winget install finished for $DisplayName with exit code $($install.ExitCode)"
                $result.ExitCode = $install.ExitCode

                if ($install.ExitCode -eq 0) {
                    $result.Success = $true
                    $result.Note = 'Installation successful'
                    Write-Log "Installation successful for $DisplayName" 'OK'
                }
                else {
                    $result.Note = "Installation failed. ExitCode=$($install.ExitCode)"
                    Write-Log "Installation failed for $DisplayName - ExitCode=$($install.ExitCode)" 'ERROR'
                    Write-Log "Winget output:`n$($install.Output)" 'ERROR'
                    $global:RemediationFailed = $true
                }
            }
            catch {
                $result.Note = $_.Exception.Message
                Write-Log "Error while installing $DisplayName : $($_.Exception.Message)" 'ERROR'
                $global:RemediationFailed = $true
            }

            $Results.Add([pscustomobject]$result) | Out-Null
            continue
        }

        Write-Log "$DisplayName is installed" 'OK'

        if ($UpgradeableOutput -match [regex]::Escape($PackageId)) {
            $result.UpgradeAvailable = $true
            $result.Action = 'Upgrade'
            Write-Log "Upgrade available for $DisplayName" 'WARN'

            try {
                Stop-ApplicationProcesses -ProcessNames $ProcessNames

                Write-Log "Starting winget upgrade for $DisplayName"
                $upgrade = Invoke-WingetUpgrade -WingetPath $WingetPath -PackageId $PackageId
                Write-Log "Winget upgrade finished for $DisplayName with exit code $($upgrade.ExitCode)"
                $result.ExitCode = $upgrade.ExitCode

                if ($upgrade.ExitCode -eq 0) {
                    $result.Success = $true
                    $result.Note = 'Upgrade successful'
                    Write-Log "Upgrade successful for $DisplayName" 'OK'
                }
                else {
                    $result.Note = "Upgrade failed. ExitCode=$($upgrade.ExitCode)"
                    Write-Log "Upgrade failed for $DisplayName - ExitCode=$($upgrade.ExitCode)" 'ERROR'
                    Write-Log "Winget output:`n$($upgrade.Output)" 'ERROR'
                    $global:RemediationFailed = $true
                }
            }
            catch {
                $result.Note = $_.Exception.Message
                Write-Log "Error while upgrading $DisplayName : $($_.Exception.Message)" 'ERROR'
                $global:RemediationFailed = $true
            }
        }
        else {
            $result.Note = 'No upgrade available'
            Write-Log "No upgrade available for $DisplayName" 'OK'
        }

        $Results.Add([pscustomobject]$result) | Out-Null
    }

    Write-Log "Execution summary"
    $Results | Format-Table -AutoSize | Out-String | Write-Host

    if ($global:RemediationFailed) {
        Write-Log "Script completed with errors" 'ERROR'
        exit 1
    }
    else {
        Write-Log "Script completed successfully" 'OK'
        exit 0
    }
}
catch {
    Write-Log "Fatal error : $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {}
}

#endregion Main