<#PSScriptInfo
.VERSION 2026.11.26
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
. (Join-Path $PSScriptRoot 'AmisAd.LabWorkflow.ps1')

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
        [Parameter(Mandatory)][string]$ErrorPath,
        [string]$YurunaRoot
    )
    $native = Invoke-AmisAdNativeStage -YurunaRoot $YurunaRoot -ScriptPath $ScriptPath -ScriptArguments $ScriptArguments `
        -OutputPath $OutputPath -ErrorPath $ErrorPath
    if ($null -ne $native) { return $native }
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
        [string]$YurunaRoot,
        [switch]$NoConfigGate,
        [switch]$NoProjectClone
    )
    Stop-LabConsole -HostType $HostType -YurunaRoot $YurunaRoot
    $out = Join-Path $LogDir "$Name.out.log"
    $err = Join-Path $LogDir "$Name.err.log"
    $stageArgs = @($Sequence)
    if ($NoProjectClone) { $stageArgs += '-NoProjectClone' }
    if ($NoConfigGate) { $stageArgs += '-NoConfigGate' }
    Write-Information "===== [$Name] $Sequence  $([DateTime]::Now.ToString('s'))  (log: $out) =====" -InformationAction Continue
    $exitCode = Invoke-AmisAdScript -ScriptPath $SequenceScript -ScriptArguments $stageArgs -OutputPath $out -ErrorPath $err `
        -YurunaRoot $YurunaRoot
    Write-Information "===== [$Name] exited $exitCode  $([DateTime]::Now.ToString('s')) =====" -InformationAction Continue
    if ($exitCode -ne 0) {
        Get-Content -LiteralPath $out -Tail 25 -ErrorAction SilentlyContinue | Out-Host
        Get-Content -LiteralPath $err -Tail 10 -ErrorAction SilentlyContinue | Out-Host
    }
    return $exitCode
}

# --- REGION: Test-AmisAdFreshSignedBuild
function Get-AmisAdNativeFreshBuild {
    [OutputType([bool])]
    param([string]$YurunaRoot, [string]$BuilderConfig, [string]$BuilderModule, [string]$HostType)

    if (-not (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot)) { return }
    $verb = 'amisad-lab-fresh-build'
    try {
        $prepared = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb $verb `
            -Argument @{ Operation = 'prepare'; ConfigPath = $BuilderConfig; HostType = $HostType } -TimeoutSeconds 10
    } catch {
        if ($_.Exception.Message -cne "host-binary-command-failed: $verb (unknown-verb)") { throw }
        return
    }
    if (-not $prepared.Used) { return }
    $plan = $prepared.Value
    if ($plan -isnot [Collections.IDictionary] -or $plan['handled'] -isnot [bool]) {
        throw 'The native fresh build plan is invalid.'
    }
    if (-not $plan.handled) { return }
    if ($plan['eligible'] -isnot [bool]) { throw 'The native fresh build plan is invalid.' }
    if (-not $plan.eligible) { return $false }
    if ($plan['candidate'] -cnotmatch '^[a-f0-9]{64}$' -or
        $plan['target'] -cnotin 'x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu' -or
        $plan['inventoryPrefixes'] -isnot [array] -or $plan['artifacts'] -isnot [array]) {
        throw 'The native fresh build plan is invalid.'
    }
    # An enrolled manifest can only be applied to a newly seeded core.
    if (@(Get-VMName -Prefix $plan.inventoryPrefixes -ErrorAction Stop).Count) { return $false }
    Import-Module $BuilderModule -DisableNameChecking -ErrorAction Stop
    $seed = Get-BuildServiceGuestSeed -ConfigPath $BuilderConfig -Target $plan.target -AmisAd -Binary $plan.artifacts -VerifyManifest
    if (-not $seed) { return $false }
    $verified = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb $verb -TimeoutSeconds 10 `
        -Argument @{ Operation = 'confirm'; Candidate = $plan.candidate; Target = $plan.target } `
        -InputBytes ([Text.Encoding]::UTF8.GetBytes($seed))
    return ($verified.Used -and $verified.Value -is [bool] -and $verified.Value)
}

function Test-AmisAdFreshSignedBuild {
    <#
    .SYNOPSIS
        Select centralized binaries when the core will receive a fresh seed.
    .DESCRIPTION
        A configured builder cannot upgrade the seed inside a retained VM.
        Require an empty core inventory as well as the enrolled signed set.
        Any unknown inventory or unproven plan keeps the existing build path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [Parameter(Mandatory)][string]$HostType,
        [string]$StashPin
    )
    if ($StashPin -or $env:YURUNA_STASH_SERVICE_HOST) { return $false }
    try {
        $testRoot = Join-Path $YurunaRoot 'test'
        $configPath = Join-Path $testRoot 'test.config.yml'
        $configModule = Join-Path $testRoot 'modules/Test.Config.psm1'
        $builderModule = Join-Path $testRoot 'extension/build-service/default.psm1'
        if (@($configPath, $configModule, $builderModule | Where-Object { -not [IO.File]::Exists($_) }).Count) { return $false }
        Import-Module $configModule -DisableNameChecking -ErrorAction Stop
        $config = Read-TestConfig -Path $configPath -ThrowOnError
        if (-not $config.vmStart.buildServiceConfigFile) { return $false }
        $builderConfig = [IO.Path]::GetFullPath($config.vmStart.buildServiceConfigFile, $testRoot)
        $native = Get-AmisAdNativeFreshBuild -YurunaRoot $YurunaRoot -BuilderConfig $builderConfig `
            -BuilderModule $builderModule -HostType $HostType
        if ($null -ne $native) { return $native }
        $settings = [IO.File]::ReadAllText($builderConfig) | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop
        if ($settings.consumer.amisad.runtimeBundle -isnot [bool] -or -not $settings.consumer.amisad.runtimeBundle) { return $false }
        # Root names and the test VM prefix are both candidates for reuse.
        if (@(Get-VMName -Prefix @('amisad-core', 'test-') -ErrorAction Stop).Count) { return $false }
        Import-Module $builderModule -DisableNameChecking -ErrorAction Stop
        $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        if ($arch -notin @('X64', 'Arm64')) { return $false }
        $target = if ($HostType -like '*.utm' -or $arch -eq 'Arm64') { 'aarch64-unknown-linux-gnu' } else { 'x86_64-unknown-linux-gnu' }
        $files = 'amisad-provision', 'framework-revision', 'seller-svc', 'resource-svc', 'ads-svc',
            'insights-svc', 'platform-svc', 'audit-svc', 'connect-svc', 'fabric-coordinator',
            'identity-mock', 'ledger-svc', 'slice-runtime', 'buyer-client'
        $plan = Get-BuildServiceGuestSeed -ConfigPath $builderConfig -Target $target -AmisAd -Binary $files -VerifyManifest
        if (-not $plan) { return $false }
        $verified = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($plan)) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return ($verified.runtimeBundle -is [bool] -and $verified.runtimeBundle -and
            $verified.target -ceq $target -and $verified.candidate -ceq $settings.consumer.amisad.candidateId)
    } catch {
        Write-Verbose "Centralized AmisAd artifacts not selected: $($_.Exception.Message)"
        return $false
    }
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
        [Parameter(Mandatory)][string]$LogDir,
        [string]$YurunaRoot
    )
    foreach ($value in $Prefix) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'A cleanup prefix cannot be empty.' }
    }
    $cleanup = @{ Script = $SweepScript; LogDir = $LogDir; YurunaRoot = $YurunaRoot }
    Invoke-AmisAdLabPlan -YurunaRoot $YurunaRoot -Request @{ kind = 'cleanup'; prefixes = $Prefix } -InvokeStep {
        param($step)
        $out = Join-Path $cleanup.LogDir "cleanup-$($step.index).out.log"
        $err = Join-Path $cleanup.LogDir "cleanup-$($step.index).err.log"
        $exitCode = Invoke-AmisAdScript -ScriptPath $cleanup.Script -ScriptArguments @('-Prefix', $step.prefix) -OutputPath $out -ErrorPath $err `
            -YurunaRoot $cleanup.YurunaRoot
        Get-Content -LiteralPath $out, $err -ErrorAction SilentlyContinue | Out-Host
        return $exitCode
    }
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
    .PARAMETER UseSignedBuild
        The lab selected a verified centralized build and will not create an AmisAd build VM.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][ValidateSet('BeforeProvisioning', 'BeforeStart')][string]$Stage,
        [switch]$IncludeDiskGrowth,
        [switch]$UseSignedBuild
    )
    if ($HostType -ne 'host.windows.hyper-v') { return @{ allowed = $true; status = 'not-applicable'; reason = '' } }
    $evidence = @{ allowed = $true; status = 'unknown'; reason = 'Storage admission is unavailable: the host driver has no Test-VMStorageCapacity helper.';
                   timestamp = [DateTime]::UtcNow.ToString('o') }
    $nativeAdmission = Test-AmisAdNativeStorageAdmission -YurunaRoot $YurunaRoot
    $capacityCommand = Get-Command Test-VMStorageCapacity -ErrorAction SilentlyContinue
    if ($capacityCommand) {
        $policyPath = Join-Path $PSScriptRoot 'host-storage.requirements.json'
        $supportsProvisioningMemory = $capacityCommand.Parameters.ContainsKey('ProvisioningMemoryBytes')
        if ($nativeAdmission) {
            $selection = @{ IncludeDiskGrowth = [bool]$IncludeDiskGrowth; UseSignedBuild = [bool]$UseSignedBuild;
                SupportsProvisioningMemory = $supportsProvisioningMemory }
            $plan = Invoke-AmisAdStorageVerb -YurunaRoot $YurunaRoot -Operation plan -Argument $selection `
                -InputBytes ([IO.File]::ReadAllBytes($policyPath)) -TimeoutSeconds 5
            if ($null -eq $plan) { $nativeAdmission = $false }
        }
        if ($nativeAdmission) {
            if ($plan.vmName -isnot [array] -or $plan.startupMemoryBytes -isnot [Collections.IDictionary] -or
                $plan.additionalStorageBytes -isnot [Collections.IDictionary] -or $plan.reserveBytes -isnot [long]) {
                throw 'The native storage admission plan is invalid.'
            }
            $capacityArgs = @{ VMName = [string[]]$plan.vmName; StartupMemoryBytes = [hashtable]$plan.startupMemoryBytes;
                AdditionalStorageBytes = [hashtable]$plan.additionalStorageBytes; ReserveBytes = $plan.reserveBytes }
            if ($IncludeDiskGrowth -and $supportsProvisioningMemory) {
                if ($plan.provisioningMemoryBytes -isnot [long]) { throw 'The native storage plan omitted the provisioning peak.' }
                $capacityArgs.ProvisioningMemoryBytes = $plan.provisioningMemoryBytes
            }
        } else {
            $requirements = Get-Content -LiteralPath $policyPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $memory = @{}
            $growth = @{}
            foreach ($vm in $requirements.virtualMachines) {
                if ($UseSignedBuild -and $vm.name -eq 'amisad-build') { continue }
                if (-not $IncludeDiskGrowth -and [long]$vm.startupMemoryBytes -eq 0) { continue }
                $memory[$vm.name] = [long]$vm.startupMemoryBytes
                if ($IncludeDiskGrowth) { $growth[$vm.name] = [long]$vm.additionalStorageBytes }
            }
            if ($IncludeDiskGrowth -and -not $UseSignedBuild -and -not $memory.ContainsKey('amisad-build')) {
                # The fallback needs a build disk even though the VM is off at startup.
                $memory['amisad-build'] = 0L
                $growth['amisad-build'] = 16GB
            }
            $capacityArgs = @{ VMName = [string[]]$memory.Keys; StartupMemoryBytes = $memory;
                AdditionalStorageBytes = $growth; ReserveBytes = [long]$requirements.reserveBytes }
            if ($IncludeDiskGrowth -and $supportsProvisioningMemory) {
                $capacityArgs.ProvisioningMemoryBytes = [long]$requirements.provisioningMemoryBytes
            }
        }
        try {
            $evidence = Test-VMStorageCapacity @capacityArgs
        } catch {
            $evidence = @{ allowed = $true; status = 'unknown'; reason = "Storage admission is unavailable: $($_.Exception.Message)";
                           timestamp = [DateTime]::UtcNow.ToString('o') }
        }
    }
    try {
        $json = $evidence | ConvertTo-Json -Depth 15
        $nativeWritten = $false
        if ($nativeAdmission) {
            $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDir)
            $reply = Invoke-AmisAdStorageVerb -YurunaRoot $YurunaRoot -Operation evidence `
                -Argument @{ LogDirectory = $directory; Stage = $Stage } `
                -InputBytes ([Text.Encoding]::UTF8.GetBytes($json + [Environment]::NewLine)) -TimeoutSeconds 10
            if ($null -ne $reply) {
                if ($reply.written -ne $true) { throw 'The native host did not confirm the storage admission evidence write.' }
                $nativeWritten = $true
            }
        }
        if (-not $nativeWritten) {
            New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
            $json | Set-Content -LiteralPath (Join-Path $LogDir "storage-admission.$Stage.json") -Encoding utf8 -ErrorAction Stop
        }
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
    param([string]$Name, [string]$SnapshotId, [Parameter(Mandatory)][string]$HostType, [string]$YurunaRoot)
    if ($HostType -ne 'host.windows.hyper-v') {
        Write-Verbose "Remove-InstallMedia: not applicable on '$HostType'."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Remove install media + retake checkpoint')) { return }
    if ((-not $SnapshotId -or (Get-Command Update-HyperVGuestCheckpoint -ErrorAction SilentlyContinue)) -and
        (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot)) {
        $native = $null
        try {
            $native = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'hyperv-detach-install-media' `
                -Argument @{ VMName = $Name } -TimeoutSeconds 95
        } catch {
            if ($_.Exception.Message -cne 'host-binary-command-failed: hyperv-detach-install-media (unknown-verb)') { throw }
        }
        if ($native -and $native.Used) {
            if ($native.Value -isnot [Collections.IDictionary] -or $native.Value['supported'] -isnot [bool]) {
                throw "Hyper-V did not confirm DVD removal for $Name."
            }
            if ($native.Value['supported']) {
                $vmId = [guid]::Empty
                if (-not [guid]::TryParse([string]$native.Value['vmId'], [ref]$vmId) -or $vmId -eq [guid]::Empty) {
                    throw "Hyper-V did not confirm the DVD removal target for $Name."
                }
                if ($SnapshotId) {
                    $retake = Update-HyperVGuestCheckpoint -VMName $Name -VMId $vmId -SnapshotName $SnapshotId -Confirm:$false
                    if (-not $retake.Success) { throw "Could not retake checkpoint '$SnapshotId' on $Name." }
                    if ($retake.Retaken) {
                        Write-Information "Retook checkpoint '$SnapshotId' on $Name without install media." -InformationAction Continue
                    }
                }
                return
            }
        }
    }
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
    param([string]$Name, [Parameter(Mandatory)][string]$HostType, [string]$YurunaRoot)
    if ($HostType -ne 'host.windows.hyper-v') {
        Write-Verbose "Set-EdgeMemory: guest memory is a provisioning-time property on '$HostType'; leaving $Name as built."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Set static memory to 4GB')) { return }
    $applied = $false
    if (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot) {
        if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '\p{Cc}') { throw 'Missing or invalid VM name.' }
        try {
            $native = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'hyperv-compute' `
                -Argument @{ VMName = $Name; MemoryBytes = 4GB; StaticMemoryOnly = $true } -TimeoutSeconds 90
            if ($native.Used) {
                if ($native.Value -isnot [bool] -or -not $native.Value) { throw "Hyper-V did not confirm static memory for $Name." }
                $applied = $true
            }
        } catch {
            if ($_.Exception.Message -cnotin 'host-binary-command-failed: hyperv-compute (unknown-verb)', `
                'host-binary-command-failed: hyperv-compute (invalid-arguments)') { throw }
        }
    }
    if (-not $applied) { Hyper-V\Set-VM -Name $Name -StaticMemory -MemoryStartupBytes 4GB }
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
    param([string]$Name, [int]$RunningTimeoutSeconds = 60, [string]$YurunaRoot)
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
    $deadline = [Environment]::TickCount64 + ([long]$RunningTimeoutSeconds * 1000L)
    $observed = $null
    if ($YurunaRoot -and $RunningTimeoutSeconds -gt 0 -and $RunningTimeoutSeconds -le 7200) {
        try {
            if (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot) {
                $reply = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'Wait-VMRunning' `
                    -Argument @{ VMName = $Name; TimeoutSeconds = $RunningTimeoutSeconds; PollSeconds = 2
                        ReportState = $true; DeadlineExpiryTick = $deadline } -TimeoutSeconds ($RunningTimeoutSeconds + 5)
                if ($reply.Used) {
                    $value = $reply.Value
                    if ($value -isnot [Collections.IDictionary] -or $value['vmName'] -cne $Name -or
                        $value['running'] -isnot [bool] -or $value['lastState'] -cnotin 'running', 'stopped', 'absent', 'unknown' -or
                        ($value['running'] -and $value['lastState'] -cne 'running')) { throw 'Invalid native VM state confirmation.' }
                    $observed = $value
                }
            }
        } catch {
            # Older verified builds accept the original Boolean wait only.
            if ($_.Exception.Message -cnotin 'host-binary-command-failed: Wait-VMRunning (unknown-verb)', `
                'host-binary-command-failed: Wait-VMRunning (invalid-arguments)') {
                Write-Verbose "Could not confirm the native VM state. $($_.Exception.Message)"
                $observed = @{ running = $false; lastState = 'unknown' }
            }
        }
    }
    if ($null -eq $observed) {
        $running = $false
        while ([Environment]::TickCount64 -lt $deadline) {
            if ((Get-VMState -VMName $Name) -eq 'running') { $running = $true; break }
            $remaining = $deadline - [Environment]::TickCount64
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([math]::Min(2000L, $remaining)) }
        }
        $observed = @{ running = $running; lastState = if ($running) { 'running' } else { Get-VMState -VMName $Name } }
    }
    if ($observed['running']) {
        $result.started = $true; $result.reason = $null; $result.kind = 'none'; $result.controlHung = $false
        return $result
    }
    $result.reason = "start reported success but the VM is '$($observed['lastState'])' after ${RunningTimeoutSeconds}s"
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
        [string]$YurunaRoot,
        [ValidateRange(0, 3600)][int]$ReadyTimeoutSeconds = 480,
        [ValidateRange(0, 300)][int]$PollSeconds = 10
    )
    if ($YurunaRoot) {
        $caller = $PSCmdlet
        $approval = { param($edge) $caller.ShouldProcess($edge, 'Remove stale IP report and start VM') }.GetNewClosure()
        $startup = Invoke-AmisAdEdgeStartup -YurunaRoot $YurunaRoot -Names $Name -LogRoot $LogRoot `
            -ReadySeconds $ReadyTimeoutSeconds -PollSeconds $PollSeconds -Approve $approval
        if ($startup) { return $startup }
    }
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
            $started = Start-VMConfirmed -Name $edge -YurunaRoot $YurunaRoot -Confirm:$false
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
    $native = $null
    if ($YurunaRoot -and $Name.Count -le 2 -and -not @($Name | Where-Object { $_ -cnotin @('amisad-edge-a', 'amisad-edge-b') }).Count) {
        $entry = Join-Path $YurunaRoot 'test/modules/Test.HostBinaryChannel.psm1'
        if (Test-Path -LiteralPath $entry -PathType Leaf) {
            Import-Module $entry -DisableNameChecking
            $edges = @($Name | Where-Object { $state[$_].Started } | ForEach-Object {
                @{ name = $_; startedUnixTicks = $state[$_].Start.ToUniversalTime().Ticks - [DateTime]::UnixEpoch.Ticks }
            })
            if ($edges.Count) {
                $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogRoot)
                try {
                    $native = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-wait-edge-reports' `
                        -TimeoutSeconds ($ReadyTimeoutSeconds + 5) -Argument @{
                            LogRoot = $root; Edges = $edges; ReadyTimeoutSeconds = $ReadyTimeoutSeconds; PollSeconds = $PollSeconds
                        }
                } catch {
                    if ($_.Exception.Message -cne 'host-binary-command-failed: amisad-wait-edge-reports (unknown-verb)') {
                        Write-Verbose "Native edge report check failed: $($_.Exception.GetType().Name)"
                        $native = @{ Used = $true; Value = @{} }
                    }
                }
            }
        }
    }
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    foreach ($edge in $Name) {
        if (-not $state[$edge].Started) { continue }
        if ($native -and $native.Used) {
            $reading = $native.Value[$edge]
            if ($reading) {
                $address[$edge] = [string]$reading.address
                $reportedAt[$edge] = if ($reading.reportedAt -is [datetime]) { $reading.reportedAt.ToUniversalTime().ToString('o') } else { [string]$reading.reportedAt }
                $lines.Add("$edge reported $($address[$edge]) at $($reportedAt[$edge]).")
                $state[$edge].Ready = $true
                $state[$edge].Reason = $null
            } else { $state[$edge].Reason = 'started but never reported a fresh valid IP address' }
            continue
        }
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
        The VM whose startup or guest operation failed.
    .PARAMETER StartupFailure
        Structured driver evidence retained through the startup wrappers.
    .PARAMETER Address
        The address used by a failed SSH readiness probe.
    .PARAMETER ProbeFailure
        The result of a failed SSH readiness probe running only 'true'.
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
        [hashtable]$StartupFailure = @{},
        [string]$Address = '',
        [hashtable]$ProbeFailure = @{}
    )
    if ([string]::IsNullOrWhiteSpace($env:YURUNA_LOG_DIR)) { return $false }
    try {
        # Host actions run in a child process, so the parent's loaded builders
        # are not inherited even though its log directory is.
        foreach ($moduleName in 'Test.SequenceFailureState.psm1', 'Test.StateFile.psm1', 'Test.RunnerInnerLoop.psm1') {
            Import-Module (Join-Path $YurunaRoot "test/modules/$moduleName") -Global -DisableNameChecking -ErrorAction Stop
        }
        $plan = Get-AmisAdEvidencePlan -YurunaRoot $YurunaRoot -Kind 'failure-rows' -Context @{
            stage = $Stage; vmName = $VMName; errorMessage = $ErrorMessage; address = $Address;
            dependencyFailures = @($DependencyFailures); startupFailure = $StartupFailure; probeFailure = $ProbeFailure
        }
        if ($plan) {
            if ($plan['rows'] -isnot [array]) { throw 'The native failure evidence has invalid rows.' }
            $rows = $plan['rows']
        } else {
            $rows = @($DependencyFailures)
            if ($StartupFailure.Count) {
                $row = @{ area = 'vm-start'; vmName = $VMName; outcome = 'start-failed'; detail = $ErrorMessage }
                if ($Stage -like 'StorageAdmission-*') { $row.area = 'host-storage'; $row.outcome = 'admission-refused' }
                foreach ($field in 'hostMemory', 'hostStorage', 'errorCode', 'kind') {
                    if ($StartupFailure.Contains($field)) { $row[$field] = $StartupFailure[$field] }
                }
                $rows += $row
            }
            if ($ProbeFailure.Count) {
                $rows += @{ area = 'guest-ssh'; vmName = $VMName; address = $Address; outcome = 'probe-failed';
                    exitCode = $ProbeFailure.exitCode; output = $ProbeFailure.output }
            }
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
        [Parameter(Mandatory)][string]$LogDir,
        [string]$YurunaRoot
    )
    if (-not (Get-Command -Name Save-UtmControlSnapshot -ErrorAction SilentlyContinue)) { return $null }
    try {
        $witness = ''
        $plan = Get-AmisAdEvidencePlan -YurunaRoot $YurunaRoot -Kind 'control-witness' -Context @{
            missing = @($EdgeStartup['Missing']); state = $EdgeStartup['State']
        }
        if ($plan) {
            if ($plan['vmName'] -isnot [string]) { throw 'The native control evidence did not identify a witness.' }
            $witness = $plan['vmName']
        } else {
            foreach ($edge in @($EdgeStartup['Missing'])) {
                $edgeState = $EdgeStartup['State'][$edge]
                if ($edgeState -and $edgeState['Started'] -and -not $edgeState['Ready']) { $witness = [string]$edge; break }
            }
        }
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
        capture. Serial readers and passive console frames, where supported,
        keep the guest's remaining evidence when it no longer answers SSH.
        Each optional capture has an independent outcome; nothing here can
        fail the stage.
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
        [string[]]$AdditionalVm = @(),
        [string]$YurunaRoot
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $records = [System.Collections.Generic.List[object]]::new()
    $canDiscover = [bool](Get-Command -Name Get-VMIp -ErrorAction SilentlyContinue)
    $canCapture = [bool](Get-Command -Name Save-VMNetworkState -ErrorAction SilentlyContinue)
    $canSaveSerial = [bool](Get-Command -Name Save-VMSerialCapture -ErrorAction SilentlyContinue)
    $canSaveFrame = [bool](Get-Command -Name Get-VMScreenshot -ErrorAction SilentlyContinue)
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
        $serial = @{ outcome = 'unavailable' }
        if ($canSaveSerial) {
            try {
                $saved = [bool](Save-VMSerialCapture -VMName $vm -OutputDirectory $directory)
                $serial = @{ outcome = if ($saved) { 'saved' } else { 'not-saved' } }
            } catch {
                $serial = @{ outcome = 'error'; reason = $_.Exception.Message }
                Write-Verbose "Save-VMSerialCapture ${vm}: $($_.Exception.Message)"
            }
        }
        $screenshot = @{ outcome = 'unavailable' }
        if ($canSaveFrame) {
            try {
                New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
                $framePath = Join-Path $directory 'console.png'
                $capturedFrame = Get-VMScreenshot -VMName $vm -Source frame -OutFile $framePath
                $saved = -not [string]::IsNullOrWhiteSpace($capturedFrame) -and
                    (Test-Path -LiteralPath $capturedFrame -PathType Leaf) -and (Get-Item -LiteralPath $capturedFrame -ErrorAction Stop).Length -gt 0
                $screenshot = @{ outcome = if ($saved) { 'saved' } else { 'not-saved' } }
                if ($saved) { $screenshot.path = $capturedFrame }
            } catch {
                $screenshot = @{ outcome = 'error'; reason = $_.Exception.Message }
                Write-Verbose "Get-VMScreenshot ${vm}: $($_.Exception.Message)"
            }
        }
        $storage = @{ status = 'unknown'; reason = 'The host driver does not expose storage capacity evidence.' }
        if (Get-Command Test-VMStorageCapacity -ErrorAction SilentlyContinue) {
            try { $storage = Test-VMStorageCapacity -VMName $vm }
            catch { $storage = @{ status = 'unknown'; reason = $_.Exception.Message } }
        }
        $diagnostics[$vm] = @{ directory = $directory; networkStateSaved = $captured; hostStorage = $storage;
            serialCapture = $serial; screenshot = $screenshot }
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
        $evidence = [ordered]@{ capturedAtUtc = [DateTime]::UtcNow.ToString('o'); edges = $records.ToArray(); vmDiagnostics = $diagnostics }
        $json = $evidence | ConvertTo-Json -Depth 15
        if (-not (Write-AmisAdEdgeEvidenceFile -YurunaRoot $YurunaRoot -LogDir $LogDir -Json $json)) {
            New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
            Set-Content -LiteralPath $path -Value $json -Encoding utf8
        }
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
        See https://yuruna.link/42010605-00ab.
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
    $binding = $null
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($YurunaRoot)
    if (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot) {
        try { $binding = Invoke-AmisAdLegacyKeyOperation -YurunaRoot $root -Action 'inspect' } catch {
            if ($_.Exception.Message -cne 'host-binary-command-failed: amisad-legacy-key-files (unknown-verb)') { throw }
        }
    }
    foreach ($item in @(@{ Name = 'amisad-demo-key'; Action = 'remove-private' }, @{ Name = 'amisad-demo-key.pub'; Action = 'remove-public' })) {
        $path = Join-Path $handoff $item.Name
        $present = if ($binding) { $item.Name -cin $binding['present'] } else { Test-Path -LiteralPath $path }
        if (-not $present) { continue }
        if (-not $PSCmdlet.ShouldProcess($path, 'Delete the legacy served demo key')) { continue }
        if ($binding) {
            $result = Invoke-AmisAdLegacyKeyOperation -YurunaRoot $root -Action $item.Action
            if (-not $result -or $result['removed'] -isnot [bool]) { throw 'The native key cleanup did not confirm the file result.' }
            if (-not $result['removed']) { continue }
        } else { Remove-Item -LiteralPath $path -Force }
        $lines.Add("Removed the legacy demo key file '$path'. That directory is served to the whole LAN by the status service, so treat the key as exposed: a long-lived VM that still trusts it must be rebuilt, or have its authorized_keys line ending in 'amisad-demo' removed.")
    }
    $empty = if ($binding) {
        $after = Invoke-AmisAdLegacyKeyOperation -YurunaRoot $root -Action 'inspect'
        if (-not $after) { throw 'The native key cleanup did not confirm the hand-off directory.' }
        $after['empty']
    } else {
        (Test-Path -LiteralPath $handoff -PathType Container) -and -not (Get-ChildItem -LiteralPath $handoff -Force)
    }
    if ($empty -and $PSCmdlet.ShouldProcess($handoff, 'Remove the empty legacy hand-off directory')) {
        if ($binding) {
            $result = Invoke-AmisAdLegacyKeyOperation -YurunaRoot $root -Action 'remove-empty'
            if (-not $result -or $result['removed'] -isnot [bool]) { throw 'The native key cleanup did not confirm the directory result.' }
        } else { Remove-Item -LiteralPath $handoff -Force }
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
    .PARAMETER PreferNative
        Use the activated core guest runtime when it supports the login proof.
    .OUTPUTS
        [string] a single-line command for vm-core's login shell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$EdgeUser,
        [Parameter(Mandatory)][string]$EdgeAddress,
        [switch]$PreferNative
    )
    if ($EdgeUser -cnotmatch '^[a-z][a-z0-9-]*$') { throw "'$EdgeUser' is not an acceptable account name." }
    if ($EdgeAddress -cnotmatch '^[0-9A-Fa-f:.]+$') { throw "'$EdgeAddress' is not an IP address." }
    $legacy = 'ssh -i "$HOME/.ssh/amisad-demo-key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 {0}@{1} true' -f $EdgeUser, $EdgeAddress
    if (-not $PreferNative) { return $legacy }
    $native = 'p="$HOME/amisad.dev/poc/target/release/amisad-provision"; if [ -f "$p" ] && [ ! -L "$p" ] && [ -x "$p" ] && "$p" --help | grep -Fq ''|core-edge-login ''; then exec "$p" core-edge-login {0} {1}; fi; ' -f $EdgeUser, $EdgeAddress
    return $native + $legacy
}

function Get-AmisAdVerifiedPublicKey {
    param([string]$YurunaRoot, [string]$Text)
    $channel = Join-Path $YurunaRoot 'test/modules/Test.HostBinaryChannel.psm1'
    if (Test-Path -LiteralPath $channel -PathType Leaf) {
        Import-Module $channel -DisableNameChecking -ErrorAction Stop
        $probe = $null
        try {
            # An earlier host can refuse this verb before reading stdin.
            $probe = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-demo-public-key' `
                -Argument @{ Probe = $true } -TimeoutSeconds 3
        } catch {
            if ($_.Exception.Message -cnotin 'host-binary-command-failed: amisad-demo-public-key (unknown-verb)', `
                'host-binary-command-failed: amisad-demo-public-key (invalid-arguments)') { throw }
        }
        if ($probe -and $probe.Used) {
            if ($probe.Value -isnot [Collections.IDictionary] -or $probe.Value['protocol'] -ne 1) {
                throw 'The native public key protocol is unsupported.'
            }
            try {
                # Keep even an unexpected guest response off the process arguments.
                $reply = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-demo-public-key' -Argument @{} `
                    -InputBytes ([Text.Encoding]::UTF8.GetBytes($Text)) -TimeoutSeconds 5
                if ($reply.Used) {
                    if (-not $reply.Value['fingerprint'] -or -not $reply.Value['authorize']) { throw 'The native public key response was incomplete.' }
                    return $reply.Value
                }
            } catch {
                if ($_.Exception.Message -cne 'host-binary-command-failed: amisad-demo-public-key (amisad-public-key-invalid)') { throw }
                # Keep the guest-facing validation detail when both runtimes refuse it.
                $null = ConvertTo-AmisAdDemoPublicKey -Text $Text
                throw 'The core did not return a usable ssh-ed25519 public key.'
            }
        }
    }
    $publicKey = ConvertTo-AmisAdDemoPublicKey -Text $Text
    return @{ fingerprint = (Get-AmisAdKeyFingerprint -PublicKey $publicKey); authorize = (Get-AmisAdAuthorizeKeyCommand -PublicKey $publicKey) }
}

# --- REGION: Sync-AmisAdDemoKey
function Sync-AmisAdDemoKey {
    <#
    .SYNOPSIS
        Authorize the PUBLIC half of vm-core's demo key on the edge VMs, over
        the harness SSH channel, and prove the login works.
    .DESCRIPTION
        See https://yuruna.link/42010605-00aa.
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
        param([string]$Reason, [string]$Stage = 'Sync-AmisAdDemoKey', [string]$VMName = '', [hashtable]$StartupFailure = @{},
            [string]$Address = '', [hashtable]$ProbeFailure = @{})
        $label = if ($Stage -eq 'Start-AmisAdCore') { "$VMName startup failed" } else { 'Demo key hand-off failed' }
        $lines.Add("${label}: $Reason")
        $failureClass = if ($StartupFailure.Contains('controlHung') -and $StartupFailure.controlHung) { 'hypervisor_unresponsive' } else { 'provisioning_failure' }
        return [pscustomobject]@{ Ok = $false; Lines = [string[]]$lines; Fingerprint = ''; Reason = $Reason;
            Stage = $Stage; VMName = $VMName; StartupFailure = $StartupFailure; FailureClass = $failureClass;
            Address = $Address; ProbeFailure = $ProbeFailure }
    }
    if (-not $PSCmdlet.ShouldProcess("$CoreVm -> $($EdgeVm -join ', ')", 'Authorize the demo public key on the edges')) {
        return [pscustomobject]@{ Ok = $true; Lines = [string[]]@(); Fingerprint = ''; Reason = '' }
    }

    $useNativeLogin = -not $InvokeGuest
    if ($useNativeLogin) {
        if (-not (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $YurunaRoot 'test/modules/Test.Ssh.psm1') -Global -DisableNameChecking -Verbose:$false
        }
        $InvokeGuest = {
            param([string]$VMName, [string]$User, [string]$Command, [int]$TimeoutSeconds, [string]$Address)
            $connection = @{ VMName = $VMName; User = $User; Command = $Command; TimeoutSeconds = $TimeoutSeconds }
            if ($Address) { $connection.ResolvedAddress = $Address }
            # Older framework checkouts expose the same SSH function without
            # the enrolled worker selector.
            if ((Get-Command Invoke-GuestSsh).Parameters.ContainsKey('UseVerifiedTransport')) {
                $connection.UseVerifiedTransport = $true
                $connection.MaxCapturedChars = 1MB
            }
            Invoke-GuestSsh @connection
        }
    }

    $coreUser = "$CoreVm-admin"
    $reportedAddresses = $EdgeAddress
    $handoff = @{ Key = $null; Failure = $null; Reported = @{}; ProofAddress = @{} }
    $code = Invoke-AmisAdLabPlan -YurunaRoot $YurunaRoot -Request @{
        kind = 'public-key-handoff'; edges = $EdgeVm; readySeconds = $ReadySeconds; pollSeconds = $PollSeconds
    } -InvokeStep {
        param($step)
        if ($step.kind -cin @('probe-edge', 'authorize-edge', 'prove-login')) {
            $edge = [string]$step.name
            $edgeUser = "$edge-admin"
            $edgeTarget = if ($reportedAddresses.ContainsKey($edge)) { ([string]$reportedAddresses[$edge]).Trim() } else { '' }
            $where = if ($edgeTarget) { "at $edgeTarget" } else { 'at its discovered address' }
        }
        switch -CaseSensitive ($step.kind) {
            'start-core' {
                if ((Get-Command Get-VMState -ErrorAction SilentlyContinue) -and ((Get-VMState -VMName $CoreVm) -ne 'running')) {
                    $lines.Add("Starting $CoreVm to read its demo public key.")
                    $started = Start-VMConfirmed -Name $CoreVm -YurunaRoot $YurunaRoot -Confirm:$false
                    if (-not $started.started) {
                        $handoff.Failure = @{ Reason = "$CoreVm did not start: $($started.reason)"; Stage = 'Start-AmisAdCore'; VMName = $CoreVm; StartupFailure = $started }
                        return 1
                    }
                }
            }
            'probe-core' {
                $probe = & $InvokeGuest $CoreVm $coreUser 'true' 30
                if (-not $probe.success) {
                    $handoff.Failure = @{ Reason = "$CoreVm did not answer SSH within ${ReadySeconds}s ($($probe.output))"; VMName = $CoreVm; ProbeFailure = $probe }
                    return 1
                }
            }
            'read-public-key' {
                $read = & $InvokeGuest $CoreVm $coreUser 'cat "$HOME/.ssh/amisad-demo-key.pub"' 60
                if (-not $read.success) {
                    $handoff.Failure = @{ Reason = "could not read $CoreVm's demo public key (exit $($read.exitCode)); did the users step of the deploy run? $($read.output)"; VMName = $CoreVm }
                    return 1
                }
                try { $handoff.Key = Get-AmisAdVerifiedPublicKey -YurunaRoot $YurunaRoot -Text $read.output }
                catch {
                    $handoff.Failure = @{ Reason = "$CoreVm's demo public key is unusable: $($_.Exception.Message)"; VMName = $CoreVm }
                    return 1
                }
                $lines.Add("$CoreVm demo key: $($handoff.Key.fingerprint)")
            }
            'probe-edge' {
                if (-not $handoff.Reported.ContainsKey($edge)) {
                    if ($edgeTarget) { $lines.Add("Reaching $edge at $edgeTarget, the address it reported.") }
                    else { $lines.Add("No reported address for $edge; the host driver's discovery chooses one.") }
                    $handoff.Reported[$edge] = $true
                }
                $probe = & $InvokeGuest $edge $edgeUser 'true' 30 $edgeTarget
                if (-not $probe.success) {
                    $handoff.Failure = @{ Reason = "$edge did not answer SSH $where within ${ReadySeconds}s (exit $($probe.exitCode)): $($probe.output)";
                        VMName = $edge; Address = $edgeTarget; ProbeFailure = $probe }
                    return 1
                }
            }
            'authorize-edge' {
                $result = & $InvokeGuest $edge $edgeUser $handoff.Key.authorize 120 $edgeTarget
                if (-not $result.success) {
                    $handoff.Failure = @{ Reason = "could not authorize the demo key on $edge $where (exit $($result.exitCode)): $($result.output)";
                        VMName = $edge; Address = $edgeTarget }
                    return 1
                }
                $lines.Add("$edge now trusts $($handoff.Key.fingerprint) (any earlier amisad-demo entry replaced).")
            }
            'prove-login' {
                if (-not $handoff.ProofAddress.ContainsKey($edge)) {
                    $handoff.ProofAddress[$edge] = if ($reportedAddresses.ContainsKey($edge)) { [string]$reportedAddresses[$edge] }
                                                  elseif (Get-Command Get-VMIp -ErrorAction SilentlyContinue) { [string](Get-VMIp -VMName $edge) }
                                                  else { '' }
                }
                $address = $handoff.ProofAddress[$edge]
                if ([string]::IsNullOrWhiteSpace($address)) {
                    $lines.Add("Skipped the login check for ${edge}: no address is known for it yet.")
                    return 0
                }
                $command = Get-AmisAdEdgeLoginCommand -EdgeUser $edgeUser -EdgeAddress $address.Trim() -PreferNative:$useNativeLogin
                $result = & $InvokeGuest $CoreVm $coreUser $command 60
                if (-not $result.success) {
                    $handoff.Failure = @{ Reason = "$CoreVm cannot log in to $edge at $address with the demo key (exit $($result.exitCode)): $($result.output)";
                        VMName = $edge; Address = $address.Trim() }
                    return 1
                }
                $lines.Add("$CoreVm logs in to $edge at $address with the demo key.")
            }
            default { throw "Unexpected demo key workflow step '$($step.kind)'." }
        }
        return 0
    }
    if ($code -ne 0) {
        $failure = $handoff.Failure
        return (& $fail @failure)
    }
    return [pscustomobject]@{ Ok = $true; Lines = [string[]]$lines; Fingerprint = $handoff.Key.fingerprint; Reason = '' }
}

Export-ModuleMember -Function Invoke-AmisAdScript, Invoke-AmisAdStage, Invoke-AmisAdCleanup,
    Test-AmisAdStorageAdmission, Test-AmisAdFreshSignedBuild,
    Remove-InstallMedia, Set-EdgeMemory, Start-VMConfirmed, Start-AmisAdEdge, Get-AmisAdEdgeFailure, Write-AmisAdLabFailure, Save-AmisAdControlSnapshot,
    Save-AmisAdEdgeAddressEvidence, Remove-LegacyDemoKey,
    ConvertTo-AmisAdDemoPublicKey, Get-AmisAdKeyFingerprint, Get-AmisAdAuthorizeKeyCommand,
    Get-AmisAdEdgeLoginCommand, Sync-AmisAdDemoKey
