<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42e65f7e-5360-4e88-88af-67fa7c3b5d6f
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

$script:personaCache = $null
$script:personaCacheKey = ''

# --- REGION: Get-DemoHostIp
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

# --- REGION: Get-DemoHostIpList
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

# --- REGION: Test-DemoAdministrator
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

# --- REGION: Add-DemoFirewallRule
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

# --- REGION: Invoke-DemoNativeCommand
function Invoke-DemoNativeCommand {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$Elevated)
    $program = $FilePath
    $nativeArgs = $ArgumentList
    if ($Elevated -and -not (Test-DemoAdministrator)) {
        $program = 'sudo'
        $nativeArgs = @($FilePath) + $ArgumentList
    }
    $global:LASTEXITCODE = 0
    $output = @(& $program @nativeArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$FilePath exited $LASTEXITCODE`: $($output -join ' ')" }
    return $output
}

# --- REGION: Add-DemoFirewallRuleWindows
function Add-DemoFirewallRuleWindows {
    <#
    .SYNOPSIS
    Adds the inbound rule and the http.sys reservation, elevating if needed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([int]$Port, [string]$RuleName)

    if (-not $PSCmdlet.ShouldProcess("port $Port", 'open inbound firewall port and reserve listener URL')) { return $false }
    $quotedRule = $RuleName.Replace("'", "''")
    $quotedUser = "$env:USERDOMAIN\$env:USERNAME".Replace("'", "''")
    $inner = @"
`$ErrorActionPreference = 'Stop'
if (-not (Get-NetFirewallRule -DisplayName '$quotedRule' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName '$quotedRule' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
}
`$reservation = @(& netsh http show urlacl 'url=http://+:$Port/' 2>&1) -join ' '
if (`$LASTEXITCODE -ne 0 -or `$reservation -notmatch [regex]::Escape('http://+:$Port/')) {
    & netsh http add urlacl 'url=http://+:$Port/' 'user=$quotedUser' | Out-Null
    if (`$LASTEXITCODE -ne 0) { throw 'Listener URL reservation failed.' }
}
"@
    try {
        if (Test-DemoAdministrator) {
            & ([scriptblock]::Create($inner))
        } else {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
                -Verb RunAs -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -ne 0) { throw "Elevated helper exited $($process.ExitCode)." }
        }
        Write-Information "Firewall: opened inbound TCP $Port." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Firewall: could not open TCP $Port ($($_.Exception.Message))."
        return $false
    }
}

# --- REGION: Add-DemoFirewallRuleMacOS
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
    try {
        $globalState = (Invoke-DemoNativeCommand -FilePath $fw -ArgumentList '--getglobalstate') -join ' '
        if ($globalState -notmatch 'enabled') { return $true }
        $pwshPath = (Get-Process -Id $PID).Path
        if (-not $PSCmdlet.ShouldProcess($pwshPath, 'allow incoming connections')) { return $false }
        Invoke-DemoNativeCommand -FilePath $fw -ArgumentList @('--add', $pwshPath) -Elevated | Out-Null
        Invoke-DemoNativeCommand -FilePath $fw -ArgumentList @('--unblockapp', $pwshPath) -Elevated | Out-Null
        Write-Information 'Firewall: this PowerShell may accept incoming connections.' -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Firewall: could not update the application firewall ($($_.Exception.Message))."
        return $false
    }
}

# --- REGION: Add-DemoFirewallRuleLinux
function Add-DemoFirewallRuleLinux {
    <#
    .SYNOPSIS
    Allows the port through ufw or firewalld, whichever is active.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([int]$Port)

    try {
        if (Get-Command ufw -ErrorAction SilentlyContinue) {
            $status = (Invoke-DemoNativeCommand -FilePath 'ufw' -ArgumentList 'status' -Elevated) -join ' '
            if ($status -match 'Status:\s*active') {
                if ($status -match "\b$Port/tcp\s+ALLOW") { return $true }
                if (-not $PSCmdlet.ShouldProcess("$Port/tcp", 'ufw allow')) { return $false }
                Invoke-DemoNativeCommand -FilePath 'ufw' -ArgumentList @('allow', "$Port/tcp") -Elevated | Out-Null
                return $true
            }
        }
        if (Get-Command firewall-cmd -ErrorAction SilentlyContinue) {
            $state = (Invoke-DemoNativeCommand -FilePath 'firewall-cmd' -ArgumentList '--state' -Elevated) -join ' '
            if ($state -match '^running$') {
                if (-not $PSCmdlet.ShouldProcess("$Port/tcp", 'firewall-cmd --add-port')) { return $false }
                Invoke-DemoNativeCommand -FilePath 'firewall-cmd' -ArgumentList "--add-port=$Port/tcp" -Elevated | Out-Null
                return $true
            }
        }
        Write-Information "Firewall: no active ufw or firewalld found; inbound $Port needs nothing here." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Firewall: could not open TCP $Port ($($_.Exception.Message))."
        return $false
    }
}

# --- REGION: New-DemoListener
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

# --- REGION: Enable-DemoStopKey
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

# --- REGION: Disable-DemoStopKey
function Disable-DemoStopKey {
    <#
    .SYNOPSIS
    Restores normal Ctrl+C handling on exit.
    #>
    [CmdletBinding()]
    param()
    try { [Console]::TreatControlCAsInput = $false } catch { Write-Verbose 'Console restore skipped.' }
}

# --- REGION: Test-DemoStopKey
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


# --- REGION: HTTP request/response helpers shared by the demo servers
# Shared by serve-by-act.ps1 and serve-data-view.ps1. Write-Json's -Depth
# default of 8 is the depth both servers rely on. Send-StaticFile and
# Invoke-Proxy deliberately stay per-server -- their differences are each
# app's own routing and proxy policy, not drift.

# --- REGION: Resolve-VmIp
function Resolve-VmIp([string]$Name, [string]$YurunaRoot) {
    <#
    .SYNOPSIS
    Resolve the demo VM's reachable IP, then try the explicitly supplied root's handoff file.
    #>
    if (Get-Command -Name 'Get-VMIp' -ErrorAction SilentlyContinue) {
        try {
            $ip = Get-VMIp -VMName $Name
            if ($ip) { return [string]$ip }
        } catch {
            Write-Verbose "Get-VMIp '$Name' failed: $($_.Exception.Message); trying the handoff file."
        }
    }
    $logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR }
               elseif ($YurunaRoot)     { Join-Path $YurunaRoot 'test/status/log' }
               else                     { '' }
    if (-not $logRoot) { return '' }
    $ipFile = Join-Path $logRoot "handoff/$Name.ip.txt"
    if (Test-Path -LiteralPath $ipFile) { return (Get-Content -LiteralPath $ipFile -Raw).Trim() }
    return ''
}

# --- REGION: Get-PersonaSecret
function Get-PersonaSecret {
    <#
    .SYNOPSIS
    The demo personas and their shared secrets, read once from the Yuruna
    authentication vault.
    .DESCRIPTION
    The root and usernames are explicit because a module cannot read the
    importing script's local variables. Cache only matching inputs in this
    module; another root or persona set must resolve its own values.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyString()][string]$YurunaRoot,
        [Parameter(Mandatory)][string[]]$Usernames
    )
    $cacheKey = ConvertTo-Json -InputObject ([ordered]@{ root = $YurunaRoot; users = @($Usernames) }) -Compress
    if ($null -ne $script:personaCache -and $script:personaCacheKey -ceq $cacheKey) { return ,$script:personaCache }
    $vaultError = ''
    if (-not $YurunaRoot) {
        $vaultError = 'framework checkout not located; pass -YurunaRoot or set YURUNA_ROOT'
    } else {
        try { Import-Module (Join-Path $YurunaRoot 'test/extension/authentication/default.psm1') -Force -ErrorAction Stop }
        catch { $vaultError = $_.Exception.Message }
    }
    $list = foreach ($u in $Usernames) {
        $pw = ''
        if ($vaultError) { $pw = "<vault error: $vaultError>" }
        else { try { $pw = Get-Password -Username $u } catch { $pw = "<vault error: $($_.Exception.Message)>" } }
        [ordered]@{ username = $u; password = $pw }
    }
    $script:personaCache = @($list)
    $script:personaCacheKey = $cacheKey
    return ,$script:personaCache
}

# --- REGION: Test-LoopbackClient
function Test-LoopbackClient($Request) {
    <#
    .SYNOPSIS
    Whether a request arrived from this machine, so loopback-only routes can refuse the rest.
    #>
    $addr = $Request.RemoteEndPoint.Address
    # A dual-stack listener reports IPv4 peers as ::ffff:127.0.0.1, which
    # IsLoopback does not recognize in its mapped form.
    if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
    return [System.Net.IPAddress]::IsLoopback($addr)
}

# --- REGION: Write-Body
function Write-Body($Response, [int]$Status, [byte[]]$Bytes, [string]$ContentType) {
    <#
    .SYNOPSIS
    Write a byte payload to an HttpListener response and close it.
    #>
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

# --- REGION: Write-Json
function Write-Json($Response, [int]$Status, $Object, [int]$Depth = 8) {
    <#
    .SYNOPSIS
    Write an object as a JSON response body. -Depth defaults to 8, the depth both demo servers rely on.
    #>
    $Response.Headers['Cache-Control'] = 'no-store'
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Depth $Depth))
    Write-Body -Response $Response -Status $Status -Bytes $bytes -ContentType 'application/json'
}

Export-ModuleMember -Function Get-DemoHostIp, Get-DemoHostIpList, Test-DemoAdministrator,
    Add-DemoFirewallRule, New-DemoListener, Enable-DemoStopKey, Disable-DemoStopKey, Test-DemoStopKey, `
    Resolve-VmIp, Get-PersonaSecret, Test-LoopbackClient, Write-Body, Write-Json
