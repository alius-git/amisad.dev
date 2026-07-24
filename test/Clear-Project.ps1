<#PSScriptInfo
.VERSION 2026.07.28
.GUID 42a3f7c9-5e21-4b8d-9c46-7f0a2d63e1b5
.AUTHOR Alisson Sol et al.
.Copyright (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab cleanup
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Tear down the AmisAd POC lab to a known-clean host: remove every lab VM
    (and its storage), then sweep orphaned VM files.
.DESCRIPTION
    The teardown half of the end-to-end pass (Set-Resource.ps1 builds it back
    up). Steps, in order:

      1. Refuse to run if a Yuruna runner owns runner.pid -- it would race the
         live cycle's VMs.
      2. Close lab vmconnect consoles (they steal GUI keystroke focus).
      3. Remove every lab VM AND its storage dir: names matching amisad-* /
         amisad.* / test-*, plus the known topology names. Remove-VM only
         unregisters, so a stranded storage dir is deleted too (a leftover dir
         breaks the next chain's saveDiskSnapshot rename).
      4. Run the framework's Remove-OrphanedVMFiles.ps1 -Force to sweep files
         no longer tied to any registered VM.

    Everything here needs elevation (Hyper-V), so Administrator is required.
.PARAMETER YurunaRoot
    Path to the Yuruna framework checkout that holds
    test/Remove-OrphanedVMFiles.ps1. Defaults to c:\git\yuruna.
.EXAMPLE
    pwsh test/Clear-Project.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$YurunaRoot = 'c:\git\yuruna'
)

Set-StrictMode -Version Latest

# The known demo topology, swept by exact name even if Get-VM's wildcard misses
# a renamed-mid-chain remnant (amisad-core-k8s is the intermediate rename).
$TopologyVms = @('amisad-build', 'amisad-edge-a', 'amisad-edge-b', 'amisad-core', 'amisad-core-k8s')

function Stop-LabConsole {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    # Only LAB consoles: a live vmconnect can steal GUI keystroke focus during a
    # VM's first login; operator consoles to unrelated VMs are left alone.
    if ($PSCmdlet.ShouldProcess('lab vmconnect consoles', 'Stop process')) {
        Get-Process vmconnect -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match 'amisad|test-' } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Remove-LabVM {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name)
    if (Hyper-V\Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($Name, 'Remove VM')) {
            Write-Information -MessageData "Removing VM $Name" -InformationAction Continue
            Hyper-V\Stop-VM -Name $Name -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Hyper-V\Remove-VM -Name $Name -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    # Delete a storage dir stranded by Remove-VM (or by a VM that never registered):
    # a leftover <vhdPath>\<Name>\ collides with the next saveDiskSnapshot rename.
    $vhdRoot = (Hyper-V\Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
    if ($vhdRoot) {
        $vmDir = Join-Path $vhdRoot $Name
        if ((Test-Path $vmDir) -and $PSCmdlet.ShouldProcess($vmDir, 'Remove leftover VM storage')) {
            Write-Information -MessageData "Removing leftover VM storage $vmDir" -InformationAction Continue
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 1) Refuse to sweep VMs out from under an active Yuruna runner -----------
# Only when run standalone. Inside a runner cycle the orchestration invokes this
# as its teardown step (set-resource), so the runner IS expected to be live:
# $env:YURUNA_CYCLE_CONTEXT -- published by the orchestrator before each step and
# inherited by this child pwsh (its absence == standalone; see Get-CycleContext)
# -- marks that in-cycle invocation and skips the guard. Absent it, an operator
# ran this by hand and the guard still refuses to race an active cycle's VMs.
if (-not $env:YURUNA_CYCLE_CONTEXT) {
    $runnerPidFile = Join-Path $YurunaRoot 'test\status\runtime\runner.pid'
    if (Test-Path $runnerPidFile) {
        $runnerPid = 0
        try { $runnerPid = [int]((Get-Content $runnerPidFile -Raw).Trim()) } catch { $runnerPid = 0 }
        if ($runnerPid -gt 0 -and (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
            throw "A Yuruna runner (PID $runnerPid) is active; stop it before clearing the project."
        }
    }
}

# --- 2) Close lab consoles ---------------------------------------------------
Stop-LabConsole

# --- 3) Remove every lab VM + its storage ------------------------------------
$labVms = @(Hyper-V\Get-VM -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'amisad-*' -or $_.Name -like 'amisad.*' -or $_.Name -like 'test-*' } |
    ForEach-Object Name)
$labVms += $TopologyVms
$removed = 0
foreach ($vmName in ($labVms | Sort-Object -Unique)) {
    Remove-LabVM -Name $vmName
    $removed++
}
Write-Information -MessageData "Lab teardown swept $removed candidate VM name(s)." -InformationAction Continue

# --- 4) Sweep orphaned VM files (host-neutral; -Force skips the prompt) ------
$removeScript = Join-Path -Path $YurunaRoot -ChildPath 'test/Remove-OrphanedVMFiles.ps1'
if (-not (Test-Path -LiteralPath $removeScript)) {
    throw "Remove-OrphanedVMFiles.ps1 not found at '$removeScript' (set -YurunaRoot)."
}

$exitCode = 0
if ($PSCmdlet.ShouldProcess($removeScript, 'Sweep orphaned VM files (-Force)')) {
    # Child process isolates the framework script's own `exit`; elevation is
    # inherited from this (already elevated) session.
    pwsh -NoProfile -File $removeScript -Force
    $exitCode = $LASTEXITCODE
}

exit $exitCode
