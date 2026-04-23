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

function Invoke-WingetProcess {
    param(
        [string]$WingetPath,
        [string]$Arguments,
        [string]$OperationLabel,
        [string]$PackageId,
        [int]$TimeoutSeconds
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

        $exited = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 500
        }

        $stdoutContent = try { [System.IO.File]::ReadAllText($stdoutFile) } catch { '' }
        $stderrContent = try { [System.IO.File]::ReadAllText($stderrFile) } catch { '' }

        if ($stdoutContent.Trim()) { Write-Log "$OperationLabel stdout [$PackageId] : $($stdoutContent.Trim())" }
        if ($stderrContent.Trim()) { Write-Log "$OperationLabel stderr [$PackageId] : $($stderrContent.Trim())" 'WARN' }

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
                $FailedOps.Add("$DisplayName(install=err)") | Out-Null
                Write-Log "Error while installing $DisplayName : $($_.Exception.Message)" 'ERROR'
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
                $FailedOps.Add("$DisplayName(upgrade=err)") | Out-Null
                Write-Log "Error while upgrading $DisplayName : $($_.Exception.Message)" 'ERROR'
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
