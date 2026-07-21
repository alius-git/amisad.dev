<#PSScriptInfo
.VERSION 2026.07.21
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
    Clear the AmisAd POC lab: stop every running "amisad*" VM, then sweep
    orphaned VM files.
.DESCRIPTION
    Two steps, in order:

      1. Turn off every running Hyper-V VM whose name starts with "amisad"
         (the demo topology: amisad-build, amisad-core, amisad-edge-a/-b).
         Stopped and non-"amisad" VMs are left untouched.

      2. Run the Yuruna framework's test/Remove-OrphanedVMFiles.ps1 with -Force
         to sweep VM files that no longer belong to a registered VM, without a
         confirmation prompt. That script is host-neutral (it detects the host
         type); this project's demo runs on Windows Hyper-V, which is why the
         stop step above uses the Hyper-V module.

    Stopping Hyper-V VMs and the Hyper-V orphan sweep both need elevation, so
    this script requires Administrator.
.PARAMETER YurunaRoot
    Path to the Yuruna framework checkout that holds
    test/Remove-OrphanedVMFiles.ps1. Defaults to c:\git\yuruna.
.EXAMPLE
    pwsh test/Clear-Project.ps1
.EXAMPLE
    pwsh test/Clear-Project.ps1 -YurunaRoot D:\git\yuruna
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$YurunaRoot = 'c:\git\yuruna'
)

Set-StrictMode -Version Latest

# --- 1) Stop all running amisad* VMs ------------------------------------
$running = @()
try {
    $running = @(Hyper-V\Get-VM -Name 'amisad*' -ErrorAction Stop |
        Where-Object { $_.State -eq 'Running' })
} catch {
    Write-Warning "Could not enumerate Hyper-V VMs: $($_.Exception.Message)"
}

if ($running.Count -eq 0) {
    Write-Information -MessageData 'No running amisad* VMs to stop.' -InformationAction Continue
} else {
    foreach ($vm in $running) {
        if ($PSCmdlet.ShouldProcess($vm.Name, 'Turn off running VM')) {
            Hyper-V\Stop-VM -Name $vm.Name -TurnOff -Force
            Write-Information -MessageData "Stopped $($vm.Name)." -InformationAction Continue
        }
    }
}

# --- 2) Sweep orphaned VM files (host-neutral; -Force skips the prompt) --
$removeScript = Join-Path -Path $YurunaRoot -ChildPath 'test/Remove-OrphanedVMFiles.ps1'
if (-not (Test-Path -LiteralPath $removeScript)) {
    throw "Remove-OrphanedVMFiles.ps1 not found at '$removeScript' (set -YurunaRoot)."
}

$exitCode = 0
if ($PSCmdlet.ShouldProcess($removeScript, 'Sweep orphaned VM files (-Force)')) {
    # Child process isolates the framework script's own `exit` and elevation
    # is inherited from this (already elevated) session.
    pwsh -NoProfile -File $removeScript -Force
    $exitCode = $LASTEXITCODE
}

exit $exitCode
