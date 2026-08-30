<#PSScriptInfo
.VERSION 2026.08.30
.GUID 42fa58fd-5d9d-4319-8816-8b5fe971bdbe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab build warmup
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
    Build + start the AmisAd POC topology on a clean host (the "warm-up" half of
    the end-to-end pass; Clear-Lab.ps1 is the teardown half that runs first).
    Runs on any Yuruna host type (Hyper-V, KVM, UTM).
.DESCRIPTION
    Ports the build stages of poc/build/run-tests.ps1 (everything except the
    scenario loop, which the amisad.end-to-end.yml orchestration sequence drives).
    Assumes the host is already clean (Clear-Lab.ps1 ran) and <RepoRoot>/project
    is already cloned (Debug-TestSequence, running the orchestration sequence, clones
    once, so guest builds run with -NoProjectClone). Stages, in order:

      0. Generate the core->edge demo keypair (once per host).
      1. Resolve the stash service and publish its address for the cycle
         (discovered or pinned; no stash found stops the pass immediately).
      2. Build once: compile + upload binaries to the stash (amisad-build).
      3. Edge VMs: provision + snapshot amisad-edge-a / -b, shrink to 4GB.
      4. vm-core: k8s + PostgreSQL + NATS + deploy 10 services + demo users.
      5. Start both edges and wait for their boot-time IP reports (the fresh
         handoff/*.ip.txt the scenarios resolve the edge from).

    Leaves amisad-core + both edges live.

    PRIVILEGE is asserted at runtime against the DETECTED host rather than
    declared with '#requires -RunAsAdministrator': what building a VM takes
    differs per host -- Administrator on Hyper-V, libvirt group membership on
    KVM, the invoking user's own utmctl session on UTM -- and a static
    requirement reads as "root" on Linux/macOS, which would refuse exactly the
    hosts this script claims to run on. Test-HostRequirement asks the host
    driver what applies and explains what is missing.

    PORTABILITY. VM lifecycle goes through the Yuruna host contract
    (Get-VMState / Start-VM / Stop-VMForce, loaded by Initialize-AmisAdHost),
    so no step names a hypervisor. Two Hyper-V-specific TUNINGS remain, each
    guarded and each a no-op elsewhere by design rather than omission:

      * Install-media stripping + checkpoint retake. A renamed/restored Hyper-V
        VM keeps ABSOLUTE references into the autoinstall DVD dir; later cycles
        overwrite it with files ACL'd to a newer VM and the older VM then fails
        to start with 0x80070005. KVM and UTM attach the cloud-init seed by
        path per boot with no ACL inheritance, so there is nothing to strip.
      * The 4GB edge shrink. Hyper-V has a live Set-VM; on KVM/UTM the guest
        size is a provisioning-time property (the sequence's memoryStartupBytes
        variable), so it cannot -- and need not -- be changed after the fact.
.PARAMETER YurunaRoot
    Yuruna framework checkout that holds test/Debug-TestSequence.ps1. Optional --
    see Resolve-YurunaRoot for the discovery order.
.PARAMETER LogDir
    Per-stage Debug-TestSequence logs. Defaults to a folder inside the running
    cycle so the logs travel with the cycle's other artifacts, and to
    <temp>/amisad-tests when this runs outside a cycle.
.PARAMETER NoConfigGate
    Forwarded to each guest build (skip the pre-cycle Test-Config.ps1 gate).
.PARAMETER StashServiceHost
    Pins the stash service instead of discovering it. Empty (the default) runs
    the discovery order in Resolve-StashService; when neither a pin nor
    discovery produces an address that answers /healthz, the pass stops.
.EXAMPLE
    pwsh test/Initialize-Lab.ps1
#>

param(
    [string]$YurunaRoot,
    [string]$LogDir = '',
    [switch]$NoConfigGate,
    [string]$StashServiceHost = ''
)

$ErrorActionPreference = 'Continue'
# Progress goes to the information stream (displayed via InformationPreference),
# never the success stream -- Invoke-Stage returns an exit code the caller checks.
$InformationPreference = 'Continue'

. (Join-Path $PSScriptRoot 'AmisAd.HostCommon.ps1')
# Resolve-StashService lives in a module, not here: poc/build/run-tests.ps1 runs
# the same pre-flight, and the address a pass uploads its binaries to must not
# depend on which entry point started it.
Import-Module (Join-Path $PSScriptRoot 'AmisAd.StashService.psm1') -Force -DisableNameChecking

$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$HostType   = Initialize-AmisAdHost -YurunaRoot $YurunaRoot
$IsHyperV   = ($HostType -eq 'host.windows.hyper-v')
Write-Information "Warm-up on '$HostType' (framework: $YurunaRoot)."

# Fail fast on a host that cannot drive its own hypervisor (Administrator on
# Hyper-V, virsh + /dev/kvm on KVM, utmctl + UTM.app on macOS). Without this
# gate the first provisioning stage burns its startup time before dying inside
# the hypervisor with a raw message that names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType)) { exit 1 }

$ts = Join-Path $YurunaRoot 'test/Debug-TestSequence.ps1'
if (-not (Test-Path -LiteralPath $ts)) { Write-Error "Debug-TestSequence.ps1 not found at $ts"; exit 1 }

function Resolve-StageLogDir {
    <#
        Where a stage's stdout/stderr are written. A stage log is the only
        record of the provisioning half of that stage -- base-image check, VM
        creation, first boot -- because the sequence transcript a guest run
        writes begins at the sequence banner, after all of it. That evidence
        decides guest-side boot and media failures, so it has to survive to
        wherever the cycle's artifacts are read: a system temp dir is not part
        of what an operator ships when a cycle fails, and is the first thing
        gone when the machine reboots.

        The cycle folder comes from the YURUNA_CYCLE_CONTEXT handle the
        framework publishes to the child processes of a host action; its
        absence means this is a standalone run with no cycle to write into, so
        the temp dir stands as the fallback. The cycle's own manifest
        enumerates the folder recursively, so nothing has to be registered.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_CYCLE_CONTEXT)) {
        try {
            $root = ($env:YURUNA_CYCLE_CONTEXT | ConvertFrom-Json -AsHashtable).rootCycleFolder
            # A cycle folder recorded but no longer on disk means the cycle is
            # over; writing it back would recreate a folder nothing collects.
            if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
                return (Join-Path $root 'initialize-lab.stage-logs')
            }
        } catch {
            Write-Verbose "Resolve-StageLogDir: unreadable cycle context, falling back to temp: $($_.Exception.Message)"
        }
    }
    return (Join-Path ([IO.Path]::GetTempPath()) 'amisad-tests')
}

$LogDir = Resolve-StageLogDir -Explicit $LogDir
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Write-Information "Per-stage logs: $LogDir"

function Invoke-Stage {
    # Write-Information (not Write-Output) for progress: the function's OUTPUT
    # stream is its return value, and a polluted return would break the caller's
    # -ne 0 check. -NoProjectClone: the orchestration run (Debug-TestSequence) already
    # refreshed <RepoRoot>/project once before invoking initialize-lab.
    param([string]$Name, [string]$Sequence, [switch]$NoConfigGate)
    Stop-LabConsole -HostType $HostType
    $out = Join-Path $LogDir "$Name.out.log"
    $err = Join-Path $LogDir "$Name.err.log"
    $stageArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ts, $Sequence, '-NoProjectClone')
    if ($NoConfigGate) { $stageArgs += '-NoConfigGate' }
    Write-Information "===== [$Name] $Sequence  $([DateTime]::Now.ToString('s'))  (log: $out) ====="
    # -WindowStyle is a Windows-only concept; passing it on Linux/macOS throws
    # "not supported on this platform" and would fail every stage before it ran.
    $spArgs = @{
        FilePath               = 'pwsh'
        PassThru               = $true
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
        ArgumentList           = $stageArgs
    }
    if ($IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    $p = Start-Process @spArgs
    $p.WaitForExit()
    Write-Information "===== [$Name] exited $($p.ExitCode)  $([DateTime]::Now.ToString('s')) ====="
    if ($p.ExitCode -ne 0) {
        Get-Content -LiteralPath $out -Tail 25 -ErrorAction SilentlyContinue | Out-Host
        Get-Content -LiteralPath $err -Tail 10 -ErrorAction SilentlyContinue | Out-Host
    }
    return $p.ExitCode
}

function Remove-InstallMedia {
    <#
        Hyper-V only -- see the PORTABILITY note in the file header for why the
        other hosts need no equivalent. Autoinstall DVDs (install ISO + per-VM
        seed.iso) are only needed to build. A renamed/restored VM keeps ABSOLUTE
        refs into that dir; later cycles overwrite it with files ACL'd to a newer
        VM, so starting the older VM fails with 0x80070005. Strip media, then
        RETAKE the checkpoint so the restored config is DVD-free too (the
        checkpoint re-attaches DVDs otherwise).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$SnapshotId)
    if (-not $IsHyperV) {
        Write-Verbose "Remove-InstallMedia: not applicable on '$HostType'."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Remove install media + retake checkpoint')) { return }
    Hyper-V\Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue |
        Hyper-V\Remove-VMDvdDrive -ErrorAction SilentlyContinue
    if ($SnapshotId) {
        $cp = Hyper-V\Get-VMCheckpoint -VMName $Name -Name $SnapshotId -ErrorAction SilentlyContinue
        if ($cp) {
            Hyper-V\Remove-VMCheckpoint -VMName $Name -Name $SnapshotId -Confirm:$false
            Hyper-V\Checkpoint-VM -Name $Name -SnapshotName $SnapshotId -Confirm:$false
            Write-Information "Retook checkpoint '$SnapshotId' on $Name without install media."
        }
    }
}

function Set-EdgeMemory {
    <#
        Hyper-V only. The framework provisions every ubuntu guest at 12GB; edges
        only run the small slice-runtime. At s004 BOTH edges are live while
        amisad-core (12GB) restores - 3 x 12GB exceeds host RAM (0x800705AA).
        Shrink before the checkpoint retake so the restored config is small too.
        On KVM/UTM the guest size is fixed at provisioning time (the sequence's
        memoryStartupBytes variable), so there is no post-hoc resize to do.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name)
    if (-not $IsHyperV) {
        Write-Verbose "Set-EdgeMemory: guest memory is a provisioning-time property on '$HostType'; leaving $Name as built."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Set static memory to 4GB')) { return }
    Hyper-V\Set-VM -Name $Name -StaticMemory -MemoryStartupBytes 4GB
    Write-Information "$Name memory set to 4GB (slice-runtime only)."
}

function Start-VMConfirmed {
    <#
        Start a VM and answer whether it is actually running, or the reason it
        is not. A start request accepted by the hypervisor is not a started VM:
        the guest process can die on its own resources (a port it cannot bind,
        a disk it cannot open) after the request has been acknowledged, so the
        state has to be observed rather than inferred from the request.
        Returns a { started; reason } record.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$Name, [int]$RunningTimeoutSeconds = 60)
    if (-not $PSCmdlet.ShouldProcess($Name, 'Start VM and confirm running')) {
        return @{ started = $false; reason = 'WhatIf' }
    }
    $record = $null
    try {
        # Start-VM answers with a status record on the success stream rather
        # than throwing, so the record is the only signal; take the last item
        # in case anything else reached the stream alongside it.
        $record = @(Start-VM -VMName $Name -ErrorAction Stop) | Select-Object -Last 1
    } catch {
        return @{ started = $false; reason = $_.Exception.Message }
    }
    if ($record -isnot [hashtable]) { return @{ started = $false; reason = 'Start-VM returned no status record' } }
    if (-not $record.success) { return @{ started = $false; reason = "$($record.errorMessage)" } }
    $deadline = (Get-Date).AddSeconds($RunningTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VMState -VMName $Name) -eq 'running') { return @{ started = $true; reason = $null } }
        Start-Sleep -Seconds 2
    }
    return @{ started = $false; reason = "start reported success but the VM is '$(Get-VMState -VMName $Name)' after ${RunningTimeoutSeconds}s" }
}

# Opt-in virtual display for headless keystroke/OCR reliability on the cold
# provisioning chains (no-op unless YURUNA_VIRTUAL_DISPLAY is truthy). The host
# type is the DETECTED one -- hard-coding Hyper-V would leave KVM/UTM (headless
# servers, the likeliest to need it) without the virtual display.
Import-Module (Join-Path $YurunaRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) {
    Initialize-HostDisplay -HostType $HostType
}

# --- [0] core->edge demo keypair (served to guests from the status handoff dir)
$handoff = Join-Path $YurunaRoot 'test/status/handoff'
New-Item -ItemType Directory -Force -Path $handoff | Out-Null
$demoKey = Join-Path $handoff 'amisad-demo-key'
if (-not (Test-Path -LiteralPath $demoKey)) {
    Write-Information "Generating the core->edge demo keypair."
    # -N '' (a true empty argument): -N '""' would encrypt with the literal "".
    ssh-keygen -t ed25519 -N '' -C 'amisad-demo' -f $demoKey | Out-Host
}

# --- [1] stash service: resolve + publish before anything long starts ---
# A stash is a requirement of this pass, not an optimization, and the project
# states no address of its own to fall back to -- so "none found" stops here,
# where it costs seconds, rather than an hour later inside a guest chain.
$stash = Resolve-StashService -YurunaRoot $YurunaRoot -Pin $StashServiceHost
foreach ($line in $stash.Lines) { Write-Information $line }
if (-not $stash.Address) {
    Write-Error ("No stash service answered /healthz; the build has nowhere to upload binaries and vm-core has nowhere to fetch them - stopping before the provisioning stages. " +
        "Start one on this host (Start-StashServiceVM.ps1), join a pool that runs one, or pin an address with -StashServiceHost / `$env:YURUNA_STASH_SERVICE_HOST.")
    exit 1
}

# --- [2] build once: compile + upload binaries to the stash ---
if ((Invoke-Stage -Name 'amisad-build' -Sequence 'workload.guest.ubuntu.server.24.amisad-build.compile' -NoConfigGate:$NoConfigGate) -ne 0) {
    Write-Error "Build stage failed; no binaries in the stash - stopping."
    exit 1
}
try { $null = Stop-VMForce -VMName 'amisad-build' } catch { Write-Verbose "Stop-VMForce amisad-build: $($_.Exception.Message)" }
Remove-InstallMedia -Name 'amisad-build' -SnapshotId 'amisad-build'
Write-Information "amisad-build stopped (kept on disk)."

# --- [3] edge VMs: provision + snapshot, one at a time (chains end stopped) ---
foreach ($edge in 'amisad-edge-a', 'amisad-edge-b') {
    if ((Invoke-Stage -Name $edge -Sequence "workload.guest.ubuntu.server.24.$edge.baseline" -NoConfigGate:$NoConfigGate) -ne 0) {
        Write-Error "$edge provisioning failed - stopping."
        exit 1
    }
    Set-EdgeMemory -Name $edge
    Remove-InstallMedia -Name $edge -SnapshotId $edge
}

# --- [4] vm-core: k8s + deploy + demo users (cold chain, solo) ---
if ((Invoke-Stage -Name 'amisad-core' -Sequence 'workload.guest.ubuntu.server.24.amisad-core.deploy' -NoConfigGate:$NoConfigGate) -ne 0) {
    Write-Error "amisad-core deploy failed - stopping."
    exit 1
}
Remove-InstallMedia -Name 'amisad-core' -SnapshotId 'amisad-core'

# --- [5] start BOTH region edges and wait for their IP reports ---
# The scenarios resolve amisad-edge-a/-b from these boot-time reports; a stale
# file from a prior run must not count, so delete first and anchor freshness to
# THIS start. Only s004.failover needs region-B live; the rest ignore it.
Write-Information "Starting amisad-edge-a + amisad-edge-b."
$logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { Join-Path $YurunaRoot 'test/status/log' }
$edges = 'amisad-edge-a', 'amisad-edge-b'
$edgeState = @{}
foreach ($edge in $edges) {
    $edgeIpFile = Join-Path $logRoot "handoff/$edge.ip.txt"
    Remove-Item -LiteralPath $edgeIpFile -Force -ErrorAction SilentlyContinue
    $edgeState[$edge] = @{ IpFile = $edgeIpFile; Start = (Get-Date); Started = $false; Reason = 'not attempted' }
    foreach ($attempt in 1..3) {
        $startResult = Start-VMConfirmed -Name $edge -Confirm:$false
        if ($startResult.started) {
            $edgeState[$edge].Started = $true
            $edgeState[$edge].Reason = $null
            break
        }
        $edgeState[$edge].Reason = $startResult.reason
        Write-Information "Start-VM $edge attempt ${attempt}/3 failed: $($startResult.reason)"
        Start-Sleep -Seconds 10
    }
}
$edgeDeadline = (Get-Date).AddMinutes(8)
foreach ($edge in $edges) {
    $edgeReady = $false
    if ($edgeState[$edge].Started) {
        while ((Get-Date) -lt $edgeDeadline) {
            if ((Test-Path -LiteralPath $edgeState[$edge].IpFile) -and
                ((Get-Item -LiteralPath $edgeState[$edge].IpFile).LastWriteTime -gt $edgeState[$edge].Start)) {
                $edgeReady = $true; break
            }
            Start-Sleep -Seconds 10
        }
        if (-not $edgeReady) { $edgeState[$edge].Reason = 'started but never reported its IP' }
    }
    $edgeState[$edge].Ready = $edgeReady
}

Write-Information "--- VM inventory ---"
foreach ($vm in @('amisad-core', 'amisad-edge-a', 'amisad-edge-b', 'amisad-build')) {
    Write-Information ("  {0,-16} {1}" -f $vm, (Get-VMState -VMName $vm))
}

# Both edges have to be live before the scenarios start. Nothing downstream
# can report a missing edge usefully: the scenarios that need region B run
# last, so the symptom is a guest script asserting on an absent peer -- a
# failure that names the wrong scenario, on the wrong VM, after every earlier
# scenario has already spent its time.
$deadEdges = @($edges | Where-Object { -not $edgeState[$_].Ready })
if ($deadEdges.Count -gt 0) {
    $detail = ($deadEdges | ForEach-Object { "$_ ($($edgeState[$_].Reason))" }) -join '; '
    Write-Error "Region edges are not live: $detail. Stopping the warm-up instead of handing the scenarios a topology they cannot run on."
    exit 1
}

Write-Information "Warm-up complete. Live: amisad-core + $($edges -join ' + ')."
exit 0
