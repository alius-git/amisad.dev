<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42b4e8da-6f32-4c9e-ad57-8b1c3f74d2e6
.AUTHOR Alisson Sol et al.
.Copyright (c) 2026 by Alisson Sol et al.
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
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Build + start the AmisAd POC topology on a clean host (the "warm-up" half of
    the end-to-end pass; Clear-Project.ps1 is the teardown half that runs first).
.DESCRIPTION
    Ports the build stages of poc/build/run-tests.ps1 (everything except the
    scenario loop, which the amisad.end-to-end.yml manifest drives). Assumes the
    host is already clean (Clear-Project.ps1 ran) and <RepoRoot>/project is
    already cloned (Test-SequenceSet clones once, so guest builds run with
    -NoProjectClone). Stages, in order:

      0. Generate the core->edge demo keypair (once per host).
      1. Build once: compile + upload binaries to the stash (amisad-build).
      2. Edge VMs: provision + snapshot amisad-edge-a / -b, shrink to 4GB.
      3. vm-core: k8s + PostgreSQL + NATS + deploy 10 services + demo users.
      4. Start both edges and wait for their boot-time IP reports (the fresh
         handoff/*.ip.txt the scenarios resolve the edge from).

    Leaves amisad-core + both edges live. Elevated (Hyper-V) is required.
.PARAMETER YurunaRoot
    Yuruna framework checkout that holds test/Test-Sequence.ps1. Default c:\git\yuruna.
.PARAMETER LogDir
    Per-stage Test-Sequence logs. Default: %TEMP%\amisad-tests.
.PARAMETER NoConfigGate
    Forwarded to each guest build (skip the pre-cycle Test-Config.ps1 gate).
.EXAMPLE
    pwsh test/gui/Set-Resource.ps1
#>

param(
    [string]$YurunaRoot = 'c:\git\yuruna',
    [string]$LogDir = (Join-Path ([IO.Path]::GetTempPath()) 'amisad-tests'),
    [switch]$NoConfigGate
)

$ErrorActionPreference = 'Continue'
$ts = Join-Path $YurunaRoot 'test\Test-Sequence.ps1'
if (-not (Test-Path $ts)) { Write-Error "Test-Sequence.ps1 not found at $ts"; exit 1 }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Stop-LabConsole {
    # A live lab vmconnect steals GUI keystroke focus during a VM's first login.
    Get-Process vmconnect -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match 'amisad|test-' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Invoke-Stage {
    # Write-Host (not Write-Output) for progress: the function's OUTPUT stream is
    # its return value, and a polluted return would break the caller's -ne 0 check.
    # -NoProjectClone: Test-SequenceSet already refreshed <RepoRoot>/project once.
    param([string]$Name, [string]$Sequence)
    Stop-LabConsole
    $out = Join-Path $LogDir "$Name.out.log"
    $err = Join-Path $LogDir "$Name.err.log"
    $stageArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ts), $Sequence, '-NoProjectClone')
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

function Remove-InstallMedia {
    param([string]$Name, [string]$SnapshotId)
    # Autoinstall DVDs (install ISO + per-VM seed.iso) are only needed to build.
    # A renamed/restored VM keeps ABSOLUTE refs into that dir; later cycles
    # overwrite it with files ACL'd to a newer VM, so starting the older VM fails
    # with 0x80070005. Strip media, then RETAKE the checkpoint so the restored
    # config is DVD-free too (the checkpoint re-attaches DVDs otherwise).
    Hyper-V\Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue |
        Hyper-V\Remove-VMDvdDrive -ErrorAction SilentlyContinue
    if ($SnapshotId) {
        $cp = Hyper-V\Get-VMCheckpoint -VMName $Name -Name $SnapshotId -ErrorAction SilentlyContinue
        if ($cp) {
            Hyper-V\Remove-VMCheckpoint -VMName $Name -Name $SnapshotId -Confirm:$false
            Hyper-V\Checkpoint-VM -Name $Name -SnapshotName $SnapshotId -Confirm:$false
            Write-Host "Retook checkpoint '$SnapshotId' on $Name without install media."
        }
    }
}

# Opt-in virtual display for headless keystroke/OCR reliability on the cold
# provisioning chains (no-op unless YURUNA_VIRTUAL_DISPLAY is truthy).
Import-Module (Join-Path $YurunaRoot 'test\modules\Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) {
    Initialize-HostDisplay -HostType 'host.windows.hyper-v'
}

# --- [0] core->edge demo keypair (served to guests from the status handoff dir)
$handoff = Join-Path $YurunaRoot 'test\status\handoff'
New-Item -ItemType Directory -Force -Path $handoff | Out-Null
$demoKey = Join-Path $handoff 'amisad-demo-key'
if (-not (Test-Path $demoKey)) {
    Write-Host "Generating the core->edge demo keypair."
    # -N '' (a true empty argument): -N '""' would encrypt with the literal "".
    ssh-keygen -t ed25519 -N '' -C 'amisad-demo' -f $demoKey | Out-Host
}

# --- [1] build once: compile + upload binaries to the stash ---
if ((Invoke-Stage -Name 'build' -Sequence 'workload.guest.ubuntu.server.24.amisad-build.compile') -ne 0) {
    Write-Error "Build stage failed; no binaries in the stash - stopping."
    exit 1
}
Hyper-V\Stop-VM -Name 'amisad-build' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
Remove-InstallMedia -Name 'amisad-build' -SnapshotId 'amisad-build'
Write-Host "amisad-build stopped (kept on disk)."

# --- [2] edge VMs: provision + snapshot, one at a time (chains end stopped) ---
foreach ($edge in 'amisad-edge-a', 'amisad-edge-b') {
    if ((Invoke-Stage -Name $edge -Sequence "workload.guest.ubuntu.server.24.$edge.baseline") -ne 0) {
        Write-Error "$edge provisioning failed - stopping."
        exit 1
    }
    # Framework provisions every ubuntu guest at 12GB; edges only run the small
    # slice-runtime. At s004 BOTH edges are live while amisad-core (12GB)
    # restores - 3 x 12GB exceeds host RAM (0x800705AA). Shrink before the
    # checkpoint retake so the restored config is small too.
    Hyper-V\Set-VM -Name $edge -StaticMemory -MemoryStartupBytes 4GB
    Write-Host "$edge memory set to 4GB (slice-runtime only)."
    Remove-InstallMedia -Name $edge -SnapshotId $edge
}

# --- [3] vm-core: k8s + deploy + demo users (cold chain, solo) ---
if ((Invoke-Stage -Name 'vm-core' -Sequence 'workload.guest.ubuntu.server.24.amisad-core.deploy') -ne 0) {
    Write-Error "amisad-core deploy failed - stopping."
    exit 1
}
Remove-InstallMedia -Name 'amisad-core' -SnapshotId 'amisad-core'

# --- [4] start BOTH region edges and wait for their IP reports ---
# The scenarios resolve amisad-edge-a/-b from these boot-time reports; a stale
# file from a prior run must not count, so delete first and anchor freshness to
# THIS start. s004/s010 need region-B live; earlier scenarios just don't use it.
Write-Host "Starting amisad-edge-a + amisad-edge-b."
$logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { Join-Path $YurunaRoot 'test\status\log' }
$edges = 'amisad-edge-a', 'amisad-edge-b'
$edgeState = @{}
foreach ($edge in $edges) {
    $edgeIpFile = Join-Path $logRoot "handoff\$edge.ip.txt"
    Remove-Item -LiteralPath $edgeIpFile -Force -ErrorAction SilentlyContinue
    $edgeState[$edge] = @{ IpFile = $edgeIpFile; Start = (Get-Date); Started = $false }
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

Write-Host "Warm-up complete. Live: amisad-core + amisad-edge-a + amisad-edge-b."
Write-Host "--- VM inventory ---"
(Hyper-V\Get-VM | Select-Object Name, State | Format-Table -AutoSize | Out-String -Width 120) | Write-Host
exit 0
