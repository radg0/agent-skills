---
name: intune-remediation-scripts
description: Guides agents through writing PowerShell 5.1 detection and remediation scripts for Microsoft Intune Proactive Remediations. Use when authoring detect+remediate script pairs, packaging scripts for the Intune portal, or hardening scripts that run unattended under the SYSTEM context on managed Windows endpoints.
---

# Intune Remediation Scripts

## Overview

Intune Proactive Remediations run a **detection** script and, if it reports non-compliance, a **remediation** script — both unattended, under SYSTEM, in Windows PowerShell 5.1. Intune only sees two signals: the script's **exit code** (`0` = compliant, `1` = non-compliant) and the first **2048 characters of stdout**. Everything else is invisible. This skill enforces the patterns that survive that environment.

## When to Use

- Writing a new Proactive Remediation (detect.ps1 + remediate.ps1 pair)
- Modifying an existing remediation script that misbehaves on real endpoints but works on your dev box
- Migrating a manual PowerShell fix into an unattended Intune script
- Reviewing a remediation before uploading to the Intune portal

**When NOT to use:** Win32 app install scripts (different exit code semantics), Configuration Profiles, scripts that genuinely require user context only (use the "Run as logged-on user" toggle and a different pattern).

## The Workflow

```
1. SPECIFY    What state is "compliant"? Define it in one sentence.
2. LOGGING    Stand up the shared logging scaffold (paths + Write-Log).
3. DETECT     Write detect.ps1 — read-only, exits 0 or 1.
4. REMEDIATE  Write remediate.ps1 — idempotent, exits 0 on success.
5. TEST       Run both as SYSTEM locally via PsExec -i -s before upload.
6. PACKAGE    Verify encoding, line endings, no BOM issues.
7. PILOT      Deploy to a 5-10 device group, watch the portal for 24h.
8. ROLLOUT    Expand only after pilot shows >95% success rate.
```

### Step 1 — Specify compliance in one sentence

Bad: "Make sure BitLocker is configured properly."
Good: "The OS volume is encrypted with BitLocker using XTS-AES 256 and a TPM+PIN protector."

If you can't write that sentence, you can't write the detection.

### Step 2 — Header banner + logging convention (shared by detect + remediate)

#### Script header banner

Every script opens with a fixed banner so an admin reading `C:\_AutoPTasks\` six months from now knows what the file is, where it runs, and which gotchas matter:

```powershell
#########################################################################################################################
#
# Script  : <Job> <Detection|Remediation>
# Purpose : <one-line goal — what state this script enforces or detects>
# Context : <SYSTEM | USER>
# Notes   : <optional — non-obvious constraints, foot-guns, prior incidents that shaped the script>
#
#########################################################################################################################
```

The `Notes` block is where you record **why** the script is shaped the way it is — a past incident, an API quirk, a registry path you must NOT touch. Future-you (and the next admin) read this before editing. Skip it only if there's truly nothing surprising.

Example with a hard-won note:

```powershell
#########################################################################################################################
#
# Script  : Autodesk License Server Remediation
# Purpose : Set ADSKFLEX_LICENSE_FILE machine variable to point to the network license server
# Context : SYSTEM
# Notes   : Uses [Environment]::SetEnvironmentVariable(..., 'Machine') exclusively.
#           NEVER writes to HKLM:\...\Session Manager\Environment via New-Item / Set-ItemProperty
#           because New-Item -Force on that key wipes Path, PSModulePath, TEMP, etc.
#
#########################################################################################################################
```

#### Logging convention

Intune only surfaces 2048 chars of stdout. For real diagnostics on a failing endpoint you need a **persistent log file on disk** that survives the script run. Every script — detection included — writes to:

```
C:\_AutoPTasks\LOG\<yyyy-MM-dd>\<yyyy-MM-dd_HH-mm-ss>_<Job>_<Context>.log
```

- `<Job>` = short identifier of the remediation (e.g. `Winget`, `BitLocker`, `AutodeskLicense`)
- `<Context>` = `SYSTEM` or `USER` depending on the assignment
- Daily folder rolls over automatically; per-run filename keeps re-runs distinct

This replaces `Start-Transcript`. Transcripts capture too much noise (banner, PS prep, every line of output) and break when a script re-imports modules or redirects streams. A purpose-built logger gives you levelled, parseable lines.

Use this header in **both** scripts:

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_<Job>_<Context>.log"

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
```

The `try/catch` around `Add-Content` and the `if ($script:LogFile)` guard mean a logging failure (locked file, missing folder) never breaks the actual remediation logic. **Log writes are best-effort; the script's job is the script's job.**

Organize the rest of the script in three regions: `#region Configuration`, `#region Functions`, `#region Main` — easy to fold in an editor and easy to diff across remediations.

### Step 3 — detect.ps1 (read-only, no side effects)

```powershell
#########################################################################################################################
#
# Script  : BitLocker Detection
# Purpose : Detect whether the OS volume is protected with BitLocker XTS-AES 256
# Context : SYSTEM
#
#########################################################################################################################

#region Configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_BitLocker_Detection_SYSTEM.log"
#endregion

#region Functions
function Initialize-Folders { <# as above #> }
function Write-Log          { <# as above #> }
#endregion

#region Main
try {
    Initialize-Folders
    Write-Log "BitLocker detection started"
    Write-Log "Execution context : $(whoami)"

    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive
    Write-Log "ProtectionStatus=$($vol.ProtectionStatus) Method=$($vol.EncryptionMethod)"

    if ($vol.ProtectionStatus -eq 'On' -and $vol.EncryptionMethod -eq 'XtsAes256') {
        $status = "Compliant | $($vol.EncryptionMethod), $($vol.ProtectionStatus)"
        Write-Log $status 'OK'
        Write-Output $status
        exit 0
    }

    $status = "NonCompliant | method=$($vol.EncryptionMethod) status=$($vol.ProtectionStatus)"
    Write-Log $status 'WARN'
    Write-Output $status
    exit 1
}
catch {
    $err = "DetectError | $($_.Exception.Message)"
    Write-Log $err 'ERROR'
    Write-Output $err
    exit 1
}
#endregion
```

Detection MUST NOT change state. Logging (writing a file under `C:\_AutoPTasks\`) is the *only* allowed side effect. If detection runs `Set-`, `New-`, `Remove-`, `Enable-`, etc. on real resources, the portal compliance numbers become meaningless.

### Step 4 — remediate.ps1 (idempotent, logged)

```powershell
#########################################################################################################################
#
# Script  : BitLocker Remediation
# Purpose : Enable BitLocker XTS-AES 256 with TPM protector on the OS volume if not already on
# Context : SYSTEM
#
#########################################################################################################################

#region Configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DateStamp     = Get-Date -Format 'yyyy-MM-dd'
$DateTimeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$RootPath       = 'C:\_AutoPTasks'
$LogPath        = Join-Path $RootPath "LOG\$DateStamp"
$script:LogFile = Join-Path $LogPath "${DateTimeStamp}_BitLocker_Remediation_SYSTEM.log"
#endregion

#region Functions
function Initialize-Folders { <# as above #> }
function Write-Log          { <# as above #> }
#endregion

#region Main
try {
    Initialize-Folders
    Write-Log "BitLocker remediation started"
    Write-Log "Execution context : $(whoami)"

    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive
    Write-Log "Pre-state : ProtectionStatus=$($vol.ProtectionStatus)"

    if ($vol.ProtectionStatus -ne 'On') {
        Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes256 -TpmProtector
        Write-Log "Enable-BitLocker invoked" 'OK'
    }
    else {
        Write-Log "Already protected, no action" 'INFO'
    }

    $status = "Remediated"
    Write-Log $status 'OK'
    Write-Output $status
    exit 0
}
catch {
    $err = "RemediateError | $($_.Exception.Message)"
    Write-Log $err 'ERROR'
    Write-Output $err
    exit 1
}
#endregion
```

Both scripts share the exact same scaffolding — only the `<Job>` token in the log filename and the body inside `try` differ. Copy the scaffold, change two lines, fill in the logic.

### Step 5 — Test as SYSTEM, not as your user

Your dev account has profile, mapped drives, and `HKCU` populated. SYSTEM has none of that. Test with PsExec from an elevated prompt:

```
PsExec.exe -i -s -accepteula powershell.exe -ExecutionPolicy Bypass -File .\detect.ps1
echo %ERRORLEVEL%
PsExec.exe -i -s -accepteula powershell.exe -ExecutionPolicy Bypass -File .\remediate.ps1
echo %ERRORLEVEL%
```

Then run remediate **three times in a row**. Exit code must stay `0` and the system state must not drift. That's idempotence. Inspect `C:\_AutoPTasks\LOG\<today>\` afterwards — three log files should be there, each ending with an `OK` line.

### Step 6 — Package

- Save as **UTF-8 with BOM** (PS 5.1 mis-decodes accented characters in plain UTF-8).
- Line endings: CRLF.
- No external module dependencies the endpoint doesn't already have. If you need a module, vendor the `.psm1` and `Import-Module` from a `$PSScriptRoot`-relative path.
- Keep each script under 200 KB (portal limit).

### Step 7 — Pilot

Deploy to a small group, then in the Intune portal check:
- **Without issues** count rising → detection works
- **Issue remediated** count matching → remediation works
- **Failed to remediate** > 5% → stop, read the error column, fix, redeploy

## PowerShell 5.1 + SYSTEM Context Patterns

| Trap | Why it bites under Intune | Pattern |
|---|---|---|
| `$env:USERPROFILE` | Empty under SYSTEM | Use `$env:ProgramData` or resolve the active user's SID via `HKU` |
| `HKCU:\` operations | SYSTEM's HKCU is `.DEFAULT`, not the logged-in user | Enumerate `HKEY_USERS\<SID>`, skip `.DEFAULT` and `_Classes` hives |
| `Write-Host` | Doesn't go to stdout in PS 5.1 — invisible to Intune | Use `Write-Output` only |
| `New-Item -Force` on existing registry key | Recreates the key **empty** — wipes every existing value, including system-critical ones like `Path`, `PSModulePath`, `TEMP` if you target `HKLM:\...\Session Manager\Environment` | Use `Set-ItemProperty` / `New-ItemProperty` to write values; never `-Force` on a key you didn't create. See "Registry Safety" below. |
| Output > 2048 chars | Truncated in portal, often mid-JSON | Emit one short status line; log details to transcript |
| `Get-CimInstance` on missing namespace | Throws ugly stack trace SYSTEM has no perms to read | Wrap in try/catch, exit 1 with a clean message |
| 32-bit PowerShell host | Some registry/WMI views differ | In Intune assignment, set "Run script in 64-bit PowerShell" = Yes |
| Unicode in script body | `’` becomes `â€™` if saved as ANSI | Save as UTF-8 with BOM, verify with a hex editor once |
| `Read-Host`, `-Confirm`, `Pause` | Hangs forever, script timeout kills it | Forbidden. No interactive cmdlets, ever |

### Reading another user's HKCU from SYSTEM

```powershell
$loggedOnUser = (Get-CimInstance Win32_ComputerSystem).UserName  # DOMAIN\user, may be $null
if ($loggedOnUser) {
    $sid = (New-Object System.Security.Principal.NTAccount($loggedOnUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $hkuPath = "Registry::HKEY_USERS\$sid\Software\..."
    # Read via $hkuPath instead of HKCU:\
}
```

## Registry Safety

Remediation scripts often touch the registry under SYSTEM. There are no guardrails: a single wrong cmdlet can wipe state across the whole machine, irreversibly. These rules exist because of real incidents — internalize them.

### Never use `New-Item -Force` on a registry key that may already exist

`New-Item -Force` does **not** merge or "ensure exists". It **deletes the key and recreates it empty**, dropping every value the key contained. On a key you don't own, this is catastrophic and irreversible without a registry backup. The canonical foot-gun:

```powershell
# CATASTROPHIC — wipes Path, PSModulePath, TEMP, ComSpec, OS, windir, every Machine env var
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name 'MY_VAR' -Value 'x'
```

The key already exists. `New-Item -Force` doesn't error — it silently nukes the contents. Once `Path` is gone, every subsequent process loses access to system binaries and the machine is effectively bricked until a registry backup is restored or the variables are rebuilt by hand.

Rules:
- If the key **may already exist**, write the value with `Set-ItemProperty` / `New-ItemProperty`. They touch only the named value, not siblings.
- Use `New-Item` (without `-Force`) only when creating a key you know does not exist, and you want it to fail if it does.
- To "ensure a key exists" idempotently: `if (-not (Test-Path $key)) { New-Item -Path $key | Out-Null }` — never `-Force`.
- This applies recursively: `Remove-Item -Recurse` on a key you didn't create is the same class of mistake.

### Use the right API for environment variables

For machine-scope environment variables, use the .NET API exclusively:

```powershell
[Environment]::SetEnvironmentVariable('MY_VAR', 'value', 'Machine')
```

It writes to `HKLM:\...\Session Manager\Environment` correctly and atomically without touching siblings. Hand-rolling `Set-ItemProperty` on that key works too, but every line you add near that key is a chance to introduce the `New-Item -Force` mistake. The .NET API removes the temptation.

### Always have a way back

Before deploying any script that touches the registry under `HKLM:\SYSTEM\` or `HKLM:\SOFTWARE\Microsoft\` to real endpoints:
- Test in a VM, with a snapshot taken **before** the run.
- `reg export "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" env-backup.reg` on the VM before testing — if the script wipes it, this file is your only path back.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "It works when I run it in my PowerShell window" | Your window is interactive, 64-bit, with your profile. Intune is none of those. Test with PsExec -s. |
| "Write-Host is fine, I see it in the console" | Intune captures stdout. `Write-Host` writes to the host UI which doesn't exist under SYSTEM — your message vanishes. |
| "I'll add the log later" | Without a log file under `C:\_AutoPTasks\LOG\`, the only debug info you have on a failing endpoint is the truncated 2048-char stdout. Add it on day one — in detection too. |
| "Detection is read-only, no need to log it" | When detection lies (false positive/negative), you have nothing to diff against. Log every detection run; the read-only rule applies to system state, not to your own log file. |
| "Start-Transcript is simpler" | It is, but it captures every banner, prompt, and stream redirect — and gets confused when the script imports modules. A purpose-built `Write-Log` produces parseable, levelled lines you can grep. |
| "Detection can also fix small things, it's faster" | A detection with side effects breaks the portal's compliance metric. You'll never know if the fix actually held. |
| "Idempotence doesn't matter, Intune only runs it once if it succeeds" | Intune re-runs detection on every cycle. If your remediation isn't idempotent, a transient failure on the second cycle silently corrupts state. |
| "Exit 1 means failure, I'll use exit 2 for partial success" | There is no partial success. Intune buckets everything as `0` or `not 0`. Custom exit codes are noise. |
| "I'll skip BOM, UTF-8 is UTF-8" | PS 5.1 defaults to ANSI when there's no BOM. Your `é` becomes `Ã©` on the endpoint. |
| "`-Force` just means 'don't error if it exists'" | On `New-Item` for registry keys, `-Force` means **delete and recreate the key empty** — every existing value is dropped. A real script using this against `HKLM:\...\Session Manager\Environment` wiped the system `Path` and bricked the dev machine. Never use `-Force` on a registry key you didn't create. |
| "I'll just write directly to the env registry key, it's the same backing store" | Same backing store, far more ways to mis-fire. `[Environment]::SetEnvironmentVariable(..., 'Machine')` writes the one value you want, atomically, with no chance of nuking a sibling. Use it. |

## Red Flags

- `Write-Host` anywhere in the script
- `Read-Host`, `-Confirm`, `pause`, `[Console]::ReadKey()` — anything interactive
- Exit codes other than `0` or `1`
- Detection script that calls `Set-`, `New-`, `Remove-`, `Stop-`, `Start-` on real resources
- Hardcoded paths under `C:\Users\<name>\` or `$env:USERPROFILE`
- `HKCU:\` reads or writes from a script meant to run as SYSTEM
- No header banner (`Script` / `Purpose` / `Context` lines) at the top of the file
- `New-Item -Force` targeting any registry key under `HKLM:\` or `HKCU:\` — high risk of wiping the key's existing values
- Direct `Set-ItemProperty` / `New-Item` on `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` instead of `[Environment]::SetEnvironmentVariable(..., 'Machine')`
- `Remove-Item -Recurse` on a registry key the script didn't create
- No log file written under `C:\_AutoPTasks\LOG\` — neither in detection nor remediation
- `Add-Content` / `Out-File` calls without try/catch — a locked log file should never break the actual remediation
- No try/catch around the main work — uncaught exceptions exit with code `1` but with no useful stdout
- stdout that includes a stack trace (will be truncated, dominates the 2048 chars budget)
- Script saved without BOM and contains non-ASCII characters
- Remediation that doesn't check current state before acting (e.g. blindly re-installs something already installed)

## Verification

Before uploading to the Intune portal:

- [ ] `detect.ps1` and `remediate.ps1` exit only `0` or `1`
- [ ] Detection has zero side effects on system state (logging to `C:\_AutoPTasks\LOG\` is the only allowed write)
- [ ] Remediation runs three times consecutively under SYSTEM, exit `0` each time, end state unchanged after run 1
- [ ] Both scripts tested via `PsExec.exe -i -s` and observed exit codes match expectations
- [ ] A log file appears under `C:\_AutoPTasks\LOG\<today>\` after each run, with parseable `[timestamp] [LEVEL] message` lines
- [ ] `Write-Log` is wrapped in try/catch so a locked or unwritable log file never breaks the remediation
- [ ] `grep -nE 'New-Item.*-Force.*HK(LM|CU):' *.ps1` returns nothing — no `-Force` on registry keys
- [ ] All Machine env-var writes go through `[Environment]::SetEnvironmentVariable(..., 'Machine')`, not direct registry edits
- [ ] stdout from both scripts is under 2048 characters, single-line status format
- [ ] No `Write-Host`, no `Read-Host`, no interactive prompts (`grep -E 'Write-Host|Read-Host|pause' *.ps1` returns nothing)
- [ ] Files saved as UTF-8 with BOM, CRLF line endings
- [ ] Script set to "Run script in 64-bit PowerShell" in the Intune assignment
- [ ] Piloted on ≥5 devices for ≥24h with >95% success before broad rollout