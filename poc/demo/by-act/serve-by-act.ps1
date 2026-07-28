<#PSScriptInfo
.VERSION 2026.07.28
.GUID 42b8c9d4-7e2f-4a61-9c05-3f8e1a6b2d47
.AUTHOR Alisson Sol et al.
.Copyright (c) 2026 by Alisson Sol et al.
.TAGS amisad poc demo serve
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# AmisAd demo console server (host-side). Serves the poc/demo mock UI and
# slide deck, exposes the demo persona passwords from the Yuruna
# authentication vault, and proxies browser API calls to the amisad-core
# NodePorts and the edge slice-runtimes (the POC services send no CORS
# headers, so the browser cannot call them cross-origin; same-origin via this
# proxy needs none). It changes nothing on the VMs beyond the API calls the
# operator clicks in the UI, and it requires no change to the deployed
# topology left live by amisad.end-to-end.yml.
#
# Binds loopback by default. -BindAddress opens it to the network so the lab
# host can serve a console driven from the presenter's laptop; the vault
# passwords on /api/personas stay loopback-only regardless, until
# -SharePersonaPasswords says otherwise (see Get-PersonaSecrets).
param(
    [int]$Port = 8091,
    [string]$YurunaRoot,
    [string]$CoreIp = '',
    [string]$EdgeAIp = '',
    [string]$EdgeBIp = '',
    # 'localhost' (default), 'any'/'*'/'+' for every interface, or one
    # hostname/IP to bind a single NIC.
    [string]$BindAddress = 'localhost',
    [switch]$SharePersonaPasswords
)
$ErrorActionPreference = 'Stop'
$demoRoot = $PSScriptRoot
# Forward slashes in every framework-relative path: a literal '..\components\art'
# is one filename containing backslashes on Linux/macOS, and a 'c:\...' root is
# read as a PSDrive name there ("Cannot find drive").
$artRoot = [IO.Path]::GetFullPath((Join-Path $demoRoot '../components/art'))

# Resolve-YurunaRoot discovers the framework checkout (explicit param ->
# YURUNA_ROOT -> YURUNA_CONFIG_PATH -> the clone layout -> a per-platform
# conventional path); Initialize-AmisAdHost imports the host driver so the
# unqualified Get-VMIp below reaches whichever hypervisor is running.
. ([IO.Path]::GetFullPath((Join-Path $demoRoot '../../test/AmisAd.HostCommon.ps1')))
try {
    $YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
} catch {
    # Not fatal: the UI, the deck and the proxy all work without the framework.
    # Only the vault passwords and the handoff-file IP fallback need it.
    Write-Warning "$($_.Exception.Message) Persona passwords will show as unavailable."
    $YurunaRoot = ''
}
if ($YurunaRoot) {
    try { $null = Initialize-AmisAdHost -YurunaRoot $YurunaRoot }
    catch { Write-Warning "Host driver unavailable ($($_.Exception.Message)); VM IPs fall back to the handoff files." }
}

# VM IP resolution: explicit param -> the host driver's guest report -> the
# status server's handoff file (the edges' boot-time IP reporter posts
# <hostname>.ip.txt there; see poc/usernames.md "Core->edge access").
function Resolve-VmIp([string]$Name) {
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
if (-not $CoreIp) { $CoreIp = Resolve-VmIp 'amisad-core' }
if (-not $EdgeAIp) { $EdgeAIp = Resolve-VmIp 'amisad-edge-a' }
if (-not $EdgeBIp) { $EdgeBIp = Resolve-VmIp 'amisad-edge-b' }

# Persona passwords come from the same vault the deploy chain rendered into
# chpasswd (poc/usernames.md). After a green end-to-end run every entry
# exists, so Get-Password is a pure read here; a missing entry would mean the
# VM account never got that password either.
$personaUsers = 'maya', 'elena', 'tom', 'marcel', 'kai', 'priya', 'ingrid', 'dana', 'alex', 'sam', 'pat'
$script:personaCache = $null
function Get-PersonaSecrets {
    if ($null -ne $script:personaCache) { return $script:personaCache }
    $vaultError = ''
    if (-not $YurunaRoot) {
        $vaultError = 'framework checkout not located; pass -YurunaRoot or set YURUNA_ROOT'
    } else {
        try { Import-Module (Join-Path $YurunaRoot 'test/extension/authentication/default.psm1') -Force }
        catch { $vaultError = $_.Exception.Message }
    }
    $list = foreach ($u in $personaUsers) {
        $pw = ''
        if ($vaultError) { $pw = "<vault error: $vaultError>" }
        else { try { $pw = Get-Password -Username $u } catch { $pw = "<vault error: $($_.Exception.Message)>" } }
        [ordered]@{ username = $u; password = $pw }
    }
    $script:personaCache = @($list)
    return $script:personaCache
}

# The vault passwords are the one thing here that must not travel further than
# the operator intends, so they are gated per REQUEST, not per binding: opening
# the console to the network still leaves the host's own browser fully
# featured, and remote viewers see the cards without the secrets.
function Test-LoopbackClient($Request) {
    $addr = $Request.RemoteEndPoint.Address
    # A dual-stack listener reports IPv4 peers as ::ffff:127.0.0.1, which
    # IsLoopback does not recognize in its mapped form.
    if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
    return [System.Net.IPAddress]::IsLoopback($addr)
}

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.md'   = 'text/plain; charset=utf-8'
    '.ico'  = 'image/x-icon'
}
$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(60)

function Write-Body($Response, [int]$Status, [byte[]]$Bytes, [string]$ContentType) {
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}
function Write-Json($Response, [int]$Status, $Object) {
    $Response.Headers['Cache-Control'] = 'no-store'
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Depth 8))
    Write-Body $Response $Status $bytes 'application/json'
}

# Forward one browser request to a lab endpoint, body and method intact,
# and relay the upstream status + body verbatim (non-2xx included: refusal
# statuses like 403/410 are demo evidence, not proxy errors).
function Invoke-Proxy($Request, $Response, [string]$TargetBase, [string]$Rest) {
    $uri = $TargetBase + $Rest + $Request.Url.Query
    $msg = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Request.HttpMethod), $uri)
    if ($Request.HasEntityBody) {
        $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
        $body = $reader.ReadToEnd()
        $msg.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    }
    try {
        $up = $http.SendAsync($msg).GetAwaiter().GetResult()
        $text = $up.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $ct = if ($up.Content.Headers.ContentType) { $up.Content.Headers.ContentType.ToString() } else { 'application/json' }
        $Response.Headers['Cache-Control'] = 'no-store'
        Write-Body $Response ([int]$up.StatusCode) ([Text.Encoding]::UTF8.GetBytes($text)) $ct
    } catch {
        Write-Json $Response 502 @{ error = $_.Exception.Message; target = $uri }
    }
}

function Send-StaticFile($Response, [string]$UrlPath) {
    $rel = $UrlPath.TrimStart('/')
    if ($rel -eq '') { $rel = 'ui/index.html' }
    if ($rel -like 'art/*') { $root = $artRoot; $rel = $rel.Substring(4) } else { $root = $demoRoot }
    $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Write-Json $Response 404 @{ error = "not found: $UrlPath" }
        return
    }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    $type = if ($mime.Contains($ext)) { $mime[$ext] } else { 'application/octet-stream' }
    Write-Body $Response 200 ([IO.File]::ReadAllBytes($full)) $type
}

$listener = [System.Net.HttpListener]::new()
# 'localhost' as an HttpListener prefix binds the loopback interface alone -
# not "every interface, addressed by name" - so a console reachable from the
# presenter's laptop needs the wildcard or that NIC's own address.
$wildcard = $BindAddress -in @('any', '*', '+', '0.0.0.0', '::')
if ($wildcard) {
    $listener.Prefixes.Add("http://+:$Port/")
} else {
    $listener.Prefixes.Add("http://${BindAddress}:$Port/")
    # A single-NIC binding would otherwise lock the host's own browser out,
    # and the loopback clients are the ones allowed to see vault passwords.
    if ($BindAddress -ne 'localhost') { $listener.Prefixes.Add("http://localhost:$Port/") }
}
try {
    $listener.Start()
} catch [System.Net.HttpListenerException] {
    # Windows reserves non-loopback prefixes in http.sys; Linux/macOS use the
    # managed listener and need no reservation.
    if ($_.Exception.ErrorCode -eq 5) {
        throw ("Access denied binding $($listener.Prefixes -join ', '). On Windows a " +
            "non-loopback prefix needs a reservation - run elevated, or once as admin: " +
            "netsh http add urlacl url=http://+:$Port/ user=$env:USERDOMAIN\$env:USERNAME")
    }
    throw
}

# Print what a remote browser should actually type. Reaching it also needs the
# host firewall to allow inbound $Port; nothing here changes firewall rules.
$hostUrls = if ($wildcard) {
    [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($_) } |
        ForEach-Object { "http://$($_):$Port/" }
} else { @() }
Write-Information "AmisAd demo console: http://localhost:$Port/   slides: http://localhost:$Port/slides.html" -InformationAction Continue
if ($hostUrls) {
    Write-Information "Reachable from other machines at: $($hostUrls -join '  ')  (open $Port on the host firewall)" -InformationAction Continue
} elseif (-not $wildcard -and $BindAddress -ne 'localhost') {
    Write-Information "Bound to ${BindAddress}: other machines use http://${BindAddress}:$Port/ (open $Port on the host firewall)" -InformationAction Continue
} else {
    Write-Information "Loopback only - pass -BindAddress any to present from another machine." -InformationAction Continue
}
if (($wildcard -or $BindAddress -ne 'localhost') -and $SharePersonaPasswords) {
    Write-Warning "-SharePersonaPasswords: the vault passwords on /api/personas are served in the clear to ANY machine that can reach port $Port."
}
Write-Information "Topology: core=$(if ($CoreIp) { $CoreIp } else { '<unresolved>' })  edge-a=$(if ($EdgeAIp) { $EdgeAIp } else { '<unresolved>' })  edge-b=$(if ($EdgeBIp) { $EdgeBIp } else { '<unresolved>' })" -InformationAction Continue
Write-Information "Framework: $(if ($YurunaRoot) { $YurunaRoot } else { '<not located>' })" -InformationAction Continue
if (-not $CoreIp) {
    Write-Warning 'amisad-core IP not resolved (host driver + handoff both empty) - pass -CoreIp; API calls will fail until then.'
}
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        try {
            $path = $req.Url.AbsolutePath
            if ($path -eq '/api/personas') {
                if ($SharePersonaPasswords -or (Test-LoopbackClient $req)) {
                    Write-Json $res 200 (Get-PersonaSecrets)
                } else {
                    Write-Json $res 200 @($personaUsers | ForEach-Object {
                        [ordered]@{ username = $_; password = '<withheld: remote viewer>' } })
                }
            } elseif ($path -eq '/api/topology') {
                Write-Json $res 200 ([ordered]@{ core = $CoreIp; edgeA = $EdgeAIp; edgeB = $EdgeBIp })
            } elseif ($path -match '^/api/core/(\d+)(/.*)$') {
                if ($CoreIp) { Invoke-Proxy $req $res "http://${CoreIp}:$($Matches[1])" $Matches[2] }
                else { Write-Json $res 503 @{ error = 'amisad-core IP unresolved; restart with -CoreIp <ip>' } }
            } elseif ($path -match '^/api/(edge-a|edge-b)(/.*)$') {
                $ip = if ($Matches[1] -eq 'edge-a') { $EdgeAIp } else { $EdgeBIp }
                if ($ip) { Invoke-Proxy $req $res "http://${ip}:8080" $Matches[2] }
                else { Write-Json $res 503 @{ error = "$($Matches[1]) IP unresolved; restart with -Edge$(($Matches[1][5]).ToString().ToUpper())Ip <ip>" } }
            } else {
                Send-StaticFile $res $path
            }
            Write-Information "$($req.HttpMethod) $path -> $($res.StatusCode)" -InformationAction Continue
        } catch {
            try { Write-Json $res 500 @{ error = $_.Exception.Message } } catch {}
            Write-Warning "$($req.HttpMethod) $($req.Url.AbsolutePath) failed: $($_.Exception.Message)"
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    $http.Dispose()
}
