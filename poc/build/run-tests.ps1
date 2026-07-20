<#PSScriptInfo
.VERSION 2026.07.20
.GUID 42a7f3c0-9b21-4d84-8e15-6f2c9a1d0b77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab test automation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

# AmisAd POC test automation driver (see poc/test.md). From a clean machine:
#   [0] remove every amisad.* VM and leftover test-* VM (fresh, reproducible run)
#   [1] build stage once: amisad.build compiles + uploads binaries to the stash,
#       then the build VM is stopped (a second live console steals GUI keystroke
#       focus during the next VM's first login)
#   [2] each scenario in order, fully cold: its chain provisions every tier under
#       the scenario's own user (poc/usernames.md), downloads the binaries from
#       the stash, deploys, runs, and leaves a live VM named amisad.sNNN.<word>.
#       On pass the PREVIOUS scenario's VM is stopped (kept on disk); the latest
#       stays live. On fail the run stops and the VM is left live for debugging.
# Must run ELEVATED (Hyper-V). Stage logs land under -LogDir.
#requires -RunAsAdministrator
param(
    [string]$YurunaRoot = 'c:\git\yuruna',
    [string]$LogDir = (Join-Path ([IO.Path]::GetTempPath()) 'amisad-tests'),
    [switch]$NoConfigGate
)
$ErrorActionPreference = 'Continue'
$ts = Join-Path $YurunaRoot 'test\Test-Sequence.ps1'
if (-not (Test-Path $ts)) { Write-Error "Test-Sequence.ps1 not found at $ts"; exit 1 }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Ordered scenario registry: append here as scenarios are implemented (test.md).
$Scenarios = @(
    @{ Sequence = 'workload.guest.ubuntu.server.24.core.amisad.s001.fulfillment'; FinalVm = 'amisad.s001.fulfillment' }
    @{ Sequence = 'workload.guest.ubuntu.server.24.core.amisad.s002.fitting'; FinalVm = 'amisad.s002.fitting' }
)

function Stop-LabConsole {
    # Only LAB consoles: a live vmconnect can steal GUI keystroke focus during a
    # VM's first login, but operator consoles to unrelated VMs must be left alone.
    Get-Process vmconnect -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match 'amisad\.|test-' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Invoke-Stage {
    # Write-Host (not Write-Output) for progress: the function's OUTPUT stream is
    # its return value, and a polluted return would break the caller's -ne 0 check.
    param([string]$Name, [string]$Sequence)
    Stop-LabConsole
    $out = Join-Path $LogDir "$Name.out.log"
    $err = Join-Path $LogDir "$Name.err.log"
    $stageArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ts), $Sequence)
    if ($NoConfigGate) { $stageArgs += '-NoConfigGate' }
    Write-Host "===== [$Name] $Sequence  $([DateTime]::Now.ToString('s'))  (log: $out) ====="
    $p = Start-Process pwsh -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -ArgumentList $stageArgs
    $p.WaitForExit()
    Write-Host "===== [$Name] exited $($p.ExitCode)  $([DateTime]::Now.ToString('s')) ====="
    if ($p.ExitCode -ne 0) {
        Get-Content $out -Tail 25 -ErrorAction SilentlyContinue | Out-Host
        Get-Content $err -Tail 10 -ErrorAction SilentlyContinue | Out-Host
    }
    return $p.ExitCode
}

function Remove-LabVM {
    param([string]$Name)
    if (Hyper-V\Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "Removing VM $Name"
        Hyper-V\Stop-VM -Name $Name -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
        Hyper-V\Remove-VM -Name $Name -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    # Remove-VM only unregisters; a leftover <vhdPath>\<Name>\ dir would make the
    # next chain's saveDiskSnapshot rename (Move-VMStorage into that dir) fail.
    # Outside the if: a dir stranded with no registered VM is the same collision.
    $vhdRoot = (Hyper-V\Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
    if ($vhdRoot) {
        $vmDir = Join-Path $vhdRoot $Name
        if (Test-Path $vmDir) {
            Write-Host "Removing leftover VM storage $vmDir"
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Headless keystroke/OCR reliability: the runner's cycle path attaches the
# opt-in virtual display (usbmmidd) via Initialize-HostDisplay, but
# Test-Sequence does not - and without a painting display, GUI keystroke
# injection at first login silently mistypes (observed: 'Login incorrect'
# with a correct vault password whenever DWM is not painting). Attach it here
# the same way the runner does; the framework no-ops unless
# YURUNA_VIRTUAL_DISPLAY is truthy (see poc/test.md).
Import-Module (Join-Path $YurunaRoot 'test\modules\Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) {
    Initialize-HostDisplay -HostType 'host.windows.hyper-v'
}

# Refuse to sweep VMs out from under an active Yuruna runner.
$runnerPidFile = Join-Path $YurunaRoot 'test\status\runtime\runner.pid'
if (Test-Path $runnerPidFile) {
    $runnerPid = 0
    try { $runnerPid = [int]((Get-Content $runnerPidFile -Raw).Trim()) } catch { $runnerPid = 0 }
    if ($runnerPid -gt 0 -and (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
        Write-Error "A Yuruna runner (PID $runnerPid) is active; stop it before running the test driver."
        exit 1
    }
}

# --- [0] clean start: a test run assumes and enforces "no pre-built VMs" ---
# Sweep registered lab VMs AND the known lab names (covers storage dirs stranded
# by a prior run whose VM is already unregistered).
$labVms = @(Hyper-V\Get-VM | Where-Object { $_.Name -like 'amisad.*' -or $_.Name -like 'test-*' } | ForEach-Object Name)
$labVms += @('amisad.build', 'amisad.k8s', 'amisad.core') + @($Scenarios | ForEach-Object { $_.FinalVm })
foreach ($vmName in ($labVms | Sort-Object -Unique)) { Remove-LabVM -Name $vmName }
Stop-LabConsole

# --- [1] build once: compile + upload binaries to the stash ---
if ((Invoke-Stage -Name 'build' -Sequence 'workload.guest.ubuntu.server.24.build.amisad.compile') -ne 0) {
    Write-Error "Build stage failed; no binaries in the stash - stopping."
    exit 1
}
Hyper-V\Stop-VM -Name 'amisad.build' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
Write-Output "amisad.build stopped (kept on disk)."

# --- [2] scenarios, in order, each fully cold under its own user ---
$previousVm = $null
foreach ($s in $Scenarios) {
    # A partial prior failure can strand an intermediate tier; a stranded
    # amisad.k8s/amisad.core carries the WRONG user for this scenario and would
    # also collide with this chain's saveDiskSnapshot renames. Clear them.
    Remove-LabVM -Name 'amisad.k8s'
    Remove-LabVM -Name 'amisad.core'
    $name = ($s.FinalVm -replace '^amisad\.', '')
    if ((Invoke-Stage -Name $name -Sequence $s.Sequence) -ne 0) {
        Write-Error "Scenario $($s.FinalVm) FAILED - stopping the run; its VM is left as-is for debugging."
        exit 1
    }
    if ($previousVm) {
        Write-Output "Stopping previous scenario VM $previousVm (kept on disk)."
        Hyper-V\Stop-VM -Name $previousVm -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    $previousVm = $s.FinalVm
}

Write-Output "ALL SCENARIOS PASSED. Latest scenario VM left live: $previousVm"
Write-Output "--- final VM inventory ---"
(Hyper-V\Get-VM | Select-Object Name, State | Format-Table -AutoSize | Out-String -Width 120) | Write-Output
exit 0
