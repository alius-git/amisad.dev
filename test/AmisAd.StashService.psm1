<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42c943f7-5e9b-4ffc-b5f2-bdac82550e11
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab stash discovery
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
    Stash-service pre-flight shared by the AmisAd entry points that build the
    topology (test/Initialize-Lab.ps1, poc/build/run-tests.ps1).
.DESCRIPTION
    See https://yuruna.link/42010605-0006.
#>

Set-StrictMode -Version Latest

# --- REGION: Resolve-StashService
function Resolve-StashService {
    <#
    .SYNOPSIS
        Find the stash service, verify it answers, and publish the address for
        the rest of the cycle to resolve without re-probing.
    .DESCRIPTION
        See https://yuruna.link/42010605-0006.
    .PARAMETER YurunaRoot
        Yuruna framework checkout supplying the stash extension and the
        extension-host lookup.
    .PARAMETER Pin
        Address to use INSTEAD of discovery, or '' to discover.
    .OUTPUTS
        [hashtable] @{ Address [string] ('' when nothing answered);
                       Lines [string[]] (the caller prints them verbatim);
                       Failures [hashtable[]] (service/discovery evidence) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [AllowEmptyString()][string]$Pin = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[hashtable]]::new()
    $result = @{ Address = ''; Lines = @(); Failures = $failures }

    $module = Join-Path $YurunaRoot 'test/extension/stash-service/default.psm1'
    Import-Module $module -Force -Global -DisableNameChecking -ErrorAction Stop
    if (-not (Get-Command Test-StashServiceHost -ErrorAction SilentlyContinue) -or
        -not (Get-Command Publish-StashServiceHost -ErrorAction SilentlyContinue)) {
        $lines.Add("The stash-service extension at $module has no reachability/publish verbs; the pre-flight cannot verify a stash.")
        Write-Warning $lines[-1]
        $failures.Add(@{ area = 'stash-service'; address = ''; endpoint = ''; outcome = 'extension-unavailable'
            detail = 'The stash-service extension has no reachability/publish verbs'; attempt = 0 })
        $result.Lines = $lines.ToArray()
        $result.Failures = $failures.ToArray()
        return $result
    }
    # The framework's extension-host lookup: with no address of our own, this is
    # how an unpinned pass finds a stash at all.
    $extensionModule = Join-Path $YurunaRoot 'test/modules/Test.Extension.psm1'
    if (Test-Path -LiteralPath $extensionModule) {
        Import-Module $extensionModule -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    }

    $lines.Add('== Resolving the stash service ==')

    # See https://yuruna.link/42010605-0006
    $retryDelaySeconds = @(2, 5, 10)
    $attemptCount = $retryDelaySeconds.Count + 1
    $canDiscover = [bool](Get-Command Get-ExtensionHostAddress -ErrorAction SilentlyContinue)
    $hasPin = (-not [string]::IsNullOrWhiteSpace($Pin)) -or
              (-not [string]::IsNullOrWhiteSpace($env:YURUNA_STASH_SERVICE_HOST))
    if (-not $hasPin -and -not $canDiscover) {
        # Nothing to retry: a missing framework verb is not a transient state,
        # and sleeping through the window would only delay the same answer.
        Write-Warning "The framework at $YurunaRoot has no Get-ExtensionHostAddress, so nothing can discover a stash service. Upgrade the framework checkout, or pin an address with `$env:YURUNA_STASH_SERVICE_HOST."
        $attemptCount = 1
    }

    for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
        $candidates = [System.Collections.Generic.List[hashtable]]::new()
        $discoveryError = ''
        if (-not [string]::IsNullOrWhiteSpace($Pin)) {
            $candidates.Add(@{ Address = $Pin.Trim(); Source = 'pinned' })
        } elseif (-not [string]::IsNullOrWhiteSpace($env:YURUNA_STASH_SERVICE_HOST)) {
            $candidates.Add(@{ Address = $env:YURUNA_STASH_SERVICE_HOST.Trim(); Source = '$env:YURUNA_STASH_SERVICE_HOST' })
        } elseif ($canDiscover) {
            # @(): a single discovered address unrolls to a scalar string, and
            # iterating THAT walks its characters.
            $discovered = @()
            try { $discovered = @(Get-ExtensionHostAddress -HostType 'stash-service') } catch {
                $discoveryError = $_.Exception.Message
                Write-Verbose "Get-ExtensionHostAddress stash-service: $discoveryError"
            }
            foreach ($address in $discovered) {
                $candidates.Add(@{ Address = $address; Source = 'discovered (this host, or the pool)' })
            }
        }

        foreach ($candidate in $candidates) {
            if (Test-StashServiceHost -Address $candidate.Address) {
                $lines.Add(("  [PASS] {0} ({1}) answered /healthz" -f $candidate.Address, $candidate.Source))
                $null = Publish-StashServiceHost -Address $candidate.Address
                $lines.Add("Stash service: $($candidate.Address) -- published for this cycle.")
                $result.Address = $candidate.Address
                $result.Lines = $lines.ToArray()
                $result.Failures = $failures.ToArray()
                return $result
            }
            $lines.Add(("  [FAIL] {0} ({1}) did not answer /healthz" -f $candidate.Address, $candidate.Source))
            $authority = [string]$candidate.Address
            if ($authority.Contains(':') -and -not $authority.StartsWith('[') -and ($authority -split ':').Count -gt 2) {
                $authority = "[$authority]"
            }
            $failures.Add(@{ area = 'stash-service'; address = [string]$candidate.Address
                endpoint = "http://$authority/healthz"; source = [string]$candidate.Source
                outcome = 'unreachable'; detail = 'No HTTP 200 from /healthz'; attempt = $attempt })
        }
        if ($candidates.Count -eq 0) {
            # "found none" covers two very different situations and the operator
            # acts differently on each: a pool that answered and knows no stash
            # is a registration problem, one that could not be reached at all is
            # this host's link. Name whichever it was.
            $why = ''
            $poolOutcome = @{ Outcome = 'discovery-unavailable'; Detail = 'No pool lookup outcome available'; Uri = '' }
            if ($discoveryError) {
                $poolOutcome = @{ Outcome = 'discovery-error'; Detail = $discoveryError; Uri = '' }
                $why = ' [discovery-error: ' + $discoveryError + ']'
            } elseif (Get-Command Get-ExtensionHostLastOutcome -ErrorAction SilentlyContinue) {
                $lookupOutcome = Get-ExtensionHostLastOutcome
                if ($lookupOutcome.Area -eq 'stash-service') { $poolOutcome = $lookupOutcome }
                $why = ' [pool: ' + $poolOutcome.Outcome
                if ($poolOutcome.Detail) { $why += ' -- ' + $poolOutcome.Detail }
                $why += ']'
            } elseif (Get-Command Get-PoolExtensionHostLastOutcome -ErrorAction SilentlyContinue) {
                $poolOutcome = Get-PoolExtensionHostLastOutcome
                $why = ' [pool: ' + $poolOutcome.Outcome
                if ($poolOutcome.Detail) { $why += ' -- ' + $poolOutcome.Detail }
                $why += ']'
            }
            $lines.Add('  [FAIL] no candidate at all: nothing pinned, and discovery (this host, the pool) found none.' + $why)
            $failures.Add(@{ area = 'stash-service'; address = ''; endpoint = [string]$poolOutcome.Uri
                source = 'discovery'; outcome = [string]$poolOutcome.Outcome; detail = [string]$poolOutcome.Detail
                attempt = $attempt })
        }

        if ($attempt -lt $attemptCount) {
            $delay = $retryDelaySeconds[$attempt - 1]
            $lines.Add(("  .. nothing answered; re-asking in {0}s (attempt {1} of {2})." -f $delay, ($attempt + 1), $attemptCount))
            Start-Sleep -Seconds $delay
        }
    }
    # Nothing answered: clear any address a previous cycle left behind so the
    # sequences cannot resolve one this cycle never confirmed.
    $null = Publish-StashServiceHost -Address ''
    $result.Lines = $lines.ToArray()
    $result.Failures = $failures.ToArray()
    return $result
}

# --- REGION: Write-AmisAdStashFailure
function Write-AmisAdStashFailure {
    <#
    .SYNOPSIS
        Preserve a failed stash pre-flight as a classified cycle dependency failure.
    .PARAMETER YurunaRoot
        Framework checkout providing the shared failure record writer.
    .PARAMETER Result
        Failed Resolve-StashService result, including discovery and health evidence.
    .PARAMETER HostType
        Detected host type for the failure record.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes diagnostic evidence for a pre-flight that has already failed; no lab resource is modified.')]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [Parameter(Mandatory)][hashtable]$Result,
        [Parameter(Mandatory)][string]$HostType
    )
    if ($Result.Address -or [string]::IsNullOrWhiteSpace($env:YURUNA_LOG_DIR)) { return }
    try {
        # Host actions run in a child process, so the parent's loaded builders
        # are not inherited even though its log directory is.
        foreach ($moduleName in 'Test.SequenceFailureState.psm1', 'Test.StateFile.psm1', 'Test.RunnerInnerLoop.psm1') {
            Import-Module (Join-Path $YurunaRoot "test/modules/$moduleName") -Global -DisableNameChecking -ErrorAction Stop
        }
        $message = if ($Result.Failures.Count -gt 0) {
            $last = $Result.Failures[-1]
            "$($last.area): $($last.outcome) -- $($last.detail)"
        } else { $Result.Lines -join [Environment]::NewLine }
        Write-CycleInfraFailure -Stage 'Resolve-StashService' -FailureClass 'lab_dependency_down' -Severity 'hard' `
            -GuestKey '(orchestration)' -ErrorMessage $message -HostType $HostType -DependencyFailures @($Result.Failures)
    } catch {
        Write-Verbose "Write-AmisAdStashFailure: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Resolve-StashService, Write-AmisAdStashFailure
