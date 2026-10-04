<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42db3be5-9299-4386-ab00-b638128e3389
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab host portability
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

<#
.SYNOPSIS
    Shared host-portability helpers for the AmisAd host-action scripts
    (Clear-Lab.ps1, Initialize-Lab.ps1). Dot-sourced, not invoked.
.DESCRIPTION
    See https://yuruna.link/42010605-0006.
#>

Set-StrictMode -Version Latest

# --- REGION: Resolve-YurunaRoot
function Resolve-YurunaRoot {
    <#
    .SYNOPSIS
        Locate the Yuruna framework checkout, without hard-coding a path.
    .DESCRIPTION
        See https://yuruna.link/42010605-0006.
    .OUTPUTS
        [string] absolute path; throws when nothing validates.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Explicit)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Explicit))           { [void]$candidates.Add($Explicit) }
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_ROOT))    { [void]$candidates.Add($env:YURUNA_ROOT) }
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_CONFIG_PATH)) {
        $testDir = Split-Path -Parent $env:YURUNA_CONFIG_PATH
        if ($testDir) { [void]$candidates.Add((Split-Path -Parent $testDir)) }
    }
    [void]$candidates.Add((Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..'))
    [void]$candidates.Add((Join-Path -Path $HOME -ChildPath 'git' -AdditionalChildPath 'yuruna'))

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        # Join-Path with forward slashes resolves on every platform; a literal
        # 'test\modules\...' would be one filename containing backslashes on
        # Linux/macOS and silently never match.
        $marker = Join-Path $candidate 'test/modules/Test.HostContract.psm1'
        if (Test-Path -LiteralPath $marker) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw ("Could not locate the Yuruna framework checkout. Tried: {0}. " -f ($candidates -join ', ')) +
          "Pass -YurunaRoot, or set YURUNA_ROOT."
}

# --- REGION: Initialize-AmisAdHost
function Initialize-AmisAdHost {
    <#
    .SYNOPSIS
        Import the framework's host contract + the driver for THIS host, and
        return the detected host type.
    .DESCRIPTION
        After this returns, the unqualified New-VM / Start-VM / Stop-VMForce /
        Remove-VM / Get-VMState / Save-VMDiskSnapshot names resolve to the
        implementation for the running hypervisor -- the drivers deliberately
        shadow Hyper-V's same-named cmdlets, so a caller never needs a
        `Hyper-V\` prefix, which would pin the script to Windows.
    .OUTPUTS
        [string] host type, e.g. 'host.ubuntu.kvm'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$YurunaRoot)

    Import-Module (Join-Path $YurunaRoot 'test/modules/Test.HostContract.psm1') -Global -Force -DisableNameChecking
    $hostType = Get-HostType
    if (-not $hostType) { throw "Could not detect the host type (unsupported platform)." }
    $null = Initialize-YurunaHost -RepoRoot $YurunaRoot -HostType $hostType
    return $hostType
}

# --- REGION: Stop-LabConsole
function Stop-LabConsole {
    <#
    .SYNOPSIS
        Close leftover LAB VM consoles that would steal GUI keystroke focus.
    .DESCRIPTION
        This is a Hyper-V/vmconnect problem specifically: vmconnect grabs
        keyboard focus during a VM's first login and the framework drives that
        login by synthesizing keystrokes. KVM and UTM are driven over VNC
        (vmStart.vncPort) with no separate console process to fight, so there
        is nothing to close there -- the no-op is the correct behavior, not a
        gap. Only consoles whose window title names a lab VM are touched; an
        operator's console to an unrelated VM is left alone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$HostType)

    if ($HostType -ne 'host.windows.hyper-v') {
        Write-Verbose "Stop-LabConsole: no separate console process on '$HostType' (VNC-driven); nothing to close."
        return
    }
    if ($PSCmdlet.ShouldProcess('lab vmconnect consoles', 'Stop process')) {
        Get-Process vmconnect -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match 'amisad|test-' } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
