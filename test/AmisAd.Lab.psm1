<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42e962ea-ac03-454b-a154-0916ff193eb4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad lab process host
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

#requires -version 7
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'AmisAd.HostCommon.ps1')

# --- REGION: Invoke-AmisAdScript
function Invoke-AmisAdScript {
    <#
    .SYNOPSIS
        Run a child PowerShell script, preserve scalar arguments, and stream its logs to disk.
    .DESCRIPTION
        The child isolates scripts that use exit. ArgumentList preserves spaces and empty
        arguments without shell quoting. Both pipes drain concurrently, so verbose stages
        cannot deadlock or accumulate their entire output in memory.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ErrorPath
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $startInfo.UseShellExecute = $false
    $startInfo.WorkingDirectory = (Get-Location).ProviderPath
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArguments)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $outputStream = $null
    $errorStream = $null
    try {
        $outputStream = [IO.File]::Create($OutputPath)
        $errorStream = [IO.File]::Create($ErrorPath)
        [void]$process.Start()
        $outputCopy = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
        $errorCopy = $process.StandardError.BaseStream.CopyToAsync($errorStream)
        $process.WaitForExit()
        [void]$outputCopy.GetAwaiter().GetResult()
        [void]$errorCopy.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($errorStream) { $errorStream.Dispose() }
        $process.Dispose()
    }
}

# --- REGION: Invoke-AmisAdStage
function Invoke-AmisAdStage {
    <#
    .SYNOPSIS
        Run one framework sequence with its own logs and return only its exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Sequence,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$SequenceScript,
        [Parameter(Mandatory)][string]$LogDir,
        [switch]$NoConfigGate,
        [switch]$NoProjectClone
    )
    Stop-LabConsole -HostType $HostType
    $out = Join-Path $LogDir "$Name.out.log"
    $err = Join-Path $LogDir "$Name.err.log"
    $stageArgs = @($Sequence)
    if ($NoProjectClone) { $stageArgs += '-NoProjectClone' }
    if ($NoConfigGate) { $stageArgs += '-NoConfigGate' }
    Write-Information "===== [$Name] $Sequence  $([DateTime]::Now.ToString('s'))  (log: $out) =====" -InformationAction Continue
    $exitCode = Invoke-AmisAdScript -ScriptPath $SequenceScript -ScriptArguments $stageArgs -OutputPath $out -ErrorPath $err
    Write-Information "===== [$Name] exited $exitCode  $([DateTime]::Now.ToString('s')) =====" -InformationAction Continue
    if ($exitCode -ne 0) {
        Get-Content -LiteralPath $out -Tail 25 -ErrorAction SilentlyContinue | Out-Host
        Get-Content -LiteralPath $err -Tail 10 -ErrorAction SilentlyContinue | Out-Host
    }
    return $exitCode
}

# --- REGION: Invoke-AmisAdCleanup
function Invoke-AmisAdCleanup {
    <#
    .SYNOPSIS
        Sweep each literal VM prefix in a child and stop on the first failure.
    .DESCRIPTION
        Native pwsh -File cannot bind a PowerShell array to the child's array parameter.
        A scalar prefix per invocation keeps each selection literal and independently checked.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$SweepScript,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Prefix,
        [Parameter(Mandatory)][string]$LogDir
    )
    foreach ($value in $Prefix) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'A cleanup prefix cannot be empty.' }
    }
    $index = 0
    foreach ($value in $Prefix) {
        $out = Join-Path $LogDir "cleanup-$index.out.log"
        $err = Join-Path $LogDir "cleanup-$index.err.log"
        $exitCode = Invoke-AmisAdScript -ScriptPath $SweepScript -ScriptArguments @('-Prefix', $value) -OutputPath $out -ErrorPath $err
        Get-Content -LiteralPath $out, $err -ErrorAction SilentlyContinue | Out-Host
        if ($exitCode -ne 0) { return $exitCode }
        $index++
    }
    return 0
}

# --- REGION: Test-AmisAdStorageAdmission
function Test-AmisAdStorageAdmission {
    <#
    .SYNOPSIS
        Check the topology's actual storage volumes and retain the admission evidence.
    .DESCRIPTION
        The optional driver helper allows this project to run with older frameworks.
        An unavailable probe is recorded explicitly; a measured shortage stops the
        stage. Disk growth is reserved before provisioning, not charged again after
        the disks and checkpoints already exist.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][ValidateSet('BeforeProvisioning', 'BeforeStart')][string]$Stage,
        [switch]$IncludeDiskGrowth
    )
    if ($HostType -ne 'host.windows.hyper-v') { return @{ allowed = $true; status = 'not-applicable'; reason = '' } }
    $evidence = @{ allowed = $true; status = 'unknown'; reason = 'Storage admission is unavailable: the host driver has no Test-VMStorageCapacity helper.';
                   timestamp = [DateTime]::UtcNow.ToString('o') }
    $capacityCommand = Get-Command Test-VMStorageCapacity -ErrorAction SilentlyContinue
    if ($capacityCommand) {
        $requirements = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host-storage.requirements.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $memory = @{}
        $growth = @{}
        foreach ($vm in $requirements.virtualMachines) {
            if (-not $IncludeDiskGrowth -and [long]$vm.startupMemoryBytes -eq 0) { continue }
            $memory[$vm.name] = [long]$vm.startupMemoryBytes
            if ($IncludeDiskGrowth) { $growth[$vm.name] = [long]$vm.additionalStorageBytes }
        }
        try {
            $capacityArgs = @{ VMName = [string[]]$memory.Keys; StartupMemoryBytes = $memory;
                AdditionalStorageBytes = $growth; ReserveBytes = [long]$requirements.reserveBytes }
            if ($IncludeDiskGrowth -and $capacityCommand.Parameters.ContainsKey('ProvisioningMemoryBytes')) {
                $capacityArgs.ProvisioningMemoryBytes = [long]$requirements.provisioningMemoryBytes
            }
            $evidence = Test-VMStorageCapacity @capacityArgs
        } catch {
            $evidence = @{ allowed = $true; status = 'unknown'; reason = "Storage admission is unavailable: $($_.Exception.Message)";
                           timestamp = [DateTime]::UtcNow.ToString('o') }
        }
    }
    try {
        New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
        $evidence | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $LogDir "storage-admission.$Stage.json") -Encoding utf8 -ErrorAction Stop
    } catch { Write-Warning "Could not save storage admission evidence: $($_.Exception.Message)" }
    if ($evidence.status -eq 'unknown') { Write-Warning $evidence.reason }
    if (-not $evidence.allowed) {
        $null = Write-AmisAdLabFailure -YurunaRoot $YurunaRoot -HostType $HostType -Stage "StorageAdmission-$Stage" `
            -FailureClass 'provisioning_failure' -ErrorMessage "Topology storage admission refused: $($evidence.reason)" `
            -StartupFailure @{ kind = 'storage-capacity'; hostStorage = $evidence }
    }
    return $evidence
}

# --- REGION: Remove-InstallMedia
function Remove-InstallMedia {
    <#
    .SYNOPSIS
        Remove Hyper-V install DVDs and retake the checkpoint without their absolute paths.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$SnapshotId, [Parameter(Mandatory)][string]$HostType)
    if ($HostType -ne 'host.windows.hyper-v') {
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
            Write-Information "Retook checkpoint '$SnapshotId' on $Name without install media." -InformationAction Continue
        }
    }
}

# --- REGION: Set-EdgeMemory
function Set-EdgeMemory {
    <#
    .SYNOPSIS
        Shrink Hyper-V edges before checkpointing; KVM/UTM memory is set during provisioning.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [Parameter(Mandatory)][string]$HostType)
    if ($HostType -ne 'host.windows.hyper-v') {
        Write-Verbose "Set-EdgeMemory: guest memory is a provisioning-time property on '$HostType'; leaving $Name as built."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Set static memory to 4GB')) { return }
    Hyper-V\Set-VM -Name $Name -StaticMemory -MemoryStartupBytes 4GB
    Write-Information "$Name memory set to 4GB (slice-runtime only)." -InformationAction Continue
}

# --- REGION: Start-VMConfirmed
function Start-VMConfirmed {
    <#
    .SYNOPSIS
        Start through the host contract and confirm that the VM reached running state.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$Name, [int]$RunningTimeoutSeconds = 60)
    if (-not $PSCmdlet.ShouldProcess($Name, 'Start VM and confirm running')) {
        return @{ started = $false; reason = 'WhatIf' }
    }
    try {
        $record = @(Start-VM -VMName $Name -ErrorAction Stop) | Select-Object -Last 1
    } catch {
        return @{ started = $false; reason = $_.Exception.Message; kind = 'error'; controlHung = $false; vmName = $Name }
    }
    if ($record -isnot [hashtable]) { return @{ started = $false; reason = 'Start-VM returned no status record'; kind = 'error'; controlHung = $false; vmName = $Name } }
    # The host contract's record may name the failure kind and whether the
    # hypervisor's control channel stopped acting; a driver that does not
    # report them reads as 'none', so the caller's retry policy is unchanged.
    $kind = if ($record.Contains('kind') -and -not [string]::IsNullOrWhiteSpace("$($record['kind'])")) { [string]$record['kind'] } else { 'none' }
    $controlHung = $record.Contains('controlHung') -and [bool]$record['controlHung']
    $result = @{ started = $false; reason = "$($record.errorMessage)"; kind = $kind; controlHung = $controlHung; vmName = $Name }
    foreach ($field in 'hostMemory', 'hostStorage', 'errorCode') {
        if ($record.Contains($field)) { $result[$field] = $record[$field] }
    }
    # Older drivers expose the numeric disk-full code only in their message.
    # Preserve compatibility without treating unrelated English text as a code.
    if ($result.reason -match '(?i)\b0x800700(?:70|27)\b') {
        $result.errorCode = $Matches[0].ToLowerInvariant()
        if ($kind -eq 'none') { $result.kind = 'storage-capacity' }
    }
    if (-not $record.success) { return $result }
    $deadline = (Get-Date).AddSeconds($RunningTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VMState -VMName $Name) -eq 'running') {
            $result.started = $true; $result.reason = $null; $result.kind = 'none'; $result.controlHung = $false
            return $result
        }
        Start-Sleep -Seconds 2
    }
    $result.reason = "start reported success but the VM is '$(Get-VMState -VMName $Name)' after ${RunningTimeoutSeconds}s"
    $result.kind = 'not-running'; $result.controlHung = $false
    return $result
}

# --- REGION: Start-AmisAdEdge
function Start-AmisAdEdge {
    <#
    .SYNOPSIS
        Start all region edges, then require a fresh valid address from each.
    .DESCRIPTION
        See https://yuruna.link/42010605-0006.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [string[]]$Name = @('amisad-edge-a', 'amisad-edge-b'),
        [Parameter(Mandatory)][string]$LogRoot,
        [ValidateRange(0, 3600)][int]$ReadyTimeoutSeconds = 480,
        [ValidateRange(0, 300)][int]$PollSeconds = 10
    )
    $state = @{}
    $address = @{}
    $reportedAt = @{}
    $lines = [System.Collections.Generic.List[string]]::new()
    # Once a start reports that the hypervisor's control channel stopped
    # acting, every further start would wait out the same timeout against the
    # same hung channel: the remaining attempts and edges are skipped, and the
    # verdict names the edge that saw it.
    $controlHung = $false
    $hungEdge = ''
    $storageBlocked = ''
    foreach ($edge in $Name) {
        $report = Join-Path $LogRoot "handoff/$edge.ip.txt"
        $state[$edge] = @{ IpFile = $report; Start = (Get-Date); Started = $false; Ready = $false; Reason = 'not attempted'; Kind = 'none'; Attempts = 0 }
        if (-not $PSCmdlet.ShouldProcess($edge, 'Remove stale IP report and start VM')) { continue }
        if ($controlHung) {
            $state[$edge].Reason = "not attempted: the hypervisor control channel stopped acting on start requests (reported for $hungEdge)"
            $state[$edge].Kind = 'apple-event'
            $lines.Add("Start-VM $edge skipped: $($state[$edge].Reason)")
            continue
        }
        if ($storageBlocked) {
            $state[$edge].Reason = "not attempted: storage capacity must improve before further starts (reported for $storageBlocked)"
            $state[$edge].Kind = 'storage-capacity'
            $lines.Add("Start-VM $edge skipped: $($state[$edge].Reason)")
            continue
        }
        Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
        $state[$edge].Start = Get-Date
        foreach ($attempt in 1..3) {
            $started = Start-VMConfirmed -Name $edge -Confirm:$false
            $state[$edge].Reason = $started.reason
            $state[$edge].Attempts = $attempt
            if ($started.Contains('kind') -and $started.kind) { $state[$edge].Kind = [string]$started.kind }
            foreach ($field in 'hostMemory', 'hostStorage', 'errorCode') {
                if ($started.Contains($field)) { $state[$edge][$field] = $started[$field] }
            }
            if ($started.started) {
                $state[$edge].Started = $true
                break
            }
            $lines.Add("Start-VM $edge attempt ${attempt}/3 failed: $($started.reason)")
            if ($state[$edge].Kind -eq 'storage-capacity' -or ($started.Contains('errorCode') -and $started.errorCode -in @('0x80070070', '0x80070027'))) {
                $storageBlocked = $edge
                $lines.Add("Start-VM $edge`: storage capacity must improve before retrying; no further start is attempted.")
                break
            }
            if ($started.Contains('controlHung') -and [bool]$started.controlHung) {
                $controlHung = $true
                $hungEdge = $edge
                $lines.Add("Start-VM $edge`: the hypervisor control channel is not acting on start requests; no further start is attempted.")
                break
            }
            if ($attempt -lt 3) { Start-Sleep -Seconds $PollSeconds }
        }
    }
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    foreach ($edge in $Name) {
        if (-not $state[$edge].Started) { continue }
        do {
            $report = $state[$edge].IpFile
            $written = if (Test-Path -LiteralPath $report -PathType Leaf) { (Get-Item -LiteralPath $report).LastWriteTime } else { $null }
            if ($written -and $written -gt $state[$edge].Start) {
                $reported = Get-Content -LiteralPath $report -Raw -ErrorAction SilentlyContinue
                $parsed = $null
                if ($reported -and [Net.IPAddress]::TryParse($reported.Trim(), [ref]$parsed)) {
                    $address[$edge] = $reported.Trim()
                    # When the report was written is what later evidence is
                    # read against: an address can be fresh at the report and
                    # still not be one the host's own discovery can find.
                    $reportedAt[$edge] = $written.ToUniversalTime().ToString('o')
                    $lines.Add("$edge reported $($address[$edge]) at $($reportedAt[$edge]).")
                    $state[$edge].Ready = $true
                    $state[$edge].Reason = $null
                    break
                }
            }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds $PollSeconds
        } while ((Get-Date) -lt $deadline)
        if (-not $state[$edge].Ready) { $state[$edge].Reason = 'started but never reported a fresh valid IP address' }
    }
    $missing = @($Name | Where-Object { -not $state[$_].Ready })
    return @{ Ok = $missing.Count -eq 0; State = $state; Address = $address; ReportedAt = $reportedAt; Missing = $missing
              Lines = [string[]]$lines; ControlHung = $controlHung; HungEdge = $hungEdge }
}

# --- REGION: Get-AmisAdEdgeFailure
function Get-AmisAdEdgeFailure {
    <#
    .SYNOPSIS
        Turn a failed Start-AmisAdEdge result into the classified failure the
        cycle record and the remediation loop can route on.
    .DESCRIPTION
        A hypervisor whose control channel stopped acting on start requests is
        `hypervisor_unresponsive`: nothing about the edges is wrong, retrying
        waits out the same timeouts, and only restarting the hypervisor
        application repairs it. Every other way an edge fails to come up --
        a refused start, a VM that never reached running, a boot that never
        reported its address -- is `provisioning_failure`, the class the
        framework's own Start-VM stage uses. One row per missing edge carries
        what was observed, so the record names the edge and its reason rather
        than only the stage.
    .OUTPUTS
        [hashtable] FailureClass, ErrorMessage, DependencyFailures ([hashtable[]]).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$EdgeStartup)
    $controlHung = $EdgeStartup.Contains('ControlHung') -and [bool]$EdgeStartup['ControlHung']
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($edge in @($EdgeStartup['Missing'])) {
        $edgeState = $EdgeStartup['State'][$edge]
        $kind = if ($edgeState -and $edgeState.Contains('Kind')) { [string]$edgeState['Kind'] } else { 'none' }
        $outcome = if ($edgeState -and $edgeState['Started']) { 'no-ip-report' }
                   elseif ($kind -eq 'apple-event') { 'start-not-acted' }
                   else { 'start-failed' }
        $row = @{
            area     = 'amisad-edge'
            vmName   = [string]$edge
            outcome  = $outcome
            detail   = [string]$edgeState['Reason']
            kind     = $kind
            attempts = [int]$(if ($edgeState -and $edgeState.Contains('Attempts')) { $edgeState['Attempts'] } else { 0 })
        }
        foreach ($field in 'hostMemory', 'hostStorage', 'errorCode') {
            if ($edgeState.Contains($field)) { $row[$field] = $edgeState[$field] }
        }
        $rows.Add($row)
    }
    $detail = (@($EdgeStartup['Missing'] | ForEach-Object { "$_ ($($EdgeStartup['State'][$_]['Reason']))" })) -join '; '
    $failureClass = if ($controlHung) { 'hypervisor_unresponsive' } else { 'provisioning_failure' }
    $message = if ($controlHung) {
        "The hypervisor control channel stopped acting on start requests while bringing up the region edges (first seen on $($EdgeStartup['HungEdge'])): $detail"
    } else {
        "Region edges are not live: $detail"
    }
    return @{ FailureClass = $failureClass; ErrorMessage = $message; DependencyFailures = [hashtable[]]$rows.ToArray() }
}

# --- REGION: Write-AmisAdLabFailure
function Write-AmisAdLabFailure {
    <#
    .SYNOPSIS
        Preserve a failed warm-up stage as a classified cycle failure record.
    .DESCRIPTION
        Initialize-Lab runs as a host action in a child process: its exit code
        reaches the orchestrator, its Write-Error text reaches only the
        transcript, and the cycle's failure record would otherwise say no more
        than "exited 1". The framework's infra-stage writer puts a schema-v2
        last_failure.json and a step_failure event in place, and the
        orchestrator inherits the class and description from that file. The
        same path the stash pre-flight uses; nothing here can fail the stage.
    .PARAMETER YurunaRoot
        Framework checkout providing the shared failure record writer.
    .PARAMETER HostType
        Detected host type for the failure record.
    .PARAMETER Stage
        The warm-up stage that failed, recorded as the action.
    .PARAMETER FailureClass
        A canonical class from the framework's failure taxonomy.
    .PARAMETER ErrorMessage
        What the stage saw, as the record's description.
    .PARAMETER DependencyFailures
        Per-item evidence rows, kept under context.dependencyFailures.
    .PARAMETER VMName
        The VM whose startup failed, when the stage names one.
    .PARAMETER StartupFailure
        Structured driver evidence retained through the startup wrappers.
    .OUTPUTS
        [bool] $true when the record was handed to the framework writer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes diagnostic evidence for a stage that has already failed; no lab resource is modified.')]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$FailureClass,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [hashtable[]]$DependencyFailures = @(),
        [string]$VMName = '',
        [hashtable]$StartupFailure = @{}
    )
    if ([string]::IsNullOrWhiteSpace($env:YURUNA_LOG_DIR)) { return $false }
    try {
        # Host actions run in a child process, so the parent's loaded builders
        # are not inherited even though its log directory is.
        foreach ($moduleName in 'Test.SequenceFailureState.psm1', 'Test.StateFile.psm1', 'Test.RunnerInnerLoop.psm1') {
            Import-Module (Join-Path $YurunaRoot "test/modules/$moduleName") -Global -DisableNameChecking -ErrorAction Stop
        }
        $rows = @($DependencyFailures)
        if ($StartupFailure.Count) {
            $row = @{ area = 'vm-start'; vmName = $VMName; outcome = 'start-failed'; detail = $ErrorMessage }
            if ($Stage -like 'StorageAdmission-*') { $row.area = 'host-storage'; $row.outcome = 'admission-refused' }
            foreach ($field in 'hostMemory', 'hostStorage', 'errorCode', 'kind') {
                if ($StartupFailure.Contains($field)) { $row[$field] = $StartupFailure[$field] }
            }
            $rows += $row
        }
        $writeArgs = @{ Stage = $Stage; FailureClass = $FailureClass; Severity = 'hard'; GuestKey = '(orchestration)';
            VMName = $VMName; ErrorMessage = $ErrorMessage; HostType = $HostType; DependencyFailures = [hashtable[]]$rows }
        $writer = Get-Command Write-CycleInfraFailure -ErrorAction Stop
        foreach ($field in 'HostMemory', 'HostStorage') {
            if ($StartupFailure.Contains($field) -and $writer.Parameters.ContainsKey($field)) { $writeArgs[$field] = $StartupFailure[$field] }
        }
        Write-CycleInfraFailure @writeArgs
        return $true
    } catch {
        Write-Verbose "Write-AmisAdLabFailure: $($_.Exception.Message)"
        return $false
    }
}

# --- REGION: Save-AmisAdControlSnapshot
function Save-AmisAdControlSnapshot {
    <#
    .SYNOPSIS
        Record the hypervisor's control-channel state beside the stage logs
        when the edges failed to come up, on a host whose driver can.
    .DESCRIPTION
        The macOS driver records UTM's process census, its listing, recent
        crash reports and a unified-log excerpt; the screenshot is of the edge
        that was started but never reported, the one whose console is the
        only remaining witness. Drivers without the verb record nothing, and
        nothing here can fail the stage.
    .OUTPUTS
        The driver's snapshot result, or $null when no driver verb exists.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes diagnostic evidence for a stage that has already failed; no lab resource is modified.')]
    param(
        [Parameter(Mandatory)][hashtable]$EdgeStartup,
        [Parameter(Mandatory)][string]$LogDir
    )
    if (-not (Get-Command -Name Save-UtmControlSnapshot -ErrorAction SilentlyContinue)) { return $null }
    $witness = ''
    foreach ($edge in @($EdgeStartup['Missing'])) {
        $edgeState = $EdgeStartup['State'][$edge]
        if ($edgeState -and $edgeState['Started'] -and -not $edgeState['Ready']) { $witness = [string]$edge; break }
    }
    try {
        return (Save-UtmControlSnapshot -OutputDirectory $LogDir -Trigger 'initialize-lab-edge-start' -VMName $witness -Confirm:$false)
    } catch {
        Write-Verbose "Save-AmisAdControlSnapshot: $($_.Exception.Message)"
        return $null
    }
}

# --- REGION: Save-AmisAdEdgeAddressEvidence
function Save-AmisAdEdgeAddressEvidence {
    <#
    .SYNOPSIS
        Record, beside the stage logs, which address each edge was reached at
        and what the host's own discovery says about it now, when the demo key
        hand-off failed.
    .DESCRIPTION
        A failed hand-off is read against three facts that are gone a minute
        later: the address the edge reported and when, what the host driver's
        discovery returns at failure time (an empty answer is the case where
        dialing the bare VM name fails in DNS), and the hypervisor's view of
        the guest's network. edge-address-evidence.json keeps the first two;
        a driver with Save-VMNetworkState (Hyper-V) adds its network-state
        capture. Nothing here can fail the stage.
    .PARAMETER EdgeVm
        The edge VM names.
    .PARAMETER EdgeAddress
        Name -> address the edge reported (Start-AmisAdEdge's Address).
    .PARAMETER ReportedAt
        Name -> UTC time of that report (Start-AmisAdEdge's ReportedAt).
    .PARAMETER LogDir
        Where the evidence is written.
    .PARAMETER AdditionalVm
        Other VMs involved in the failure, including a core that could not start.
    .OUTPUTS
        [pscustomobject] Written, Path, Lines (to print).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes diagnostic evidence for a stage that has already failed; no lab resource is modified.')]
    param(
        [Parameter(Mandatory)][string[]]$EdgeVm,
        [hashtable]$EdgeAddress = @{},
        [hashtable]$ReportedAt = @{},
        [Parameter(Mandatory)][string]$LogDir,
        [string[]]$AdditionalVm = @()
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $records = [System.Collections.Generic.List[object]]::new()
    $canDiscover = [bool](Get-Command -Name Get-VMIp -ErrorAction SilentlyContinue)
    $canCapture = [bool](Get-Command -Name Save-VMNetworkState -ErrorAction SilentlyContinue)
    $diagnostics = @{}
    foreach ($vm in (@($EdgeVm) + @($AdditionalVm) | Select-Object -Unique)) {
        # Driver filenames are fixed. Each VM needs its own directory so a
        # later snapshot cannot overwrite the machine that failed first.
        $directory = Join-Path $LogDir ([Uri]::EscapeDataString($vm))
        $captured = $null
        if ($canCapture) {
            try { $captured = [bool](Save-VMNetworkState -VMName $vm -OutputDirectory $directory) }
            catch { $captured = $false; Write-Verbose "Save-VMNetworkState ${vm}: $($_.Exception.Message)" }
        }
        $storage = @{ status = 'unknown'; reason = 'The host driver does not expose storage capacity evidence.' }
        if (Get-Command Test-VMStorageCapacity -ErrorAction SilentlyContinue) {
            try { $storage = Test-VMStorageCapacity -VMName $vm }
            catch { $storage = @{ status = 'unknown'; reason = $_.Exception.Message } }
        }
        $diagnostics[$vm] = @{ directory = $directory; networkStateSaved = $captured; hostStorage = $storage }
    }
    foreach ($edge in $EdgeVm) {
        $discovered = $null
        $discoveryError = $null
        if ($canDiscover) {
            try { $discovered = [string](Get-VMIp -VMName $edge) } catch { $discoveryError = $_.Exception.Message }
        }
        $reported = if ($EdgeAddress.ContainsKey($edge)) { [string]$EdgeAddress[$edge] } else { $null }
        $records.Add([ordered]@{
            vm                = $edge
            reportedAddress   = $reported
            reportedAtUtc     = if ($ReportedAt.ContainsKey($edge)) { [string]$ReportedAt[$edge] } else { $null }
            discoveryChecked  = $canDiscover
            discoveredAddress = if ($discovered) { $discovered } else { $null }
            discoveryError    = $discoveryError
            networkStateSaved = $diagnostics[$edge].networkStateSaved
        })
        $seen = if (-not $canDiscover) { 'no discovery verb on this host' }
                elseif ($discoveryError) { "discovery failed: $discoveryError" }
                elseif ($discovered) { "discovery now returns $discovered" }
                else { 'discovery now returns nothing' }
        $lines.Add("${edge}: reported $(if ($reported) { $reported } else { 'no address' }); $seen.")
    }
    $path = Join-Path $LogDir 'edge-address-evidence.json'
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        [ordered]@{ capturedAtUtc = [DateTime]::UtcNow.ToString('o'); edges = $records.ToArray(); vmDiagnostics = $diagnostics } |
            ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding utf8
        $lines.Add("Edge address evidence: $path")
        return [pscustomobject]@{ Written = $true; Path = $path; Lines = [string[]]$lines }
    } catch {
        Write-Verbose "Save-AmisAdEdgeAddressEvidence: $($_.Exception.Message)"
        return [pscustomobject]@{ Written = $false; Path = $path; Lines = [string[]]$lines }
    }
}

# --- REGION: Remove-LegacyDemoKey
function Remove-LegacyDemoKey {
    <#
    .SYNOPSIS
        Delete a core->edge demo key that an earlier lab run left in the status
        service's served tree.
    .DESCRIPTION
        See https://yuruna.link/42010605-0006.
    .PARAMETER YurunaRoot
        Yuruna framework checkout whose status service served the file.
    .OUTPUTS
        [string[]] progress lines to print; empty when nothing was found.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$YurunaRoot)

    $handoff = Join-Path $YurunaRoot 'test/status/handoff'
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($name in 'amisad-demo-key', 'amisad-demo-key.pub') {
        $path = Join-Path $handoff $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (-not $PSCmdlet.ShouldProcess($path, 'Delete the legacy served demo key')) { continue }
        Remove-Item -LiteralPath $path -Force
        $lines.Add("Removed the legacy demo key file '$path'. That directory is served to the whole LAN by the status service, so treat the key as exposed: a long-lived VM that still trusts it must be rebuilt, or have its authorized_keys line ending in 'amisad-demo' removed.")
    }
    if ((Test-Path -LiteralPath $handoff -PathType Container) -and -not (Get-ChildItem -LiteralPath $handoff -Force)) {
        if ($PSCmdlet.ShouldProcess($handoff, 'Remove the empty legacy hand-off directory')) {
            Remove-Item -LiteralPath $handoff -Force
        }
    }
    return [string[]]$lines
}

# --- REGION: ConvertTo-AmisAdDemoPublicKey
function ConvertTo-AmisAdDemoPublicKey {
    <#
    .SYNOPSIS
        Reduce text read from a guest to one canonical ed25519 public-key line,
        or refuse it.
    .DESCRIPTION
        The text comes out of a VM and is about to be written into another VM's
        authorized_keys through a shell command line, so it is not trusted:
        exactly one OpenSSH ed25519 public key is accepted, rebuilt with the
        fixed comment 'amisad-demo' (the marker an edge uses to replace an older
        key). Anything else -- a private key block, several lines, another key
        type, shell metacharacters -- throws, and nothing is built from it.
    .PARAMETER Text
        What 'cat ~/.ssh/amisad-demo-key.pub' printed.
    .OUTPUTS
        [string] 'ssh-ed25519 <base64> amisad-demo'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $lines = @(([string]$Text) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -ne 1) {
        throw "Expected exactly one public-key line from the core, got $($lines.Count)."
    }
    # AAAAC3NzaC1lZDI1NTE5AAAAI is the wire header of an ed25519 key (type
    # string, then a 32-byte length); 43 characters finish its 68-character body.
    $match = [regex]::Match($lines[0], '^ssh-ed25519 (AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43})(?: .*)?$')
    if (-not $match.Success) {
        throw 'The core did not return an ssh-ed25519 public key (is amisad-demo-key.pub the file that was read?).'
    }
    return "ssh-ed25519 $($match.Groups[1].Value) amisad-demo"
}

# --- REGION: Get-AmisAdKeyFingerprint
function Get-AmisAdKeyFingerprint {
    <#
    .SYNOPSIS
        The SHA256 fingerprint ssh-keygen -l prints for a canonical public-key line.
    .PARAMETER PublicKey
        A line returned by ConvertTo-AmisAdDemoPublicKey.
    .OUTPUTS
        [string] 'SHA256:<unpadded base64>'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$PublicKey)

    $blob = [Convert]::FromBase64String(($PublicKey -split ' ')[1])
    $digest = [Security.Cryptography.SHA256]::HashData($blob)
    return 'SHA256:' + [Convert]::ToBase64String($digest).TrimEnd('=')
}

# --- REGION: Get-AmisAdAuthorizeKeyCommand
function Get-AmisAdAuthorizeKeyCommand {
    <#
    .SYNOPSIS
        The shell command that makes an edge trust exactly one demo public key.
    .DESCRIPTION
        Idempotent by construction: it rewrites authorized_keys without any line
        whose last field is 'amisad-demo', then appends the given key, so a
        re-run leaves one entry and a rotated key invalidates the previous one
        instead of sitting beside it for good. Other keys (the harness's) are
        kept. The new file is written beside the old one and moved over it, so
        a failure part-way leaves the previous authorized_keys intact, and the
        mode is 0600 throughout.
    .PARAMETER PublicKey
        A line from ConvertTo-AmisAdDemoPublicKey. It is validated again here:
        this is the only place it enters a command line.
    .OUTPUTS
        [string] a single-line command for the edge's login shell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$PublicKey)

    $line = ConvertTo-AmisAdDemoPublicKey -Text $PublicKey
    $template = @'
umask 077; d="$HOME/.ssh"; f="$d/authorized_keys"; mkdir -p "$d" && chmod 700 "$d" && touch "$f" && t=$(mktemp "$d/.authorized_keys.XXXXXX") && awk '$NF != "amisad-demo"' "$f" > "$t" && printf '%s\n' '__PUBLIC_KEY__' >> "$t" && chmod 600 "$t" && mv -f "$t" "$f" && sync
'@
    return $template.Trim().Replace('__PUBLIC_KEY__', $line)
}

# --- REGION: Get-AmisAdEdgeLoginCommand
function Get-AmisAdEdgeLoginCommand {
    <#
    .SYNOPSIS
        The command, run ON vm-core, that proves it can log in to an edge with
        the demo key.
    .PARAMETER EdgeUser
        The edge's administrator account (<hostname>-admin).
    .PARAMETER EdgeAddress
        The edge's IP address.
    .OUTPUTS
        [string] a single-line command for vm-core's login shell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$EdgeUser,
        [Parameter(Mandatory)][string]$EdgeAddress
    )
    if ($EdgeUser -cnotmatch '^[a-z][a-z0-9-]*$') { throw "'$EdgeUser' is not an acceptable account name." }
    if ($EdgeAddress -cnotmatch '^[0-9A-Fa-f:.]+$') { throw "'$EdgeAddress' is not an IP address." }
    return 'ssh -i "$HOME/.ssh/amisad-demo-key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 {0}@{1} true' -f $EdgeUser, $EdgeAddress
}

# --- REGION: Sync-AmisAdDemoKey
function Sync-AmisAdDemoKey {
    <#
    .SYNOPSIS
        Authorize the PUBLIC half of vm-core's demo key on the edge VMs, over
        the harness SSH channel, and prove the login works.
    .DESCRIPTION
        See https://yuruna.link/42010605-0006.
    .PARAMETER YurunaRoot
        Yuruna framework checkout; supplies the SSH helper when -InvokeGuest is
        not given.
    .PARAMETER CoreVm
        vm-core's VM name. Its administrator is <name>-admin.
    .PARAMETER EdgeVm
        The edge VM names. Each administrator is <name>-admin.
    .PARAMETER EdgeAddress
        Optional name -> IP map of the addresses the edges just reported. Every
        SSH call to an edge (readiness, key install) dials that address, and the
        login proof targets it; an edge without an entry falls back to the host
        driver's discovery. A fresh report is the stronger evidence: discovery
        can come back empty while the guest is reachable at the address it
        reported.
    .PARAMETER InvokeGuest
        Test seam: a scriptblock taking (VMName, User, Command, TimeoutSeconds,
        Address) and returning @{ success; exitCode; output }. Address is empty
        when no reported address is known. The default wraps the framework's
        Invoke-GuestSsh, passing a known address as -ResolvedAddress.
    .PARAMETER ReadySeconds
        How long to wait for vm-core's SSH after starting it, and for each
        edge's SSH before the key is installed there (an address report proves
        the network is up, not that sshd is accepting logins yet).
    .PARAMETER PollSeconds
        Pause between attempts.
    .OUTPUTS
        [pscustomobject] Ok, Lines (to print), Fingerprint, Reason (when not Ok).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [string]$CoreVm = 'amisad-core',
        [string[]]$EdgeVm = @('amisad-edge-a', 'amisad-edge-b'),
        [hashtable]$EdgeAddress = @{},
        [scriptblock]$InvokeGuest,
        [int]$ReadySeconds = 300,
        [int]$PollSeconds = 10
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $fail = {
        param([string]$Reason, [string]$Stage = 'Sync-AmisAdDemoKey', [string]$VMName = '', [hashtable]$StartupFailure = @{})
        $label = if ($Stage -eq 'Start-AmisAdCore') { "$VMName startup failed" } else { 'Demo key hand-off failed' }
        $lines.Add("${label}: $Reason")
        $failureClass = if ($StartupFailure.Contains('controlHung') -and $StartupFailure.controlHung) { 'hypervisor_unresponsive' } else { 'provisioning_failure' }
        return [pscustomobject]@{ Ok = $false; Lines = [string[]]$lines; Fingerprint = ''; Reason = $Reason;
            Stage = $Stage; VMName = $VMName; StartupFailure = $StartupFailure; FailureClass = $failureClass }
    }
    if (-not $PSCmdlet.ShouldProcess("$CoreVm -> $($EdgeVm -join ', ')", 'Authorize the demo public key on the edges')) {
        return [pscustomobject]@{ Ok = $true; Lines = [string[]]@(); Fingerprint = ''; Reason = '' }
    }

    if (-not $InvokeGuest) {
        if (-not (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $YurunaRoot 'test/modules/Test.Ssh.psm1') -Global -DisableNameChecking -Verbose:$false
        }
        $InvokeGuest = {
            param([string]$VMName, [string]$User, [string]$Command, [int]$TimeoutSeconds, [string]$Address)
            if ($Address) {
                Invoke-GuestSsh -VMName $VMName -User $User -Command $Command -TimeoutSeconds $TimeoutSeconds -ResolvedAddress $Address
            } else {
                Invoke-GuestSsh -VMName $VMName -User $User -Command $Command -TimeoutSeconds $TimeoutSeconds
            }
        }
    }

    # --- REGION: Wait for core SSH
    if ((Get-Command Get-VMState -ErrorAction SilentlyContinue) -and ((Get-VMState -VMName $CoreVm) -ne 'running')) {
        $lines.Add("Starting $CoreVm to read its demo public key.")
        $started = Start-VMConfirmed -Name $CoreVm -Confirm:$false
        if (-not $started.started) { return (& $fail "$CoreVm did not start: $($started.reason)" 'Start-AmisAdCore' $CoreVm $started) }
    }
    $coreUser = "$CoreVm-admin"
    $deadline = (Get-Date).AddSeconds($ReadySeconds)
    $answering = $false
    do {
        $probe = & $InvokeGuest $CoreVm $coreUser 'true' 30
        if ($probe.success) { $answering = $true; break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    if (-not $answering) { return (& $fail "$CoreVm did not answer SSH within ${ReadySeconds}s ($($probe.output))") }

    # --- REGION: Read demo public key
    $read = & $InvokeGuest $CoreVm $coreUser 'cat "$HOME/.ssh/amisad-demo-key.pub"' 60
    if (-not $read.success) {
        return (& $fail "could not read $CoreVm's demo public key (exit $($read.exitCode)); did the users step of the deploy run? $($read.output)")
    }
    try { $publicKey = ConvertTo-AmisAdDemoPublicKey -Text $read.output }
    catch { return (& $fail "$CoreVm's demo public key is unusable: $($_.Exception.Message)") }
    $fingerprint = Get-AmisAdKeyFingerprint -PublicKey $publicKey
    $lines.Add("$CoreVm demo key: $fingerprint")

    # --- REGION: Authorize demo public key
    $authorize = Get-AmisAdAuthorizeKeyCommand -PublicKey $publicKey
    foreach ($edge in $EdgeVm) {
        $edgeUser = "$edge-admin"
        $edgeTarget = if ($EdgeAddress.ContainsKey($edge)) { ([string]$EdgeAddress[$edge]).Trim() } else { '' }
        $where = if ($edgeTarget) { "at $edgeTarget" } else { "at its discovered address" }
        if ($edgeTarget) { $lines.Add("Reaching $edge at $edgeTarget, the address it reported.") }
        else { $lines.Add("No reported address for $edge; the host driver's discovery chooses one.") }
        $edgeDeadline = (Get-Date).AddSeconds($ReadySeconds)
        $edgeProbe = $null
        do {
            $edgeProbe = & $InvokeGuest $edge $edgeUser 'true' 30 $edgeTarget
            if ($edgeProbe.success) { break }
            Start-Sleep -Seconds $PollSeconds
        } while ((Get-Date) -lt $edgeDeadline)
        if (-not $edgeProbe.success) {
            return (& $fail "$edge did not answer SSH $where within ${ReadySeconds}s (exit $($edgeProbe.exitCode)): $($edgeProbe.output)")
        }
        $done = $null
        foreach ($attempt in 1..3) {
            $done = & $InvokeGuest $edge $edgeUser $authorize 120 $edgeTarget
            if ($done.success) { break }
            if ($attempt -lt 3) { Start-Sleep -Seconds $PollSeconds }
        }
        if (-not $done.success) { return (& $fail "could not authorize the demo key on $edge $where (exit $($done.exitCode)): $($done.output)") }
        $lines.Add("$edge now trusts $fingerprint (any earlier amisad-demo entry replaced).")
    }

    # --- REGION: Verify core-to-edge login
    foreach ($edge in $EdgeVm) {
        $address = if ($EdgeAddress.ContainsKey($edge)) { [string]$EdgeAddress[$edge] }
                   elseif (Get-Command Get-VMIp -ErrorAction SilentlyContinue) { [string](Get-VMIp -VMName $edge) }
                   else { '' }
        if ([string]::IsNullOrWhiteSpace($address)) {
            $lines.Add("Skipped the login check for ${edge}: no address is known for it yet.")
            continue
        }
        $login = Get-AmisAdEdgeLoginCommand -EdgeUser "$edge-admin" -EdgeAddress $address.Trim()
        $proved = $null
        foreach ($attempt in 1..6) {
            $proved = & $InvokeGuest $CoreVm $coreUser $login 60
            if ($proved.success) { break }
            if ($attempt -lt 6) { Start-Sleep -Seconds $PollSeconds }
        }
        if (-not $proved.success) {
            return (& $fail "$CoreVm cannot log in to $edge at $address with the demo key (exit $($proved.exitCode)): $($proved.output)")
        }
        $lines.Add("$CoreVm logs in to $edge at $address with the demo key.")
    }

    return [pscustomobject]@{ Ok = $true; Lines = [string[]]$lines; Fingerprint = $fingerprint; Reason = '' }
}

Export-ModuleMember -Function Invoke-AmisAdScript, Invoke-AmisAdStage, Invoke-AmisAdCleanup,
    Test-AmisAdStorageAdmission,
    Remove-InstallMedia, Set-EdgeMemory, Start-VMConfirmed, Start-AmisAdEdge, Get-AmisAdEdgeFailure, Write-AmisAdLabFailure, Save-AmisAdControlSnapshot,
    Save-AmisAdEdgeAddressEvidence, Remove-LegacyDemoKey,
    ConvertTo-AmisAdDemoPublicKey, Get-AmisAdKeyFingerprint, Get-AmisAdAuthorizeKeyCommand,
    Get-AmisAdEdgeLoginCommand, Sync-AmisAdDemoKey
