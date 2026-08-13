<#PSScriptInfo
.VERSION 2026.08.14
.GUID 42ece3f0-71f7-49a5-b325-387b1c3c98ca
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc demo host serve
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
Shared host plumbing for the AmisAd demo servers.

.DESCRIPTION
Both demo servers under this folder present from the lab host to a laptop,
tablet or projector on the same network, so they share the parts that are
about the HOST rather than about either demo: which address to advertise, how
to get the port through whatever firewall this platform runs, how to bind a
listener that accepts off-box connections, and how to stop cleanly from the
keyboard.

Imported with -Force by each serve script; nothing here touches the lab.
#>

# No Set-StrictMode here: it propagates to the scripts that import this module
# and would change how their own code treats unset variables, which is not this
# module's call to make.

function Get-DemoHostIp {
    <#
    .SYNOPSIS
    The routable address to advertise for this host, or localhost when it has none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # The address to PRINT. Loopback is useless on a projector or read out to
    # someone holding a tablet, so the banner leads with a real routable
    # address and falls back to localhost only when there is no interface.
    $candidates = @()
    try {
        foreach ($a in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
            if ($a.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($a)) {
                $candidates += [string]$a
            }
        }
    } catch {
        Write-Verbose "Host address lookup failed: $($_.Exception.Message)"
    }
    if (-not $candidates) { return 'localhost' }
    # A host that also runs the hypervisor has a virtual-bridge address the
    # guests use; the audience is on the physical LAN, so prefer anything that
    # is not one of the usual virtual ranges.
    $physical = @($candidates | Where-Object {
        $_ -notmatch '^(192\.168\.122\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|169\.254\.)'
    })
    if ($physical.Count) { return $physical[0] }
    return $candidates[0]
}

function Get-DemoHostIpList {
    <#
    .SYNOPSIS
    Every non-loopback IPv4 address of this host.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $list = @()
    try {
        foreach ($a in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
            if ($a.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($a)) {
                $list += [string]$a
            }
        }
    } catch {
        Write-Verbose "Host address lookup failed: $($_.Exception.Message)"
    }
    return [string[]]$list
}

function Test-DemoAdministrator {
    <#
    .SYNOPSIS
    Whether this process can already change firewall state without elevation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($IsWindows) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return ((id -u) -eq '0')
}

function Add-DemoFirewallRule {
    <#
    .SYNOPSIS
    Opens the demo port inbound on whichever firewall this platform runs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$RuleName
    )
    # Opening an inbound port is a real change to the machine, so it is
    # announced before it happens, it is idempotent, and every failure is a
    # warning rather than a stop: the demo still works for anyone who can
    # already reach the port.
    if ($IsWindows) { return Add-DemoFirewallRuleWindows -Port $Port -RuleName $RuleName }
    if ($IsMacOS) { return Add-DemoFirewallRuleMacOS }
    return Add-DemoFirewallRuleLinux -Port $Port
}

function Add-DemoFirewallRuleWindows {
    <#
    .SYNOPSIS
    Adds the inbound rule and the http.sys reservation, elevating if needed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([int]$Port, [string]$RuleName)

    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Information "Firewall: inbound rule '$RuleName' already present." -InformationAction Continue
        return $true
    }
    # Windows needs the same elevation for the http.sys reservation that a
    # non-loopback HttpListener prefix requires, so both are done in one pass.
    $inner = "New-NetFirewallRule -DisplayName '$RuleName' -Direction Inbound -Protocol TCP " +
             "-LocalPort $Port -Action Allow -Profile Any | Out-Null; " +
             "netsh http add urlacl url=http://+:$Port/ user='$env:USERDOMAIN\$env:USERNAME' | Out-Null"
    if (Test-DemoAdministrator) {
        if (-not $PSCmdlet.ShouldProcess("port $Port", 'open inbound firewall port')) { return $false }
        try {
            New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP `
                -LocalPort $Port -Action Allow -Profile Any | Out-Null
            & netsh http add urlacl "url=http://+:$Port/" "user=$env:USERDOMAIN\$env:USERNAME" | Out-Null
            Write-Information "Firewall: opened inbound TCP $Port." -InformationAction Continue
            return $true
        } catch {
            Write-Warning "Firewall: could not open TCP $Port ($($_.Exception.Message))."
            return $false
        }
    }
    Write-Information "Firewall: inbound TCP $Port is not open yet - Windows will ask for administrator approval." -InformationAction Continue
    if (-not $PSCmdlet.ShouldProcess("port $Port", 'open inbound firewall port (elevated)')) { return $false }
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $inner `
            -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0) {
            Write-Information "Firewall: opened inbound TCP $Port." -InformationAction Continue
            return $true
        }
        Write-Warning "Firewall: the elevated helper exited with $($p.ExitCode); TCP $Port may still be blocked."
        return $false
    } catch {
        Write-Warning ("Firewall: elevation declined or failed ($($_.Exception.Message)). " +
            "Open TCP $Port manually, or rerun this script from an elevated shell.")
        return $false
    }
}

function Add-DemoFirewallRuleMacOS {
    <#
    .SYNOPSIS
    Lets this PowerShell accept incoming connections through the macOS firewall.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    $fw = '/usr/libexec/ApplicationFirewall/socketfilterfw'
    if (-not (Test-Path -LiteralPath $fw)) { return $true }
    $globalState = (& $fw --getglobalstate 2>$null) -join ' '
    if ($globalState -notmatch 'enabled') {
        Write-Information 'Firewall: the macOS application firewall is off; nothing to open.' -InformationAction Continue
        return $true
    }
    # That firewall filters by application, not by port, so the thing to
    # unblock is this PowerShell binary rather than a port number.
    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $PSCmdlet.ShouldProcess($pwshPath, 'allow incoming connections')) { return $false }
    Write-Information "Firewall: allowing incoming connections for $pwshPath (sudo may prompt)." -InformationAction Continue
    try {
        & sudo $fw --add $pwshPath | Out-Null
        & sudo $fw --unblockapp $pwshPath | Out-Null
        Write-Information 'Firewall: this PowerShell may accept incoming connections.' -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Firewall: could not update the application firewall ($($_.Exception.Message))."
        return $false
    }
}

function Add-DemoFirewallRuleLinux {
    <#
    .SYNOPSIS
    Allows the port through ufw or firewalld, whichever is active.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([int]$Port)

    $sudo = @()
    if (-not (Test-DemoAdministrator)) { $sudo = @('sudo') }

    if (Get-Command ufw -ErrorAction SilentlyContinue) {
        $status = (& @sudo ufw status 2>$null) -join ' '
        if ($status -match 'Status:\s*active') {
            if ($status -match "\b$Port/tcp\s+ALLOW") {
                Write-Information "Firewall: ufw already allows $Port/tcp." -InformationAction Continue
                return $true
            }
            if (-not $PSCmdlet.ShouldProcess("$Port/tcp", 'ufw allow')) { return $false }
            Write-Information "Firewall: running 'ufw allow $Port/tcp' (sudo may prompt)." -InformationAction Continue
            & @sudo ufw allow "$Port/tcp" | Out-Null
            return $true
        }
    }
    if (Get-Command firewall-cmd -ErrorAction SilentlyContinue) {
        $state = (& firewall-cmd --state 2>$null) -join ' '
        if ($state -match 'running') {
            if (-not $PSCmdlet.ShouldProcess("$Port/tcp", 'firewall-cmd --add-port')) { return $false }
            Write-Information "Firewall: running 'firewall-cmd --add-port=$Port/tcp' (sudo may prompt)." -InformationAction Continue
            & @sudo firewall-cmd --add-port="$Port/tcp" | Out-Null
            return $true
        }
    }
    Write-Information "Firewall: no active ufw or firewalld found; inbound $Port needs nothing here." -InformationAction Continue
    return $true
}

function New-DemoListener {
    <#
    .SYNOPSIS
    Binds and starts an HttpListener that accepts connections from other machines.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Net.HttpListener])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$BindAddress = 'any'
    )
    # 'localhost' as an HttpListener prefix binds the loopback interface alone
    # - not "every interface, addressed by name" - so anything reachable from
    # another machine needs the wildcard or that NIC's own address.
    $listener = [System.Net.HttpListener]::new()
    $wildcard = $BindAddress -in @('any', '*', '+', '0.0.0.0', '::')
    if ($wildcard) {
        $listener.Prefixes.Add("http://+:$Port/")
    } else {
        $listener.Prefixes.Add("http://${BindAddress}:$Port/")
        # A single-NIC binding would otherwise lock the host's own browser out,
        # and loopback clients are the ones allowed to see vault passwords.
        if ($BindAddress -ne 'localhost') { $listener.Prefixes.Add("http://localhost:$Port/") }
    }
    if (-not $PSCmdlet.ShouldProcess(($listener.Prefixes -join ', '), 'start HTTP listener')) { return $null }
    try {
        $listener.Start()
    } catch [System.Net.HttpListenerException] {
        # Windows reserves non-loopback prefixes in http.sys; Linux and macOS
        # use the managed listener and need no reservation.
        if ($_.Exception.ErrorCode -eq 5) {
            throw ("Access denied binding $($listener.Prefixes -join ', '). On Windows a non-loopback " +
                "prefix needs a reservation - rerun from an elevated shell (this script offers to add " +
                "it), or once as admin: netsh http add urlacl url=http://+:$Port/ user=$env:USERDOMAIN\$env:USERNAME")
        }
        throw
    }
    return $listener
}

function Enable-DemoStopKey {
    <#
    .SYNOPSIS
    Routes Ctrl+C to the request loop so the server can stop without killing the terminal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Ctrl+C cannot interrupt a thread parked in HttpListener.GetContext(),
    # which is why a server built that way can only be stopped by closing the
    # terminal. Reading the console as input instead lets the request loop
    # notice Ctrl+C, End or Q between polls and shut down properly.
    try {
        [Console]::TreatControlCAsInput = $true
        return $true
    } catch {
        Write-Verbose "Console key input unavailable: $($_.Exception.Message)"
        return $false
    }
}

function Disable-DemoStopKey {
    <#
    .SYNOPSIS
    Restores normal Ctrl+C handling on exit.
    #>
    [CmdletBinding()]
    param()
    try { [Console]::TreatControlCAsInput = $false } catch { Write-Verbose 'Console restore skipped.' }
}

function Test-DemoStopKey {
    <#
    .SYNOPSIS
    Drains the console buffer and reports whether Ctrl+C, End or Q was pressed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::End -or $k.Key -eq [ConsoleKey]::Q -or
                ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control))) {
                return $true
            }
        }
    } catch {
        Write-Verbose "Console key poll unavailable: $($_.Exception.Message)"
    }
    return $false
}

Export-ModuleMember -Function Get-DemoHostIp, Get-DemoHostIpList, Test-DemoAdministrator,
    Add-DemoFirewallRule, New-DemoListener, Enable-DemoStopKey, Disable-DemoStopKey, Test-DemoStopKey
