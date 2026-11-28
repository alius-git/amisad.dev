<#PSScriptInfo
.VERSION 2026.11.27
.GUID 42aeb1a4-aa77-4a41-a882-47104f3b9ac5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

#requires -version 7

function Read-AmisAdLabReply {
    param([Diagnostics.Process]$Process, [hashtable]$Request, [int]$ReplyTimeoutMs = 5000, [int]$MaxReplyChars = 16KB)
    if ($Request) {
        $write = $Process.StandardInput.WriteLineAsync((ConvertTo-Json -InputObject $Request -Compress))
        if (-not $write.Wait(5000)) { throw 'The native lab workflow did not accept the request.' }
    }
    $pending = $Process.StandardOutput.ReadLineAsync()
    if (-not $pending.Wait($ReplyTimeoutMs)) { throw 'The native lab workflow did not reply.' }
    $line = $pending.GetAwaiter().GetResult()
    if (-not $line -or $line.Length -gt $MaxReplyChars) { throw 'The native lab workflow sent an invalid reply.' }
    $jsonOption = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOption.DateKind = 'String' }
    return (ConvertFrom-Json -InputObject $line -AsHashtable -Depth 4 -ErrorAction Stop @jsonOption)
}

function Get-AmisAdLabCompatibilityPlan {
    param([hashtable]$Request)
    if ($Request.kind -ceq 'cleanup') {
        $index = 0
        foreach ($prefix in $Request.prefixes) { @{ kind = 'sweep'; prefix = $prefix; index = $index++ } }
        return
    }
    if ($Request.kind -ceq 'public-key-handoff') {
        @{ kind = 'start-core' }
        @{ kind = 'probe-core' }
        @{ kind = 'read-public-key' }
        foreach ($edge in $Request.edges) {
            @{ kind = 'probe-edge'; name = $edge }
            @{ kind = 'authorize-edge'; name = $edge }
        }
        foreach ($edge in $Request.edges) { @{ kind = 'prove-login'; name = $edge } }
        return
    }
    if ($Request.kind -ceq 'stash') {
        $source = 'discovery'
        $address = ''
        if (-not [string]::IsNullOrWhiteSpace($Request.pin)) {
            $source = 'pinned'
            $address = $Request.pin.Trim()
        } elseif (-not [string]::IsNullOrWhiteSpace($Request.environmentPin)) {
            $source = '$env:YURUNA_STASH_SERVICE_HOST'
            $address = $Request.environmentPin.Trim()
        }
        $delay = @(2, 5, 10, $null)
        $total = if ($address -or $Request.canDiscover) { $delay.Count } else { 1 }
        for ($index = 0; $index -lt $total; $index++) {
            @{ kind = 'probe-stash'; address = $address; source = $source; attempt = $index + 1; total = $total;
                delay = if ($index + 1 -lt $total) { $delay[$index] } }
        }
        return
    }
    @{ kind = 'admit-provisioning' }
    if (-not $Request.driver) { @{ kind = 'initialize-display' } }
    @{ kind = 'remove-legacy-key' }
    if ($Request.signedBuild) { @{ kind = 'announce-signed-build' } } else {
        @{ kind = 'resolve-stash' }
        @{ kind = 'provision'; name = 'amisad-build'; sequence = 'workload.guest.ubuntu.server.24.amisad-build.compile' }
    }
    foreach ($name in 'amisad-edge-a', 'amisad-edge-b') {
        @{ kind = 'provision'; name = $name; sequence = "workload.guest.ubuntu.server.24.$name.baseline" }
    }
    @{ kind = 'provision'; name = 'amisad-core'; sequence = 'workload.guest.ubuntu.server.24.amisad-core.deploy' }
    @{ kind = 'admit-start' }
    @{ kind = 'start-edges' }
    if (-not $Request.driver) { @{ kind = 'inventory' } }
    @{ kind = 'handoff' }
    foreach ($sequence in $Request.scenarios) {
        @{ kind = 'scenario'; name = ($sequence -split '\.')[-2..-1] -join '.'; sequence = $sequence }
    }
}

function Invoke-AmisAdLabCompatibilityPlan {
    param([hashtable]$Request, [scriptblock]$InvokeStep)
    foreach ($step in (Get-AmisAdLabCompatibilityPlan -Request $Request)) {
        if ($step.kind -ceq 'probe-stash') {
            $code = & $InvokeStep $step
            if ($code -isnot [int]) { throw 'A lab step did not report an exit code.' }
            if ($code -eq 0 -or $null -eq $step.delay) { return $code }
            Start-Sleep -Seconds $step.delay
            continue
        }
        $attempt = 0
        $probe = $step.kind -cin @('probe-core', 'probe-edge')
        $limit = switch -CaseSensitive ($step.kind) { 'authorize-edge' { 3 }; 'prove-login' { 6 }; default { 1 } }
        $started = [Diagnostics.Stopwatch]::StartNew()
        do {
            $code = & $InvokeStep $step
            if ($code -isnot [int]) { throw 'A lab step did not report an exit code.' }
            if ($code -eq 0) { break }
            $attempt++
            if (-not $probe -and $attempt -ge $limit) { return $code }
            Start-Sleep -Seconds $Request.pollSeconds
            if ($probe -and $started.Elapsed.TotalSeconds -ge $Request.readySeconds) { return $code }
        } while ($true)
    }
    return 0
}

function Get-AmisAdVerifiedHostBinary {
    [OutputType([string])]
    param([string]$YurunaRoot)
    if (-not $YurunaRoot) { return }
    $channel = Join-Path $YurunaRoot 'test/modules/Test.HostBinaryChannel.psm1'
    if (-not (Test-Path -LiteralPath $channel -PathType Leaf)) { return }
    Import-Module $channel -DisableNameChecking -ErrorAction Stop
    return (Get-VerifiedYurunaHostBinary -RepoRoot $YurunaRoot)
}

function Invoke-AmisAdLegacyKeyOperation {
    [OutputType([hashtable])]
    param([string]$YurunaRoot, [string]$Action)
    $reply = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-legacy-key-files' `
        -Argument @{ Root = $YurunaRoot; Action = $Action } -TimeoutSeconds 10
    if (-not $reply.Used) { return }
    $value = $reply.Value
    if ($value -isnot [Collections.IDictionary] -or ($Action -ceq 'inspect' -and
        ($value['present'] -isnot [array] -or $value['empty'] -isnot [bool]))) {
        throw 'The native legacy key operation returned invalid evidence.'
    }
    return $value
}

function Invoke-AmisAdStorageVerb {
    [OutputType([hashtable])]
    param([string]$YurunaRoot, [ValidateSet('plan', 'evidence')][string]$Operation,
        [hashtable]$Argument, [byte[]]$InputBytes, [int]$TimeoutSeconds)
    $verb = "amisad-storage-$Operation"
    $arguments = @{ RepoRoot = $YurunaRoot; Verb = $verb; Argument = $Argument; TimeoutSeconds = $TimeoutSeconds }
    if ($PSBoundParameters.ContainsKey('InputBytes')) { $arguments.InputBytes = $InputBytes }
    try {
        $reply = Invoke-VerifiedYurunaHostVerb @arguments
    } catch {
        if ($_.Exception.Message -cnotin "host-binary-command-failed: $verb (unknown-verb)",
            "host-binary-command-failed: $verb (invalid-arguments)") { throw }
        return
    }
    if (-not $reply.Used) { return }
    if ($reply.Value -isnot [Collections.IDictionary]) { throw 'The native storage admission reply is invalid.' }
    return $reply.Value
}

function Test-AmisAdNativeStorageAdmission {
    [OutputType([bool])]
    param([string]$YurunaRoot)
    if (-not (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot)) { return $false }
    $probe = Invoke-AmisAdStorageVerb -YurunaRoot $YurunaRoot -Operation plan -Argument @{ Probe = $true } -TimeoutSeconds 3
    if ($null -eq $probe) { return $false }
    if ($probe['protocol'] -ne 1) {
        throw 'The native storage admission protocol is unsupported.'
    }
    return $true
}

function Write-AmisAdEdgeEvidenceFile {
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes diagnostic evidence for a stage that has already failed.')]
    param([string]$YurunaRoot, [string]$LogDir, [string]$Json)
    if (-not (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot)) { return $false }
    try {
        $probe = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-edge-address-evidence' `
            -Argument @{ Probe = $true } -TimeoutSeconds 3
    } catch {
        if ($_.Exception.Message -ceq 'host-binary-command-failed: amisad-edge-address-evidence (unknown-verb)') { return $false }
        throw
    }
    if (-not $probe.Used) { return $false }
    if ($probe.Value -isnot [Collections.IDictionary] -or $probe.Value['protocol'] -ne 1) {
        throw 'The native edge evidence file protocol is unsupported.'
    }
    $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDir)
    $reply = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-edge-address-evidence' `
        -Argument @{ LogDirectory = $directory } -InputBytes ([Text.Encoding]::UTF8.GetBytes($Json + [Environment]::NewLine)) -TimeoutSeconds 10
    if (-not $reply.Used -or $reply.Value -isnot [Collections.IDictionary] -or $reply.Value['written'] -ne $true) {
        throw 'The native host did not confirm the edge evidence write.'
    }
    return $true
}

function Get-AmisAdEvidencePlan {
    [OutputType([hashtable])]
    param([string]$YurunaRoot, [string]$Kind, [hashtable]$Context)
    if (-not $YurunaRoot -or -not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind') -or
        -not (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot)) { return }
    try {
        $probe = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-lab-evidence-plan' `
            -Argument @{ Probe = $true } -TimeoutSeconds 3
    } catch {
        if ($_.Exception.Message -ceq 'host-binary-command-failed: amisad-lab-evidence-plan (unknown-verb)') { return }
        throw
    }
    if (-not $probe.Used) { return }
    if ($probe.Value -isnot [Collections.IDictionary] -or $probe.Value['protocol'] -ne 1) {
        throw 'The native lab evidence protocol is unsupported.'
    }
    $json = $Context | ConvertTo-Json -Depth 15 -Compress
    $reply = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-lab-evidence-plan' `
        -Argument @{ Kind = $Kind } -InputBytes ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSeconds 10 -MaxCapturedChars 16777216
    if (-not $reply.Used -or $reply.Value -isnot [Collections.IDictionary] -or $reply.Value['planBase64'] -isnot [string]) {
        throw 'The native host did not return a lab evidence plan.'
    }
    # Date-shaped diagnostic strings are evidence, and must not be coerced.
    $bytes = [Convert]::FromBase64String($reply.Value['planBase64'])
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 15 -DateKind String)
}

function Invoke-AmisAdNativeStage {
    [OutputType([int])]
    param([string]$YurunaRoot, [string]$ScriptPath, [string[]]$ScriptArguments, [string]$OutputPath, [string]$ErrorPath)
    $binary = Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot
    if (-not $binary) { return }
    $info = [Diagnostics.ProcessStartInfo]::new($binary)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $err = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ErrorPath)
    foreach ($argument in (@('amisad-lab-stage', (Get-Process -Id $PID).Path, (Get-Location).ProviderPath, $ScriptPath, $out, $err) + $ScriptArguments)) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $reply = $process.StandardOutput.ReadToEnd() | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $process.WaitForExit()
        # Earlier binaries refuse this argument shape before opening the logs.
        if ($process.ExitCode -eq 2 -and $reply['ok'] -eq $false -and $reply['error']['code'] -cin 'unknown-verb', 'invalid-arguments') {
            return
        }
        if ($process.ExitCode -ne 0 -or $reply['ok'] -ne $true -or $reply['result'] -isnot [int] -and $reply['result'] -isnot [long]) {
            throw "Native AmisAd lab stage failed. $($reply['error']['message'])"
        }
        return [int]$reply['result']
    } finally { $process.Dispose() }
}

function Invoke-AmisAdConsoleStage {
    [OutputType([int])]
    param([string]$YurunaRoot, [string]$ScriptPath, [string[]]$ScriptArguments)
    $binary = Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot
    $native = $null
    if ($binary) {
        try {
            $native = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb 'amisad-lab-terminal-stage-probe' `
                -Argument @{} -TimeoutSeconds 3 -MaxCapturedChars 4096
        } catch {
            if ($_.Exception.Message -cne 'host-binary-command-failed: amisad-lab-terminal-stage-probe (unknown-verb)') { throw }
        }
    }
    if (-not $native -or -not $native.Used) {
        & pwsh -NoProfile -File $ScriptPath @ScriptArguments | Out-Host
        return $LASTEXITCODE
    }
    if ($native.Value -isnot [Collections.IDictionary] -or $native.Value['protocol'] -ne 1) {
        throw 'The native AmisAd terminal stage protocol is unsupported.'
    }
    # The stage owns the terminal streams. The probe is separate so a child
    # exit code cannot be confused with an older host declining the verb.
    $pwsh = (Get-Command -Name pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info = [Diagnostics.ProcessStartInfo]::new($binary)
    $info.UseShellExecute = $false
    foreach ($argument in (@('amisad-lab-terminal-stage', $pwsh, (Get-Location).ProviderPath, $ScriptPath) + $ScriptArguments)) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $process.WaitForExit()
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Open-AmisAdLabProcess {
    [OutputType([Diagnostics.Process])]
    param([string]$Binary, [string]$Verb)
    $info = [Diagnostics.ProcessStartInfo]::new($Binary)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.ArgumentList.Add($Verb)
    return [Diagnostics.Process]::Start($info)
}

function Close-AmisAdLabProcess {
    param([Diagnostics.Process]$Process)
    try { $Process.StandardInput.Close() } catch { Write-Verbose "Could not close the lab workflow input: $($_.Exception.GetType().Name)" }
    try {
        if (-not $Process.WaitForExit(1000)) { $Process.Kill(); $null = $Process.WaitForExit(1000) }
    } finally { $Process.Dispose() }
}

function Invoke-AmisAdEdgeStartup {
    [OutputType([hashtable])]
    param([string]$YurunaRoot, [string[]]$Names, [string]$LogRoot, [int]$ReadySeconds, [int]$PollSeconds,
        [scriptblock]$Approve)
    if (-not $YurunaRoot -or $Names.Count -gt 2 -or
        @($Names | Where-Object { $_ -cnotin 'amisad-edge-a', 'amisad-edge-b' }).Count -or
        @($Names | Select-Object -Unique).Count -ne $Names.Count) { return }
    $binary = Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot
    if (-not $binary) { return }
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogRoot)
    $process = Open-AmisAdLabProcess -Binary $binary -Verb 'amisad-edge-start'
    $evidence = @{}
    try {
        $process.StandardInput.AutoFlush = $true
        $reply = Read-AmisAdLabReply -Process $process
        if ($reply['ok'] -eq $false -and $reply['error']['code'] -in @('unknown-verb', 'invalid-arguments')) { return }
        if ($reply['state'] -cne 'ready' -or $reply['version'] -ne 1) { throw 'The native edge startup protocol is unsupported.' }
        $request = @{ names = $Names; logRoot = $root; readySeconds = $ReadySeconds; pollSeconds = $PollSeconds }
        $reply = Read-AmisAdLabReply -Process $process -Request $request
        while ($reply['state'] -cin 'approve', 'start', 'pause') {
            $edge = [string]$reply['name']
            switch -CaseSensitive ($reply['state']) {
                'approve' {
                    if ($edge -cnotin $Names) { throw 'Unexpected edge approval request.' }
                    $ack = @{ kind = 'approval'; approved = [bool](& $Approve $edge) }
                }
                'start' {
                    if ($edge -cnotin $Names) { throw 'Unexpected edge start request.' }
                    $started = Start-VMConfirmed -Name $edge -YurunaRoot $YurunaRoot -Confirm:$false
                    if (-not $evidence.ContainsKey($edge)) { $evidence[$edge] = @{} }
                    foreach ($field in 'hostMemory', 'hostStorage', 'errorCode') {
                        if ($started.Contains($field)) { $evidence[$edge][$field] = $started[$field] }
                    }
                    $ack = @{ kind = 'started'; started = [bool]$started['started']; reason = $started['reason'];
                        failureKind = $started['kind']; errorCode = $started['errorCode']; controlHung = [bool]$started['controlHung'] }
                }
                'pause' {
                    Start-Sleep -Seconds $reply['seconds']
                    $ack = @{ kind = 'continue' }
                }
            }
            $reply = Read-AmisAdLabReply -Process $process -Request $ack
        }
        if ($reply['state'] -cne 'converge') { throw 'The native edge startup did not reach convergence.' }
        $reply = Read-AmisAdLabReply -Process $process -ReplyTimeoutMs (($ReadySeconds + 5) * 1000) -MaxReplyChars 512KB
        if ($reply['state'] -cne 'done') { throw 'The native edge startup did not report its outcome.' }
        $state = @{}
        $reportedAt = @{}
        foreach ($edge in $Names) {
            $record = $reply['edges'][$edge]
            $state[$edge] = @{
                IpFile = Join-Path $LogRoot "handoff/$edge.ip.txt"
                Start = [DateTime]::UnixEpoch.AddTicks([long]$record['startUnixTicks']).ToLocalTime()
                Started = [bool]$record['started']; Ready = [bool]$record['ready']
                Reason = $record['reason']; Kind = $record['kind']; Attempts = [int]$record['attempts']
            }
            if ($evidence.ContainsKey($edge)) {
                foreach ($field in $evidence[$edge].Keys) { $state[$edge][$field] = $evidence[$edge][$field] }
            }
            $time = $reply['reportedAt'][$edge]
            if ($time) { $reportedAt[$edge] = if ($time -is [datetime]) { $time.ToUniversalTime().ToString('o') } else { [string]$time } }
        }
        return @{
            Ok = $reply['ok']; State = $state; Address = [hashtable]$reply['address']; ReportedAt = $reportedAt
            Missing = [string[]]$reply['missing']; Lines = [string[]]$reply['lines']
            ControlHung = $reply['controlHung']; HungEdge = $reply['hungEdge']
        }
    } finally {
        Close-AmisAdLabProcess -Process $process
    }
}

function Invoke-AmisAdLabPlan {
    <#
    .SYNOPSIS
        Execute each native lab workflow instruction once through the host adapter.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$YurunaRoot, [Parameter(Mandatory)][hashtable]$Request, [Parameter(Mandatory)][scriptblock]$InvokeStep)
    $binary = Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot
    if (-not $binary) {
        return (Invoke-AmisAdLabCompatibilityPlan -Request $Request -InvokeStep $InvokeStep)
    }
    $process = Open-AmisAdLabProcess -Binary $binary -Verb 'amisad-lab'
    try {
        $process.StandardInput.AutoFlush = $true
        $reply = Read-AmisAdLabReply -Process $process
        if ($reply['ok'] -eq $false -and $reply['error']['code'] -in @('unknown-verb', 'invalid-arguments')) {
            return (Invoke-AmisAdLabCompatibilityPlan -Request $Request -InvokeStep $InvokeStep)
        }
        if ($reply['state'] -cne 'ready' -or $reply['version'] -ne 1) { throw 'The native lab workflow protocol is unsupported.' }
        $reply = Read-AmisAdLabReply -Process $process -Request $Request
        $code = 0
        $canRepeat = $Request.kind -cin @('public-key-handoff', 'stash')
        while ($reply['state'] -cin 'step', 'pause') {
            if ($reply['state'] -ceq 'pause') {
                if (-not $canRepeat) { throw 'The lab workflow cannot repeat this operation.' }
                Start-Sleep -Seconds $reply['seconds']
                $ack = 0
            } else {
                if ($code -ne 0 -and -not $canRepeat) { throw 'The lab workflow resumed after a failed effect.' }
                $code = & $InvokeStep $reply['step']
                if ($code -isnot [int]) { throw 'A lab step did not report an exit code.' }
                $ack = $code
            }
            $reply = Read-AmisAdLabReply -Process $process -Request @{ kind = 'result'; exitCode = $ack }
        }
        if ($reply['state'] -cne 'done' -or $reply['exitCode'] -ne $code) { throw 'The native lab workflow did not acknowledge the last step.' }
        return $code
    } finally {
        Close-AmisAdLabProcess -Process $process
    }
}

function Invoke-AmisAdWarmup {
    <#
    .SYNOPSIS
        Apply the shared lab workflow to the selected framework and host.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$YurunaRoot, [hashtable]$StageContext, [string]$StashPin, [switch]$NoConfigGate,
        [switch]$Driver, [string[]]$Scenarios = @())
    $hostType = $StageContext.HostType
    $logDir = $StageContext.LogDir
    $skipConfigGate = [bool]$NoConfigGate
    $useSignedBuild = Test-AmisAdFreshSignedBuild -YurunaRoot $YurunaRoot -HostType $hostType -StashPin $StashPin
    $edges = 'amisad-edge-a', 'amisad-edge-b'
    $workspace = @{ EdgeStartup = $null }
    Invoke-AmisAdLabPlan -YurunaRoot $YurunaRoot -Request @{
        kind = 'warmup'; signedBuild = $useSignedBuild; driver = [bool]$Driver; scenarios = $Scenarios
    } -InvokeStep {
        param($step)
        switch -CaseSensitive ($step.kind) {
            { $_ -cin 'admit-provisioning', 'admit-start' } {
                $provisioning = $step.kind -ceq 'admit-provisioning'
                $phase = if ($provisioning) { 'BeforeProvisioning' } else { 'BeforeStart' }
                $storage = Test-AmisAdStorageAdmission -YurunaRoot $YurunaRoot -HostType $hostType -LogDir $logDir -Stage $phase `
                    -IncludeDiskGrowth:$provisioning -UseSignedBuild:($provisioning -and $useSignedBuild)
                if (-not $storage.allowed) { Write-Error "Topology storage admission refused: $($storage.reason)"; return 1 }
            }
            'initialize-display' {
                Import-Module (Join-Path $YurunaRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
                if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) { $null = Initialize-HostDisplay -HostType $hostType }
            }
            'remove-legacy-key' {
                foreach ($line in (Remove-LegacyDemoKey -YurunaRoot $YurunaRoot -Confirm:$false)) { Write-Warning $line }
            }
            'announce-signed-build' { Write-Information 'The fresh AmisAd core will use the signed build-service runtime.' }
            'resolve-stash' {
                $stash = Resolve-StashService -YurunaRoot $YurunaRoot -Pin $StashPin
                foreach ($line in $stash.Lines) { Write-Information $line }
                if (-not $stash.Address) {
                    $null = Write-AmisAdStashFailure -YurunaRoot $YurunaRoot -Result $stash -HostType $hostType
                    Write-Error ('No stash service answered /healthz. Start one on this host (Start-StashServiceVM.ps1), join a pool that runs one, or pin it with -StashServiceHost or YURUNA_STASH_SERVICE_HOST.')
                    return 1
                }
            }
            'provision' {
                $name = [string]$step.name
                if ((Invoke-AmisAdStage @StageContext -Name $name -Sequence $step.sequence -NoConfigGate:$skipConfigGate -YurunaRoot $YurunaRoot) -ne 0) {
                    $message = switch ($name) {
                        'amisad-build' { 'Build stage failed; no binaries in the stash - stopping.' }
                        'amisad-core' { 'amisad-core deploy failed - stopping.' }
                        default { "$name provisioning failed - stopping." }
                    }
                    Write-Error $message
                    return 1
                }
                if ($name -ceq 'amisad-build') {
                    try { $null = Stop-VMForce -VMName $name } catch { Write-Verbose "Stop-VMForce ${name}: $($_.Exception.Message)" }
                }
                if ($name -cin $edges) { $null = Set-EdgeMemory -Name $name -HostType $hostType -YurunaRoot $YurunaRoot -Confirm:$false }
                $null = Remove-InstallMedia -Name $name -SnapshotId $name -HostType $hostType -YurunaRoot $YurunaRoot -Confirm:$false
                if ($name -ceq 'amisad-build') { Write-Information 'amisad-build stopped (kept on disk).' }
            }
            'start-edges' {
                Write-Information 'Starting amisad-edge-a + amisad-edge-b.'
                $logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { Join-Path $YurunaRoot 'test/status/log' }
                $startup = Start-AmisAdEdge -Name $edges -LogRoot $logRoot -YurunaRoot $YurunaRoot -Confirm:$false
                $workspace.EdgeStartup = $startup
                foreach ($line in $startup.Lines) { Write-Information $line }
                if (-not $startup.Ok) {
                    $failure = Get-AmisAdEdgeFailure -EdgeStartup $startup
                    $null = Write-AmisAdLabFailure -YurunaRoot $YurunaRoot -HostType $hostType -Stage 'Start-AmisAdEdge' `
                        -FailureClass $failure.FailureClass -ErrorMessage $failure.ErrorMessage -DependencyFailures $failure.DependencyFailures
                    $evidence = Save-AmisAdEdgeAddressEvidence -EdgeVm $edges -AdditionalVm 'amisad-core' -LogDir $logDir -YurunaRoot $YurunaRoot
                    foreach ($line in $evidence.Lines) { Write-Information $line }
                    if (-not $Driver) {
                        $snapshot = Save-AmisAdControlSnapshot -EdgeStartup $startup -LogDir $logDir -YurunaRoot $YurunaRoot
                        if ($snapshot -and $snapshot.Written) { Write-Information "Hypervisor control snapshot: $($snapshot.Path)" }
                    }
                    Write-Error "$($failure.ErrorMessage). Stopping before the scenarios; VMs are left as-is for debugging."
                    return 1
                }
            }
            'inventory' {
                Write-Information '--- VM inventory ---'
                foreach ($vm in 'amisad-core', 'amisad-edge-a', 'amisad-edge-b', 'amisad-build') {
                    Write-Information ('  {0,-16} {1}' -f $vm, (Get-VMState -VMName $vm))
                }
            }
            'handoff' {
                $addresses = $workspace.EdgeStartup.Address
                $handoff = Sync-AmisAdDemoKey -YurunaRoot $YurunaRoot -CoreVm 'amisad-core' -EdgeVm $edges -EdgeAddress $addresses -Confirm:$false
                foreach ($line in $handoff.Lines) { Write-Information $line }
                if (-not $handoff.Ok) {
                    $evidence = Save-AmisAdEdgeAddressEvidence -EdgeVm $edges -AdditionalVm 'amisad-core' -EdgeAddress $addresses `
                        -ReportedAt $workspace.EdgeStartup.ReportedAt -LogDir $logDir -YurunaRoot $YurunaRoot
                    foreach ($line in $evidence.Lines) { Write-Information $line }
                    $null = Write-AmisAdLabFailure -YurunaRoot $YurunaRoot -HostType $hostType -Stage $handoff.Stage -FailureClass $handoff.FailureClass `
                        -ErrorMessage $handoff.Reason -VMName $handoff.VMName -StartupFailure $handoff.StartupFailure `
                        -Address $handoff.Address -ProbeFailure $handoff.ProbeFailure
                    Write-Error "$($handoff.Stage): $($handoff.Reason). Stopping before the scenarios."
                    return 1
                }
            }
            'scenario' {
                if ((Invoke-AmisAdStage @StageContext -Name $step.name -Sequence $step.sequence -NoConfigGate:$skipConfigGate -YurunaRoot $YurunaRoot) -ne 0) {
                    Write-Error "Scenario $($step.sequence) FAILED - stopping the run; VMs are left as-is for debugging."
                    return 1
                }
            }
            default { throw "Unexpected lab workflow step '$($step.kind)'." }
        }
        return 0
    }
}
