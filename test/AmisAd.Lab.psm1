<#PSScriptInfo
.VERSION 2026.10.11
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
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($edge in $Name) {
        $report = Join-Path $LogRoot "handoff/$edge.ip.txt"
        $state[$edge] = @{ IpFile = $report; Start = (Get-Date); Started = $false; Ready = $false; Reason = 'not attempted' }
        if (-not $PSCmdlet.ShouldProcess($edge, 'Remove stale IP report and start VM')) { continue }
        Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
        $state[$edge].Start = Get-Date
        foreach ($attempt in 1..3) {
            $started = Start-VMConfirmed -Name $edge -Confirm:$false
            $state[$edge].Reason = $started.reason
            if ($started.started) {
                $state[$edge].Started = $true
                break
            }
            $lines.Add("Start-VM $edge attempt ${attempt}/3 failed: $($started.reason)")
            if ($attempt -lt 3) { Start-Sleep -Seconds $PollSeconds }
        }
    }
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    foreach ($edge in $Name) {
        if (-not $state[$edge].Started) { continue }
        do {
            $report = $state[$edge].IpFile
            if ((Test-Path -LiteralPath $report -PathType Leaf) -and
                (Get-Item -LiteralPath $report).LastWriteTime -gt $state[$edge].Start) {
                $reported = Get-Content -LiteralPath $report -Raw -ErrorAction SilentlyContinue
                $parsed = $null
                if ($reported -and [Net.IPAddress]::TryParse($reported.Trim(), [ref]$parsed)) {
                    $address[$edge] = $reported.Trim()
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
    return @{ Ok = $missing.Count -eq 0; State = $state; Address = $address; Missing = $missing; Lines = [string[]]$lines }
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
        Optional name -> IP map for the login proof (the addresses the edges
        reported); an edge without an entry is looked up through the host driver.
    .PARAMETER InvokeGuest
        Test seam: a scriptblock taking (VMName, User, Command, TimeoutSeconds)
        and returning @{ success; exitCode; output }. The default wraps the
        framework's Invoke-GuestSsh.
    .PARAMETER ReadySeconds
        How long to wait for vm-core's SSH after starting it.
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
        param([string]$Reason)
        $lines.Add("Demo key hand-off failed: $Reason")
        return [pscustomobject]@{ Ok = $false; Lines = [string[]]$lines; Fingerprint = ''; Reason = $Reason }
    }
    if (-not $PSCmdlet.ShouldProcess("$CoreVm -> $($EdgeVm -join ', ')", 'Authorize the demo public key on the edges')) {
        return [pscustomobject]@{ Ok = $true; Lines = [string[]]@(); Fingerprint = ''; Reason = '' }
    }

    if (-not $InvokeGuest) {
        if (-not (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $YurunaRoot 'test/modules/Test.Ssh.psm1') -Global -DisableNameChecking -Verbose:$false
        }
        $InvokeGuest = {
            param([string]$VMName, [string]$User, [string]$Command, [int]$TimeoutSeconds)
            Invoke-GuestSsh -VMName $VMName -User $User -Command $Command -TimeoutSeconds $TimeoutSeconds
        }
    }

    # --- REGION: Wait for core SSH
    if ((Get-Command Get-VMState -ErrorAction SilentlyContinue) -and ((Get-VMState -VMName $CoreVm) -ne 'running')) {
        $lines.Add("Starting $CoreVm to read its demo public key.")
        $started = Start-VMConfirmed -Name $CoreVm -Confirm:$false
        if (-not $started.started) { return (& $fail "$CoreVm did not start: $($started.reason)") }
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
        $done = $null
        foreach ($attempt in 1..3) {
            $done = & $InvokeGuest $edge $edgeUser $authorize 120
            if ($done.success) { break }
            if ($attempt -lt 3) { Start-Sleep -Seconds $PollSeconds }
        }
        if (-not $done.success) { return (& $fail "could not authorize the demo key on $edge (exit $($done.exitCode)): $($done.output)") }
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
    Remove-InstallMedia, Set-EdgeMemory, Start-VMConfirmed, Start-AmisAdEdge, Remove-LegacyDemoKey,
    ConvertTo-AmisAdDemoPublicKey, Get-AmisAdKeyFingerprint, Get-AmisAdAuthorizeKeyCommand,
    Get-AmisAdEdgeLoginCommand, Sync-AmisAdDemoKey
