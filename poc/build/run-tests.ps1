<#PSScriptInfo
.VERSION 2026.09.30
.GUID 422575f2-b59c-4bf6-92c5-a76bc5b529bb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab test automation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

#requires -version 7

<#
.SYNOPSIS
    AmisAd POC test automation driver: builds the design topology and runs every
    scenario against a shared amisad-core (stages [0]-[5]; see poc/test.md).
    Runs on any Yuruna host type (Hyper-V, KVM, UTM).
.DESCRIPTION
    On fail the run stops with everything left up for debugging; green leaves
    amisad-core + both edges live as the demo environment. Stage logs land
    under -LogDir.

    PORTABILITY. VM lifecycle goes through the Yuruna host contract
    (Get-VMState / Start-VM / Stop-VMForce, loaded by Initialize-AmisAdHost)
    and the clean-start sweep goes through the framework's
    Remove-TestVMFiles.ps1, so no stage names a hypervisor. Two Hyper-V-
    specific TUNINGS remain, each guarded and each a no-op elsewhere by design
    rather than omission:

      * Install-media stripping + checkpoint retake. A renamed/restored Hyper-V
        VM keeps ABSOLUTE references into the autoinstall DVD dir; later cycles
        overwrite it with files ACL'd to a newer VM and the older VM then fails
        to start with 0x80070005. KVM and UTM attach the cloud-init seed by
        path per boot with no ACL inheritance, so there is nothing to strip.
      * The 4GB edge shrink. Hyper-V has a live Set-VM; on KVM/UTM the guest
        size is a provisioning-time property (the sequence's memoryStartupBytes
        variable), so it cannot -- and need not -- be changed after the fact.

    ELEVATION is asserted at runtime against the DETECTED host rather than
    declared with '#requires -RunAsAdministrator': only host.windows.hyper-v
    registers RequiresElevation, and a static requirement would demand root on
    KVM/UTM, where the framework deliberately uses libvirt group membership and
    the invoking user's utmctl session instead.
.PARAMETER YurunaRoot
    Yuruna framework checkout that holds test/Debug-TestSequence.ps1. Optional
    -- see Resolve-YurunaRoot for the discovery order.
.PARAMETER LogDir
    Per-stage Debug-TestSequence logs. Default: <temp>/amisad-tests.
.PARAMETER NoConfigGate
    Forwarded to each stage (skip the pre-cycle Test-Config.ps1 gate).
.EXAMPLE
    pwsh poc/build/run-tests.ps1
#>

param(
    [string]$YurunaRoot,
    [string]$LogDir = (Join-Path ([IO.Path]::GetTempPath()) 'amisad-tests'),
    [switch]$NoConfigGate
)
$ErrorActionPreference = 'Continue'
# Progress goes to the information stream (displayed via InformationPreference),
# never the success stream -- Invoke-AmisAdStage returns an exit code the caller checks.
$InformationPreference = 'Continue'

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $ProjectRoot 'test/AmisAd.HostCommon.ps1')
# Resolve-StashService lives in a module, not here: test/Initialize-Lab.ps1 runs
# the same pre-flight, and the address a pass uploads its binaries to must not
# depend on which entry point started it.
Import-Module (Join-Path $ProjectRoot 'test/AmisAd.StashService.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'test/AmisAd.Lab.psm1') -Force -DisableNameChecking

$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$HostType   = Initialize-AmisAdHost -YurunaRoot $YurunaRoot
Write-Information "Test driver on '$HostType' (framework: $YurunaRoot)."

# Fail fast on a host that cannot call its own VM cmdlets (Administrator on
# Hyper-V, virsh//dev/kvm on KVM, utmctl + UTM.app on macOS). Without this gate
# the first sweep dies inside the hypervisor with its own raw message, which
# names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType)) { exit 1 }

$ts = Join-Path $YurunaRoot 'test/Debug-TestSequence.ps1'
if (-not (Test-Path -LiteralPath $ts)) { Write-Error "Debug-TestSequence.ps1 not found at $ts"; exit 1 }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stageContext = @{ HostType = $HostType; SequenceScript = $ts; LogDir = $LogDir }

# Ordered scenario registry: append here as scenarios are implemented (test.md).
$Scenarios = @(
    'workload.guest.ubuntu.server.24.amisad-core.s001.fulfillment'
    'workload.guest.ubuntu.server.24.amisad-core.s002.fitting'
    'workload.guest.ubuntu.server.24.amisad-core.s003.silence'
    'workload.guest.ubuntu.server.24.amisad-core.s004.failover'
    'workload.guest.ubuntu.server.24.amisad-core.s005.attribution'
    'workload.guest.ubuntu.server.24.amisad-core.s006.mandate'
    'workload.guest.ubuntu.server.24.amisad-core.s007.inventory'
    'workload.guest.ubuntu.server.24.amisad-core.s008.mediation'
    'workload.guest.ubuntu.server.24.amisad-core.s009.suppression'
    'workload.guest.ubuntu.server.24.amisad-core.s010.certification'
)

# Headless keystroke/OCR reliability for the cold provisioning chains: attach
# the opt-in virtual display the way the runner's cycle path does (no-op unless
# YURUNA_VIRTUAL_DISPLAY is truthy - see poc/test.md). The host type is the
# DETECTED one -- hard-coding Hyper-V would leave KVM/UTM (headless servers, the
# likeliest to need it) without the virtual display.
Import-Module (Join-Path $YurunaRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) {
    Initialize-HostDisplay -HostType $HostType
}

# Refuse to sweep VMs out from under an active Yuruna runner.
$runnerPidFile = Join-Path $YurunaRoot 'test/status/runtime/runner.pid'
if (Test-Path -LiteralPath $runnerPidFile) {
    $runnerPid = 0
    try { $runnerPid = [int]((Get-Content -LiteralPath $runnerPidFile -Raw).Trim()) } catch { $runnerPid = 0 }
    if ($runnerPid -gt 0 -and (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
        Write-Error "A Yuruna runner (PID $runnerPid) is active; stop it before running the test driver."
        exit 1
    }
}

# --- [0] clean start: a test run assumes and enforces "no pre-built VMs" ---
# The whole sweep is the framework's: Remove-TestVMFiles.ps1 enumerates,
# force-stops and removes every VM whose name starts with one of the prefixes
# through the host contract, then runs the orphaned-file sweep that clears the
# leftover per-VM storage dirs an unregister leaves behind (a stranded dir would
# make the next chain's saveDiskSnapshot rename collide). Current 'amisad-' and
# legacy 'amisad.' cover the topology; 'test-' covers the framework's transient
# provisioning VMs. Keeping no VM list and no removal logic here means a
# teardown bug gets fixed once, in the framework, for every host type.
Stop-LabConsole -HostType $HostType
$sweepScript = Join-Path $YurunaRoot 'test/Remove-TestVMFiles.ps1'
if (-not (Test-Path -LiteralPath $sweepScript)) {
    Write-Error "Remove-TestVMFiles.ps1 not found at '$sweepScript' (set -YurunaRoot)."
    exit 1
}
# Child process isolates the framework script's own `exit`.
$sweepExit = Invoke-AmisAdCleanup -SweepScript $sweepScript -Prefix @('amisad-', 'amisad.', 'test-') -LogDir $LogDir
if ($sweepExit -ne 0) {
    Write-Error "Clean-start sweep failed (exit $sweepExit); a lab VM survived - stopping before provisioning on top of it."
    exit 1
}
Stop-LabConsole -HostType $HostType

# Core->edge demo keypair, served to guests from the status service's handoff
# dir (lab-trusted LAN; see poc/usernames.md). Generated once per host.
$handoff = Join-Path $YurunaRoot 'test/status/handoff'
New-Item -ItemType Directory -Force -Path $handoff | Out-Null
$demoKey = Join-Path $handoff 'amisad-demo-key'
if (-not (Test-Path -LiteralPath $demoKey)) {
    Write-Information "Generating the core->edge demo keypair."
    # -N '' (a true empty argument): under pwsh 7's Standard native passing,
    # -N '""' would create a key ENCRYPTED with the literal passphrase "".
    ssh-keygen -t ed25519 -N '' -C 'amisad-demo' -f $demoKey | Out-Host
}

# --- pre-flight: stash service, resolved + published before anything long starts ---
# A stash is a requirement of this pass, not an optimization: the build uploads
# its binaries to it and amisad-core downloads them. This project states no
# address of its own, so "none found" stops here, where it costs seconds,
# rather than an hour later inside the build guest.
$stash = Resolve-StashService -YurunaRoot $YurunaRoot
foreach ($line in $stash.Lines) { Write-Information $line }
if (-not $stash.Address) {
    Write-Error ("No stash service answered /healthz; the build has nowhere to upload binaries and amisad-core has nowhere to fetch them - stopping before the provisioning stages. " +
        "Start one on this host (Start-StashServiceVM.ps1), join a pool that runs one, or pin an address with `$env:YURUNA_STASH_SERVICE_HOST.")
    exit 1
}

# --- [1] build once: compile + upload binaries to the stash ---
if ((Invoke-AmisAdStage @stageContext -Name 'amisad-build' -Sequence 'workload.guest.ubuntu.server.24.amisad-build.compile' -NoConfigGate:$NoConfigGate) -ne 0) {
    Write-Error "Build stage failed; no binaries in the stash - stopping."
    exit 1
}
try { $null = Stop-VMForce -VMName 'amisad-build' } catch { Write-Verbose "Stop-VMForce amisad-build: $($_.Exception.Message)" }
Remove-InstallMedia -Name 'amisad-build' -SnapshotId 'amisad-build' -Confirm:$false -HostType $HostType
Write-Information "amisad-build stopped (kept on disk)."

# --- [2] edge VMs: provision + snapshot, one at a time (chains end stopped) ---
foreach ($edge in 'amisad-edge-a', 'amisad-edge-b') {
    if ((Invoke-AmisAdStage @stageContext -Name $edge -Sequence "workload.guest.ubuntu.server.24.$edge.baseline" -NoConfigGate:$NoConfigGate) -ne 0) {
        Write-Error "$edge provisioning failed - stopping."
        exit 1
    }
    Set-EdgeMemory -Name $edge -Confirm:$false -HostType $HostType
    Remove-InstallMedia -Name $edge -SnapshotId $edge -Confirm:$false -HostType $HostType
}

# --- [3] vm-core: k8s + deploy + demo users (cold chain, solo) ---
if ((Invoke-AmisAdStage @stageContext -Name 'amisad-core' -Sequence 'workload.guest.ubuntu.server.24.amisad-core.deploy' -NoConfigGate:$NoConfigGate) -ne 0) {
    Write-Error "amisad-core deploy failed - stopping."
    exit 1
}
Remove-InstallMedia -Name 'amisad-core' -SnapshotId 'amisad-core' -Confirm:$false -HostType $HostType

# --- [4] start BOTH region edges and wait for their IP reports ---
# s004.failover needs the region-B edge live (jurisdiction-restricted
# allocation must have a roomier non-compliant region to exclude); earlier
# scenarios simply don't use it. Both stay live in the demo environment.
Write-Information "Starting amisad-edge-a + amisad-edge-b."
# The log-upload sink writes under YURUNA_LOG_DIR when overridden; resolve the
# same way the server does, and anchor freshness to THIS start (a stale file
# from a prior run/boot must not count).
$logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { Join-Path $YurunaRoot 'test/status/log' }
$edges = 'amisad-edge-a', 'amisad-edge-b'
# Start both first (they boot in parallel), then wait on both IP reports -
# a serial start would add a full edge boot to the stage for nothing.
$edgeState = @{}
foreach ($edge in $edges) {
    $edgeIpFile = Join-Path $logRoot "handoff/$edge.ip.txt"
    Remove-Item -LiteralPath $edgeIpFile -Force -ErrorAction SilentlyContinue
    $edgeState[$edge] = @{ IpFile = $edgeIpFile; Start = (Get-Date); Started = $false }
    # Loud + retried: a silent start failure would leave the edge Off and push
    # the scenarios into the degraded fallback with no evidence why.
    foreach ($attempt in 1..3) {
        $startResult = Start-VMConfirmed -Name $edge -Confirm:$false
        if ($startResult.started) {
            $edgeState[$edge].Started = $true
            break
        }
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
    }
    if (-not $edgeReady) {
        Write-Warning "$edge IP report not seen; dependent scenarios will fall back or fail loudly."
    }
}

# --- [5] scenarios, in order, each restoring amisad-core over SSH ---
foreach ($s in $Scenarios) {
    $name = ($s -split '\.')[-2..-1] -join '.'
    if ((Invoke-AmisAdStage @stageContext -Name $name -Sequence $s -NoConfigGate:$NoConfigGate) -ne 0) {
        Write-Error "Scenario $s FAILED - stopping the run; VMs are left as-is for debugging."
        exit 1
    }
}

Write-Information "ALL SCENARIOS PASSED. Demo environment live: amisad-core + amisad-edge-a + amisad-edge-b."
Write-Information "--- final VM inventory ---"
foreach ($vm in @('amisad-core', 'amisad-edge-a', 'amisad-edge-b', 'amisad-build')) {
    Write-Information ("  {0,-16} {1}" -f $vm, (Get-VMState -VMName $vm))
}
exit 0
