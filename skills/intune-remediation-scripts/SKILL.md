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
2. DETECT     Write detect.ps1 — read-only, exits 0 or 1.
3. REMEDIATE  Write remediate.ps1 — idempotent, exits 0 on success.
4. TEST       Run both as SYSTEM locally via PsExec -i -s before upload.
5. PACKAGE    Verify encoding, line endings, no BOM issues.
6. PILOT      Deploy to a 5-10 device group, watch the portal for 24h.
7. ROLLOUT    Expand only after pilot shows >95% success rate.
```

### Step 1 — Specify compliance in one sentence

Bad: "Make sure BitLocker is configured properly."
Good: "The OS volume is encrypted with BitLocker using XTS-AES 256 and a TPM+PIN protector."

If you can't write that sentence, you can't write the detection.

### Step 2 — detect.ps1 (read-only, no side effects)

```powershell
$ErrorActionPreference = 'Stop'
try {
    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive
    if ($vol.ProtectionStatus -eq 'On' -and $vol.EncryptionMethod -eq 'XtsAes256') {
        Write-Output "Compliant: $($vol.EncryptionMethod), $($vol.ProtectionStatus)"
        exit 0
    }
    Write-Output "NonCompliant: method=$($vol.EncryptionMethod) status=$($vol.ProtectionStatus)"
    exit 1
} catch {
    Write-Output "DetectError: $($_.Exception.Message)"
    exit 1
}
```

Detection MUST NOT change state. If detection has side effects, the portal compliance numbers become meaningless.

### Step 3 — remediate.ps1 (idempotent, transcripted)

```powershell
$ErrorActionPreference = 'Stop'
$LogDir = 'C:\ProgramData\IntuneRemediations'
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path "$LogDir\bitlocker-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" -Force

try {
    # Idempotent: enabling on an already-enabled volume should be a no-op or handled.
    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive
    if ($vol.ProtectionStatus -ne 'On') {
        Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes256 -TpmProtector
    }
    Write-Output "Remediated"
    exit 0
} catch {
    Write-Output "RemediateError: $($_.Exception.Message)"
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
```

### Step 4 — Test as SYSTEM, not as your user

Your dev account has profile, mapped drives, and `HKCU` populated. SYSTEM has none of that. Test with PsExec from an elevated prompt:

```
PsExec.exe -i -s -accepteula powershell.exe -ExecutionPolicy Bypass -File .\detect.ps1
echo %ERRORLEVEL%
PsExec.exe -i -s -accepteula powershell.exe -ExecutionPolicy Bypass -File .\remediate.ps1
echo %ERRORLEVEL%
```

Then run remediate **three times in a row**. Exit code must stay `0` and the system state must not drift. That's idempotence.

### Step 5 — Package

- Save as **UTF-8 with BOM** (PS 5.1 mis-decodes accented characters in plain UTF-8).
- Line endings: CRLF.
- No external module dependencies the endpoint doesn't already have. If you need a module, vendor the `.psm1` and `Import-Module` from a `$PSScriptRoot`-relative path.
- Keep each script under 200 KB (portal limit).

### Step 6 — Pilot

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

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "It works when I run it in my PowerShell window" | Your window is interactive, 64-bit, with your profile. Intune is none of those. Test with PsExec -s. |
| "Write-Host is fine, I see it in the console" | Intune captures stdout. `Write-Host` writes to the host UI which doesn't exist under SYSTEM — your message vanishes. |
| "I'll add the transcript later" | Without a transcript, the only debug info you have on a failing endpoint is the truncated 2048-char stdout. Add it on day one. |
| "Detection can also fix small things, it's faster" | A detection with side effects breaks the portal's compliance metric. You'll never know if the fix actually held. |
| "Idempotence doesn't matter, Intune only runs it once if it succeeds" | Intune re-runs detection on every cycle. If your remediation isn't idempotent, a transient failure on the second cycle silently corrupts state. |
| "Exit 1 means failure, I'll use exit 2 for partial success" | There is no partial success. Intune buckets everything as `0` or `not 0`. Custom exit codes are noise. |
| "I'll skip BOM, UTF-8 is UTF-8" | PS 5.1 defaults to ANSI when there's no BOM. Your `é` becomes `Ã©` on the endpoint. |

## Red Flags

- `Write-Host` anywhere in the script
- `Read-Host`, `-Confirm`, `pause`, `[Console]::ReadKey()` — anything interactive
- Exit codes other than `0` or `1`
- Detection script that calls `Set-`, `New-`, `Remove-`, `Stop-`, `Start-` on real resources
- Hardcoded paths under `C:\Users\<name>\` or `$env:USERPROFILE`
- `HKCU:\` reads or writes from a script meant to run as SYSTEM
- No `Start-Transcript` in the remediation script
- No try/catch around the main work — uncaught exceptions exit with code `1` but with no useful stdout
- stdout that includes a stack trace (will be truncated, dominates the 2048 chars budget)
- Script saved without BOM and contains non-ASCII characters
- Remediation that doesn't check current state before acting (e.g. blindly re-installs something already installed)

## Verification

Before uploading to the Intune portal:

- [ ] `detect.ps1` and `remediate.ps1` exit only `0` or `1`
- [ ] Detection has zero side effects (grep the script for write-cmdlets — none should be there)
- [ ] Remediation runs three times consecutively under SYSTEM, exit `0` each time, end state unchanged after run 1
- [ ] Both scripts tested via `PsExec.exe -i -s` and observed exit codes match expectations
- [ ] Transcript file is created under `C:\ProgramData\...` and contains the run output
- [ ] stdout from both scripts is under 2048 characters, single-line status format
- [ ] No `Write-Host`, no `Read-Host`, no interactive prompts (`grep -E 'Write-Host|Read-Host|pause' *.ps1` returns nothing)
- [ ] Files saved as UTF-8 with BOM, CRLF line endings
- [ ] Script set to "Run script in 64-bit PowerShell" in the Intune assignment
- [ ] Piloted on ≥5 devices for ≥24h with >95% success before broad rollout