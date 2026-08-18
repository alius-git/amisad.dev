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
    A module rather than a dot-sourced helper so both drivers run ONE
    implementation: the address a pass uploads its binaries to must not depend
    on which entry point started it.

    This project states no stash address of its own. A site's stash address is
    that site's -- naming one here would leak it and would go stale the first
    time the service moved -- so every candidate is either discovered through
    the Yuruna framework or stated by the operator, and an environment that can
    produce neither has no stash as far as a pass is concerned.
#>

Set-StrictMode -Version Latest

function Resolve-StashService {
    <#
    .SYNOPSIS
        Find the stash service, verify it answers, and publish the address for
        the rest of the cycle to resolve without re-probing.
    .DESCRIPTION
        The build uploads its binaries to the stash and vm-core downloads them,
        so a stash nobody can reach makes the whole pass pointless -- but the
        guests only discover that from inside their own long chains, tens of
        minutes in. Resolving here, before any VM starts, turns that into an
        immediate stop.

        A pin (-Pin, or $env:YURUNA_STASH_SERVICE_HOST for the address a pool handed
        this host) is the ONLY candidate when present -- a pass told to use a
        particular stash must fail rather than quietly exercise a different one.
        Otherwise every address the framework can find for the area
        (Get-ExtensionHostAddress -HostType 'stash-service') is tried in order
        and the first that answers /healthz wins: an operator pin for the area,
        a stash VM on THIS host at its current address, and the address the pool
        reports for a stash running on another host entirely. The pool answer is
        what keeps a lab working after its stash is rebuilt onto a new IP -- the
        service announces itself, and this host reads that back.

        Both the discovery and the probe are re-asked over a short backoff
        rather than answered once. A host whose link is briefly away -- a DHCP
        renew is enough, even one that hands back the same address -- produces
        an empty directory answer and a failed /healthz that are indistinguish-
        able from having no stash at all, and this runs before any VM starts,
        so a single unlucky instant would end the pass. A stash that is really
        absent stays absent for the whole window and still stops it.

        Publishing the winner makes every later
        ${ext:stash-service.ResolveHost(...)} expansion return the address that
        was actually verified, instead of each sequence re-probing for a VM this
        host may not run and warning when it finds none. Nothing answering
        CLEARS the published address, so a pass can never inherit one a previous
        cycle proved and this one did not.

        Progress is returned as Lines rather than written here: a module
        function does not see the caller's script-scoped $InformationPreference,
        so printing inside would silently drop the very report an operator needs
        when the pre-flight is what stopped the pass.
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

    # Every leg of this resolution rides the host's link, and that link is not
    # continuously up: a DHCP renew alone takes it away for a few seconds, and a
    # renew that returns the SAME address still does, so nothing downstream even
    # reports an address change. Inside that window the pool lookup answers with
    # nothing and a perfectly healthy stash fails /healthz -- both shaped exactly
    # like a stash that does not exist. Answering on the first attempt therefore
    # converts a blip into a hard stop before any VM starts, and the pass dies
    # for a condition that cured itself seconds later.
    #
    # So ask across a window that outlasts a renew rather than at one instant.
    # Discovery is redone per attempt, not just the probe: the empty answer is
    # the more common symptom, and a cached candidate list would keep replaying
    # it. Only an environment still silent at the end of the window really has
    # no stash, and that still stops the pass.
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
