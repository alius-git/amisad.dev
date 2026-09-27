<#PSScriptInfo
.VERSION 2026.09.27
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

Export-ModuleMember -Function Invoke-AmisAdScript, Invoke-AmisAdStage, Invoke-AmisAdCleanup,
    Remove-InstallMedia, Set-EdgeMemory, Start-VMConfirmed
