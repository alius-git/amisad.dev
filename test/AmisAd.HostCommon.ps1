<#PSScriptInfo
.VERSION 2026.08.28
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
    A host action that calls `Hyper-V\Get-VM` directly, or defaults its root to
    a drive-letter path, cannot run on host.ubuntu.kvm or host.macos.utm: the
    Hyper-V module is absent, and a leading 'c:' is read as a PSDrive name
    there, so Join-Path fails with "Cannot find drive".

    Yuruna solves this: host/<host-type>/modules/Yuruna.Host.psm1 exports ONE
    contract (New-VM / Start-VM / Stop-VMForce / Remove-VM / Get-VMState /
    Save-VMDiskSnapshot / ...) implemented per hypervisor, and
    Initialize-YurunaHost imports the right driver for the detected host. These
    helpers wire the project into that contract so the host actions carry no
    hypervisor branches of their own.
#>

Set-StrictMode -Version Latest

function Resolve-YurunaRoot {
    <#
    .SYNOPSIS
        Locate the Yuruna framework checkout, without hard-coding a path.
    .DESCRIPTION
        Tried in order, first one that actually looks like a checkout wins:

          1. -Explicit (the caller's -YurunaRoot), so an operator override
             always beats discovery.
          2. $env:YURUNA_ROOT, for a host whose layout matches nothing below.
          3. $env:YURUNA_CONFIG_PATH -- the runner publishes the resolved
             '<root>/test/test.config.yml' before every step and the host
             action inherits it, which makes this exact in-cycle.
          4. <this file>/../.. -- the cycle clones the project to
             '<root>/project', so the project's test/ dir sits two levels
             under the framework root.
          5. $HOME/git/yuruna, for a standalone run outside any cycle (an
             operator invoking the teardown by hand). That is where the
             bootstrap installers clone on every platform, Windows included,
             so one candidate covers all three hosts and no drive letter is
             written down anywhere.

        A candidate counts only if test/modules/Test.HostContract.psm1 is
        there: that is the module both host actions import, so validating on
        it means a match can never resolve to a checkout too old or too
        partial to drive.
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
