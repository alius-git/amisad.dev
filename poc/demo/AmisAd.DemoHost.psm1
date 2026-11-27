<#PSScriptInfo
.VERSION 2026.11.26
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
        [Parameter(Mandatory)][string]$RuleName,
        [string]$NativeExecutable
    )
    # Opening an inbound port is a real change to the machine, so it is
    # announced before it happens, it is idempotent, and every failure is a
    # warning rather than a stop: the demo still works for anyone who can
    # already reach the port.
    if ($IsWindows) { return Add-DemoFirewallRuleWindows -Port $Port -RuleName $RuleName -NativeListener:([bool]$NativeExecutable) }
    if ($IsMacOS) { return Add-DemoFirewallRuleMacOS -Executable $NativeExecutable }
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
    param([int]$Port, [string]$RuleName, [switch]$NativeListener)

    $action = if ($NativeListener) { 'open inbound firewall port' } else { 'open inbound firewall port and reserve listener URL' }
    if (-not $PSCmdlet.ShouldProcess("port $Port", $action)) { return $false }
    $quotedRule = $RuleName.Replace("'", "''")
    $quotedUser = "$env:USERDOMAIN\$env:USERNAME".Replace("'", "''")
    $inner = @"
`$ErrorActionPreference = 'Stop'
if (-not (Get-NetFirewallRule -DisplayName '$quotedRule' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName '$quotedRule' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
}
if ('$NativeListener' -ne 'True') {
    `$reservation = @(& netsh http show urlacl 'url=http://+:$Port/' 2>&1) -join ' '
    if (`$LASTEXITCODE -ne 0 -or `$reservation -notmatch [regex]::Escape('http://+:$Port/')) {
        & netsh http add urlacl 'url=http://+:$Port/' 'user=$quotedUser' | Out-Null
        if (`$LASTEXITCODE -ne 0) { throw 'Listener URL reservation failed.' }
    }
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
    Lets the listener executable accept incoming connections through the macOS firewall.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$Executable)

    $fw = '/usr/libexec/ApplicationFirewall/socketfilterfw'
    if (-not (Test-Path -LiteralPath $fw)) { return $true }
    try {
        $globalState = (Invoke-DemoNativeCommand -FilePath $fw -ArgumentList '--getglobalstate') -join ' '
        if ($globalState -notmatch 'enabled') { return $true }
        $listener = if ($Executable) { $Executable } else { (Get-Process -Id $PID).Path }
        if (-not $PSCmdlet.ShouldProcess($listener, 'allow incoming connections')) { return $false }
        Invoke-DemoNativeCommand -FilePath $fw -ArgumentList @('--add', $listener) -Elevated | Out-Null
        Invoke-DemoNativeCommand -FilePath $fw -ArgumentList @('--unblockapp', $listener) -Elevated | Out-Null
        Write-Information "Firewall: $listener may accept incoming connections." -InformationAction Continue
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
    Whether a request arrived from this machine, addressed to it by a loopback
    name, so loopback-only routes can refuse the rest.
    .DESCRIPTION
    A page on another site can have its own host name resolve to 127.0.0.1
    (DNS rebinding): its requests then arrive from a loopback peer but name
    that site in Host, so the peer alone does not prove a local caller.
    #>
    $addr = $Request.RemoteEndPoint.Address
    # A dual-stack listener reports IPv4 peers as ::ffff:127.0.0.1, which
    # IsLoopback does not recognize in its mapped form.
    if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
    if (-not [System.Net.IPAddress]::IsLoopback($addr)) { return $false }
    $name = [string]$Request.Url.DnsSafeHost
    $literal = $null
    return ($name -eq 'localhost' -or ([System.Net.IPAddress]::TryParse($name, [ref]$literal) -and [System.Net.IPAddress]::IsLoopback($literal)))
}

# --- REGION: Test-DemoRequestHost
function Test-DemoRequestHost {
    <#
    .SYNOPSIS
    Whether a request names this machine in its Host header.
    .DESCRIPTION
    The demo answers to loopback names, to this machine's own addresses and
    name, and to the address it was bound to. Any other name is a page on
    another site whose name was made to resolve here (DNS rebinding), and is
    refused before a route runs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Request, [string]$BindAddress = 'any')
    $name = [string]$Request.Url.DnsSafeHost
    if (-not $name) { return $false }
    if ($name -eq 'localhost' -or $name -eq [Environment]::MachineName -or $name -eq $BindAddress) { return $true }
    $literal = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$literal)) {
        if ([System.Net.IPAddress]::IsLoopback($literal)) { return $true }
        return ($name -in @(Get-DemoHostIpList))
    }
    return $false
}

# --- REGION: Test-DemoSameOrigin
function Test-DemoSameOrigin {
    <#
    .SYNOPSIS
    Whether a request that changes demo state may come from where it came.
    .DESCRIPTION
    Browsers send Origin on every cross-origin request that is not a GET, a
    plain form post or a no-cors fetch included, so a request from another
    page names that page here and is refused. The demo's own pages send their
    own origin, and a client that is not a browser sends none.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Request)
    $origin = [string]$Request.Headers['Origin']
    if (-not $origin) { return $true }
    $own = '{0}://{1}' -f $Request.Url.Scheme, $Request.Url.Authority
    return [string]::Equals($origin.TrimEnd('/'), $own, [StringComparison]::OrdinalIgnoreCase)
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

# --- REGION: Receive-AmisAdDemoArtifact
function Receive-AmisAdDemoArtifact {
    <#
    .SYNOPSIS
    Resolve a pinned native demo for this project checkout.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$YurunaRoot, [string]$DemoRoot)
    if (-not $YurunaRoot) { return '' }
    $configPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } else { Join-Path $YurunaRoot 'test/test.config.yml' }
    if (-not [IO.File]::Exists($configPath)) { return '' }
    $configPath = [IO.Path]::GetFullPath($configPath)
    Import-Module (Join-Path $YurunaRoot 'test/modules/Test.Config.psm1') -DisableNameChecking -ErrorAction Stop
    $config = Read-TestConfig -Path $configPath
    $builderFile = [string]$config.vmStart.buildServiceConfigFile
    if (-not $builderFile) { return '' }
    $builderPath = [IO.Path]::GetFullPath($builderFile, (Split-Path -Parent $configPath))
    if (-not [IO.File]::Exists($builderPath)) { return '' }
    $builder = [IO.File]::ReadAllText($builderPath) | ConvertFrom-Json -AsHashtable -Depth 20
    $consumer = $builder.consumer
    $pins = $consumer.amisad
    if (-not $pins) { return '' }
    if ($pins -isnot [Collections.IDictionary] -or $pins.candidateId -cnotmatch '^[a-f0-9]{64}$' -or
        $pins.manifestSha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $consumer.trustedPublicKeyFile -or -not $consumer.baseUrl) {
        throw 'The AmisAd artifact candidate, digest, builder address, or enrolled public key is invalid.'
    }
    $project = [IO.Path]::GetFullPath((Join-Path $DemoRoot '../../..'))
    $revision = [string](& git -C $project rev-parse --verify 'HEAD^{commit}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $revision -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify the AmisAd checkout revision.' }
    $key = [IO.Path]::GetFullPath([string]$consumer.trustedPublicKeyFile, (Split-Path -Parent $builderPath))
    Import-Module (Join-Path $YurunaRoot 'test/extension/build-service/default.psm1') -DisableNameChecking -ErrorAction Stop
    return Receive-BuildServiceArtifact -BaseUrl $consumer.baseUrl -CandidateId $pins.candidateId `
        -ManifestSha256 $pins.manifestSha256 -TrustedKeyFile $key -RequiredRevision $revision -Binary 'amisad-demo-host' `
        -InstallRoot (Join-Path $HOME '.yuruna/verified-artifacts') -Confirm:$false
}

# --- REGION: Resolve-AmisAdDemoExecutable
function Resolve-AmisAdDemoExecutable {
    <#
    .SYNOPSIS
    Find the native demo beside the project's other built executables.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DemoRoot, [string]$YurunaRoot)
    $verified = Receive-AmisAdDemoArtifact -DemoRoot $DemoRoot -YurunaRoot $YurunaRoot
    if ($verified) { return $verified }
    $name = if ($IsWindows) { 'amisad-demo-host.exe' } else { 'amisad-demo-host' }
    $directories = if ($env:AMISAD_BIN_DIR) { @($env:AMISAD_BIN_DIR) } else {
        @((Join-Path $DemoRoot '../../target/release'), (Join-Path $DemoRoot '../../target/debug'))
    }
    foreach ($directory in $directories) {
        $candidate = Join-Path $directory $name
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    return ''
}

# --- REGION: Invoke-AmisAdNativeDemo
function Invoke-AmisAdNativeDemo {
    <#
    .SYNOPSIS
    Run the demo's native HTTP service with access to the host's existing providers.
    .DESCRIPTION
    The child requests persona and VM data on its inherited pipes. The Rust
    routes check which HTTP clients may obtain secrets before requesting them.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][ValidateSet('by-act', 'data-view')][string]$Mode,
        [Parameter(Mandatory)][string]$DemoRoot,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$BindAddress,
        [AllowEmptyString()][string]$YurunaRoot,
        [AllowEmptyString()][string]$CoreIp,
        [AllowEmptyString()][string]$EdgeAIp,
        [AllowEmptyString()][string]$EdgeBIp,
        [Parameter(Mandatory)][string[]]$PersonaUsers,
        [scriptblock]$VmReport,
        [switch]$SharePersonaPasswords
    )
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @($Mode, '--host-bridge', '--port', "$Port", '--bind-address', $BindAddress,
        '--demo-root', $DemoRoot, '--core-ip', $CoreIp, '--edge-a-ip', $EdgeAIp, '--edge-b-ip', $EdgeBIp)) {
        $info.ArgumentList.Add($argument)
    }
    if ($SharePersonaPasswords) { $info.ArgumentList.Add('--share-persona-passwords') }
    $keyStop = Enable-DemoStopKey
    $process = $null
    Write-Information $(if ($keyStop) { 'Press Ctrl+C, End or Q to stop.' } else { 'Press Ctrl+C to stop.' }) -InformationAction Continue
    try {
        $process = [Diagnostics.Process]::Start($info)
        $line = $process.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($keyStop -and (Test-DemoStopKey)) {
                if (-not $process.HasExited) {
                    $process.StandardInput.WriteLine('{"kind":"stop"}')
                    $process.StandardInput.Flush()
                }
                break
            }
            if (-not $line.Wait(200)) { continue }
            $text = $line.GetAwaiter().GetResult()
            if ($null -eq $text) { break }
            if ($text.StartsWith('AMISAD-HOST ', [StringComparison]::Ordinal)) {
                $request = $text.Substring(12) | ConvertFrom-Json -AsHashtable -Depth 4
                if (($request.id -isnot [int] -and $request.id -isnot [long]) -or $request.id -le 0) {
                    throw 'Invalid native demo host request.'
                }
                $value = $null
                try {
                    if ($request.resource -ceq 'personas') {
                        $value = Get-PersonaSecret -YurunaRoot $YurunaRoot -Usernames $PersonaUsers
                    } elseif ($request.resource -ceq 'vms' -and $VmReport) {
                        $value = @(& $VmReport)
                    }
                } catch {
                    # A provider error is unavailable data. Do not print a vault response.
                    Write-Verbose "Native demo host resource unavailable: $($_.Exception.GetType().Name)"
                }
                $reply = @{ kind = 'response'; id = $request.id; value = $value } | ConvertTo-Json -Depth 6 -Compress
                $process.StandardInput.WriteLine($reply)
                $process.StandardInput.Flush()
            } else {
                Write-Information $text -InformationAction Continue
            }
            $line = $process.StandardOutput.ReadLineAsync()
        }
        if (-not $process.WaitForExit(5000)) { $process.Kill($true); $process.WaitForExit() }
        return $process.ExitCode
    } finally {
        if ($process) {
            try {
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(5000)) { $process.Kill($true); $process.WaitForExit() }
            } finally { $process.Dispose() }
        }
        if ($keyStop) { Disable-DemoStopKey }
    }
}

Export-ModuleMember -Function Get-DemoHostIp, Get-DemoHostIpList, Test-DemoAdministrator,
    Add-DemoFirewallRule, New-DemoListener, Enable-DemoStopKey, Disable-DemoStopKey, Test-DemoStopKey, `
    Resolve-VmIp, Get-PersonaSecret, Test-LoopbackClient, Test-DemoRequestHost, Test-DemoSameOrigin, Write-Body, Write-Json,
    Resolve-AmisAdDemoExecutable, Invoke-AmisAdNativeDemo
