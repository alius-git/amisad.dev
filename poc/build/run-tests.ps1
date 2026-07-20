<#PSScriptInfo
.VERSION 2026.07.20
.GUID 42a7f3c0-9b21-4d84-8e15-6f2c9a1d0b77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab test automation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

# AmisAd POC test automation driver (see poc/test.md). From a clean machine it
# builds the design topology (plan/design/01-overview.md) and runs every
# implemented scenario against it:
#   [0] remove every amisad lab VM (old and new naming) + leftover test-* VMs
#       AND their storage dirs; ensure the core->edge demo keypair exists
#   [1] amisad-vm-build: compile + upload binaries to the stash, then stop it
#   [2] amisad-vm-edge-a and amisad-vm-edge-b: provision + snapshot (each chain
#       runs solo - first-login OCR is only reliable with no other lab VM up)
#   [3] amisad-vm-core: k8s + deploy + demo users, snapshot amisad-vm-core
#   [4] start BOTH edges and wait for their IP reports (s004 needs region B
#       live; earlier scenarios just don't use it)
#   [5] each scenario in order: restore amisad-vm-core (the per-scenario state
#       reset) and drive it over SSH - concurrent edge VMs cannot disturb SSH
#       stages. On fail the run stops and everything is left up for debugging.
# Green leaves amisad-vm-core + both edges live as the demo environment.
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
    'workload.guest.ubuntu.server.24.amisad-vm-core.s001.fulfillment'
    'workload.guest.ubuntu.server.24.amisad-vm-core.s002.fitting'
    'workload.guest.ubuntu.server.24.amisad-vm-core.s003.silence'
    'workload.guest.ubuntu.server.24.amisad-vm-core.s004.failover'
)

function Stop-LabConsole {
    # Only LAB consoles: a live vmconnect can steal GUI keystroke focus during a
    # VM's first login, but operator consoles to unrelated VMs must be left alone.
    Get-Process vmconnect -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match 'amisad|test-' } |
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

function Remove-InstallMedia {
    param([string]$Name, [string]$SnapshotId)
    # The provisioning DVDs (install ISO + the per-VM seed.iso in the transient
    # test- storage dir) are only needed for autoinstall. A renamed VM keeps
    # ABSOLUTE references into that dir; later provisioning cycles overwrite it
    # with files ACL'd to the newer VM, and starting the older VM then fails
    # with 0x80070005. Strip the media once the chain is done (VM must be Off).
    Hyper-V\Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue |
        Hyper-V\Remove-VMDvdDrive -ErrorAction SilentlyContinue
    # Stripping the CURRENT config is not enough for restore targets: the
    # checkpoint still re-attaches the DVDs, and the strip drops the VM's ACE
    # on the ISO files, so the next loadDiskSnapshot fails with 0x80070005
    # (proved 2026-07-20). Retake the checkpoint so the RESTORED config is
    # DVD-free too. The snapshot manifest compares (VMName, SnapshotId,
    # HostType) only, all unchanged by the retake.
    if ($SnapshotId) {
        $cp = Hyper-V\Get-VMCheckpoint -VMName $Name -Name $SnapshotId -ErrorAction SilentlyContinue
        if ($cp) {
            Hyper-V\Remove-VMCheckpoint -VMName $Name -Name $SnapshotId -Confirm:$false
            Hyper-V\Checkpoint-VM -Name $Name -SnapshotName $SnapshotId -Confirm:$false
            Write-Host "Retook checkpoint '$SnapshotId' on $Name without install media."
        }
    }
}

# Headless keystroke/OCR reliability for the cold provisioning chains: attach
# the opt-in virtual display the way the runner's cycle path does (no-op unless
# YURUNA_VIRTUAL_DISPLAY is truthy - see poc/test.md).
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
# Sweep registered lab VMs (current amisad-vm-* and legacy amisad.* names) AND
# the known names, covering storage dirs stranded by a prior run.
$topologyVms = @('amisad-vm-build', 'amisad-vm-edge-a', 'amisad-vm-edge-b', 'amisad-vm-core', 'amisad-vm-core-k8s')
$labVms = @(Hyper-V\Get-VM |
    Where-Object { $_.Name -like 'amisad-vm-*' -or $_.Name -like 'amisad.*' -or $_.Name -like 'test-*' } |
    ForEach-Object Name)
$labVms += $topologyVms
foreach ($vmName in ($labVms | Sort-Object -Unique)) { Remove-LabVM -Name $vmName }
Stop-LabConsole

# Core->edge demo keypair, served to guests from the status server's handoff
# dir (lab-trusted LAN; see poc/usernames.md). Generated once per host.
$handoff = Join-Path $YurunaRoot 'test\status\handoff'
New-Item -ItemType Directory -Force -Path $handoff | Out-Null
$demoKey = Join-Path $handoff 'amisad-demo-key'
if (-not (Test-Path $demoKey)) {
    Write-Host "Generating the core->edge demo keypair."
    # -N '' (a true empty argument): under pwsh 7's Standard native passing,
    # -N '""' would create a key ENCRYPTED with the literal passphrase "".
    ssh-keygen -t ed25519 -N '' -C 'amisad-demo' -f $demoKey | Out-Host
}

# --- [1] build once: compile + upload binaries to the stash ---
if ((Invoke-Stage -Name 'build' -Sequence 'workload.guest.ubuntu.server.24.amisad-vm-build.compile') -ne 0) {
    Write-Error "Build stage failed; no binaries in the stash - stopping."
    exit 1
}
Hyper-V\Stop-VM -Name 'amisad-vm-build' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
Remove-InstallMedia -Name 'amisad-vm-build' -SnapshotId 'amisad-vm-build'
Write-Host "amisad-vm-build stopped (kept on disk)."

# --- [2] edge VMs: provision + snapshot, one at a time (chains end stopped) ---
foreach ($edge in 'amisad-vm-edge-a', 'amisad-vm-edge-b') {
    if ((Invoke-Stage -Name $edge -Sequence "workload.guest.ubuntu.server.24.$edge.baseline") -ne 0) {
        Write-Error "$edge provisioning failed - stopping."
        exit 1
    }
    Remove-InstallMedia -Name $edge -SnapshotId $edge
}

# --- [3] vm-core: k8s + deploy + demo users (cold chain, solo) ---
if ((Invoke-Stage -Name 'vm-core' -Sequence 'workload.guest.ubuntu.server.24.amisad-vm-core.deploy') -ne 0) {
    Write-Error "amisad-vm-core deploy failed - stopping."
    exit 1
}
Remove-InstallMedia -Name 'amisad-vm-core' -SnapshotId 'amisad-vm-core'

# --- [4] start BOTH region edges and wait for their IP reports ---
# s004.failover needs the region-B edge live (jurisdiction-restricted
# allocation must have a roomier non-compliant region to exclude); earlier
# scenarios simply don't use it. Both stay live in the demo environment.
Write-Host "Starting amisad-vm-edge-a + amisad-vm-edge-b."
# The log-upload sink writes under YURUNA_LOG_DIR when overridden; resolve the
# same way the server does, and anchor freshness to THIS start (a stale file
# from a prior run/boot must not count).
$logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { Join-Path $YurunaRoot 'test\status\log' }
$edges = 'amisad-vm-edge-a', 'amisad-vm-edge-b'
# Start both first (they boot in parallel), then wait on both IP reports -
# a serial start would add a full edge boot to the stage for nothing.
$edgeState = @{}
foreach ($edge in $edges) {
    $edgeIpFile = Join-Path $logRoot "handoff\$edge.ip.txt"
    Remove-Item -LiteralPath $edgeIpFile -Force -ErrorAction SilentlyContinue
    $edgeState[$edge] = @{ IpFile = $edgeIpFile; Start = (Get-Date); Started = $false }
    # Loud + retried: a silent Start-VM failure previously left the edge Off and
    # pushed the scenarios into the degraded fallback with no evidence why.
    foreach ($attempt in 1..3) {
        try {
            Hyper-V\Start-VM -Name $edge -ErrorAction Stop
            $edgeState[$edge].Started = $true
            break
        } catch {
            Write-Host "Start-VM $edge attempt ${attempt}/3 failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    }
}
$edgeDeadline = (Get-Date).AddMinutes(8)
foreach ($edge in $edges) {
    $edgeReady = $false
    if ($edgeState[$edge].Started) {
        while ((Get-Date) -lt $edgeDeadline) {
            if ((Test-Path $edgeState[$edge].IpFile) -and
                ((Get-Item $edgeState[$edge].IpFile).LastWriteTime -gt $edgeState[$edge].Start)) {
                $edgeReady = $true; break
            }
            Start-Sleep -Seconds 10
        }
    }
    if (-not $edgeReady) {
        Write-Warning "$edge IP report not seen; dependent scenarios will fall back or fail loudly."
    }
}

# --- [5] scenarios, in order, each restoring amisad-vm-core over SSH ---
foreach ($s in $Scenarios) {
    $name = ($s -split '\.')[-2..-1] -join '.'
    if ((Invoke-Stage -Name $name -Sequence $s) -ne 0) {
        Write-Error "Scenario $s FAILED - stopping the run; VMs are left as-is for debugging."
        exit 1
    }
}

Write-Host "ALL SCENARIOS PASSED. Demo environment live: amisad-vm-core + amisad-vm-edge-a + amisad-vm-edge-b."
Write-Host "--- final VM inventory ---"
(Hyper-V\Get-VM | Select-Object Name, State | Format-Table -AutoSize | Out-String -Width 120) | Write-Host
exit 0
