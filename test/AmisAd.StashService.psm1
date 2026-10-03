<#PSScriptInfo
.VERSION 2026.07.27
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
                       Lines [string[]] (the caller prints them verbatim) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$YurunaRoot,
        [AllowEmptyString()][string]$Pin = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $result = @{ Address = ''; Lines = @() }

    $module = Join-Path $YurunaRoot 'test/extension/stash-service/default.psm1'
    Import-Module $module -Force -Global -DisableNameChecking -ErrorAction Stop
    if (-not (Get-Command Test-StashServiceHost -ErrorAction SilentlyContinue) -or
        -not (Get-Command Publish-StashServiceHost -ErrorAction SilentlyContinue)) {
        Write-Warning "The stash-service extension at $module has no reachability/publish verbs; the pre-flight cannot verify a stash."
        $result.Lines = $lines.ToArray()
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
        if (-not [string]::IsNullOrWhiteSpace($Pin)) {
            $candidates.Add(@{ Address = $Pin.Trim(); Source = 'pinned' })
        } elseif (-not [string]::IsNullOrWhiteSpace($env:YURUNA_STASH_SERVICE_HOST)) {
            $candidates.Add(@{ Address = $env:YURUNA_STASH_SERVICE_HOST.Trim(); Source = '$env:YURUNA_STASH_SERVICE_HOST' })
        } elseif ($canDiscover) {
            # @(): a single discovered address unrolls to a scalar string, and
            # iterating THAT walks its characters.
            $discovered = @()
            try { $discovered = @(Get-ExtensionHostAddress -HostType 'stash-service') } catch {
                Write-Verbose "Get-ExtensionHostAddress stash-service: $($_.Exception.Message)"
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
                return $result
            }
            $lines.Add(("  [FAIL] {0} ({1}) did not answer /healthz" -f $candidate.Address, $candidate.Source))
        }
        if ($candidates.Count -eq 0) {
            # "found none" covers two very different situations and the operator
            # acts differently on each: a pool that answered and knows no stash
            # is a registration problem, one that could not be reached at all is
            # this host's link. Name whichever it was.
            $why = ''
            if (Get-Command Get-PoolExtensionHostLastOutcome -ErrorAction SilentlyContinue) {
                $poolOutcome = Get-PoolExtensionHostLastOutcome
                $why = ' [pool: ' + $poolOutcome.Outcome
                if ($poolOutcome.Detail) { $why += ' -- ' + $poolOutcome.Detail }
                $why += ']'
            }
            $lines.Add('  [FAIL] no candidate at all: nothing pinned, and discovery (this host, the pool) found none.' + $why)
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
    return $result
}

Export-ModuleMember -Function Resolve-StashService
