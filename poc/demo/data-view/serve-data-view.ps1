<#PSScriptInfo
.VERSION 2026.07.28
.GUID 7c1e5a92-4d3b-4f88-a0e6-2b9d7c41f503
.AUTHOR Alisson Sol et al.
.Copyright (c) 2026 by Alisson Sol et al.
.TAGS amisad poc demo data view serve
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# AmisAd data-view demo server (host-side). Serves two synchronized browser
# windows - the persona action timeline and the live backend data view - plus
# the slide deck, and proxies browser API calls to the amisad-core NodePorts
# and the edge slice-runtimes (the POC services send no CORS headers, so the
# browser cannot call them cross-origin; same-origin via this proxy needs
# none). It changes nothing on the VMs beyond the API calls the operator
# clicks, and requires no change to the deployed topology.
#
# The journal (/api/journal) is the synchronization bus: the action window
# appends step events, every window polls them, so any number of viewers on
# any machine reconstruct the same timeline. It is in-memory only - a restart
# clears it, and clients detect that from a sequence number going backwards.
#
# Serves the network by default so the lab host can drive a console shown on a
# projector while the presenter works from a laptop or tablet; the vault
# passwords on /api/personas stay loopback-only regardless, until
# -SharePersonaPasswords says otherwise.
param(
    [int]$Port = 8092,
    [string]$YurunaRoot,
    [string]$CoreIp = '',
    [string]$EdgeAIp = '',
    [string]$EdgeBIp = '',
    # 'any' (default) for every interface, 'localhost' for this machine only,
    # or one hostname/IP to bind a single NIC.
    [string]$BindAddress = 'any',
    [switch]$SharePersonaPasswords,
    # Skip the inbound-port firewall rule (and, on Windows, the http.sys
    # reservation) when the port is already open or policy forbids it.
    [switch]$SkipFirewall
)
$ErrorActionPreference = 'Stop'
$demoRoot = $PSScriptRoot
# Forward slashes in every framework-relative path: a literal '..\components\art'
# is one filename containing backslashes on Linux/macOS, and a 'c:\...' root is
# read as a PSDrive name there ("Cannot find drive").
$artRoot = [IO.Path]::GetFullPath((Join-Path $demoRoot '../../components/art'))
Import-Module ([IO.Path]::GetFullPath((Join-Path $demoRoot '../AmisAd.DemoHost.psm1'))) -Force

# Resolve-YurunaRoot discovers the framework checkout (explicit param ->
# YURUNA_ROOT -> YURUNA_CONFIG_PATH -> the clone layout -> a per-platform
# conventional path); Initialize-AmisAdHost imports the host driver so the
# unqualified Get-VMIp and Get-VMState below reach whichever hypervisor runs.
. ([IO.Path]::GetFullPath((Join-Path $demoRoot '../../../test/AmisAd.HostCommon.ps1')))
try {
    $YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
} catch {
    # Not fatal: both windows, the deck and the proxy all work without the
    # framework. Only the vault passwords, the VM power states and the
    # handoff-file IP fallback need it.
    Write-Warning "$($_.Exception.Message) Persona passwords will show as unavailable."
    $YurunaRoot = ''
}
if ($YurunaRoot) {
    try { $null = Initialize-AmisAdHost -YurunaRoot $YurunaRoot }
    catch { Write-Warning "Host driver unavailable ($($_.Exception.Message)); VM IPs fall back to the handoff files." }
}

$vmNames = 'amisad-core', 'amisad-edge-a', 'amisad-edge-b'

# VM IP resolution: explicit param -> the host driver's guest report -> the
# status service's handoff file (the edges' boot-time IP reporter posts
# <hostname>.ip.txt there).
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

# Power state comes from the host driver contract, which reports the same four
# values (absent/stopped/running/unknown) on KVM, Hyper-V and UTM - so the VM
# cards stay hypervisor-portable. Cached briefly because the browser polls it
# and the IP fallback chain can be slow when a guest has no lease.
$script:vmCache = $null
$script:vmCacheAt = [DateTime]::MinValue
function Get-VmReport {
    if ($script:vmCache -and ((Get-Date) - $script:vmCacheAt).TotalSeconds -lt 5) {
        return $script:vmCache
    }
    $haveState = [bool](Get-Command -Name 'Get-VMState' -ErrorAction SilentlyContinue)
    $ips = @{ 'amisad-core' = $CoreIp; 'amisad-edge-a' = $EdgeAIp; 'amisad-edge-b' = $EdgeBIp }
    $list = foreach ($n in $vmNames) {
        $vmState = 'unknown'
        if ($haveState) {
            try { $vmState = [string](Get-VMState -VMName $n) }
            catch { $vmState = 'unknown' }
        }
        [ordered]@{ name = $n; state = $vmState; ip = [string]$ips[$n] }
    }
    $script:vmCache = @($list)
    $script:vmCacheAt = Get-Date
    return $script:vmCache
}

# The coordinator derives a buyer's pseudonymous subject as
# sha256("<actor>|<class>|subject") truncated to 16 hex chars. Computing it
# here rather than in the browser keeps the data view working over plain http
# on a LAN address, where WebCrypto is unavailable outside a secure context.
function Get-SubjectHash([string]$Actor) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Actor|person|subject"))
        $hex = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
        return $hex.Substring(0, 16)
    } finally { $sha.Dispose() }
}

# Persona passwords come from the same vault the deploy chain rendered into
# chpasswd. After a green end-to-end run every entry exists, so Get-Password is
# a pure read here; a missing entry would mean the VM account never got that
# password either.
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

# The journal: append-only in memory, monotonic sequence. Clients poll with the
# highest seq they hold; a 'latest' lower than that tells them this process
# restarted and their view must be rebuilt from scratch.
$script:journal = [System.Collections.Generic.List[object]]::new()
$script:journalSeq = 0

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
$http.Timeout = [TimeSpan]::FromSeconds(30)

function Write-Body($Response, [int]$Status, [byte[]]$Bytes, [string]$ContentType) {
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}
function Write-Json($Response, [int]$Status, $Object, [int]$Depth = 8) {
    $Response.Headers['Cache-Control'] = 'no-store'
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Depth $Depth))
    Write-Body $Response $Status $bytes 'application/json'
}
function Read-RequestBody($Request) {
    if (-not $Request.HasEntityBody) { return '' }
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    return $reader.ReadToEnd()
}

# Forward one browser request to a lab endpoint, body and method intact, and
# relay the upstream status + body verbatim (non-2xx included: refusal statuses
# like 403/410 are demo evidence, not proxy errors). Reads get a short deadline
# of their own: the data view polls continuously, and one unreachable VM must
# not stall the single-threaded loop for the full client timeout.
function Invoke-Proxy($Request, $Response, [string]$TargetBase, [string]$Rest) {
    $uri = $TargetBase + $Rest + $Request.Url.Query
    $msg = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Request.HttpMethod), $uri)
    $body = Read-RequestBody $Request
    if ($body) {
        $msg.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    }
    $cts = $null
    try {
        if ($Request.HttpMethod -eq 'GET') {
            $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(8))
            $up = $http.SendAsync($msg, $cts.Token).GetAwaiter().GetResult()
        } else {
            $up = $http.SendAsync($msg).GetAwaiter().GetResult()
        }
        $text = $up.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $ct = if ($up.Content.Headers.ContentType) { $up.Content.Headers.ContentType.ToString() } else { 'application/json' }
        $Response.Headers['Cache-Control'] = 'no-store'
        Write-Body $Response ([int]$up.StatusCode) ([Text.Encoding]::UTF8.GetBytes($text)) $ct
    } catch {
        Write-Json $Response 502 @{ error = $_.Exception.Message; target = $uri }
    } finally {
        if ($cts) { $cts.Dispose() }
    }
}

# '' serves the action window and '/data' the data view; both are ordinary
# files under ui/, so everything else resolves as a normal static path.
function Send-StaticFile($Response, [string]$UrlPath) {
    $rel = $UrlPath.TrimStart('/')
    if ($rel -eq '') { $rel = 'ui/actions.html' }
    elseif ($rel -eq 'data') { $rel = 'ui/data.html' }
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

$servesNetwork = $BindAddress -ne 'localhost'
if ($servesNetwork -and -not $SkipFirewall) {
    $null = Add-DemoFirewallRule -Port $Port -RuleName "AmisAd data-view demo ($Port)"
}
$listener = New-DemoListener -Port $Port -BindAddress $BindAddress

# Lead with the address someone can actually type on another machine: a
# localhost URL is unusable on a projector or read out to a person holding a
# tablet.
$hostIp = if ($servesNetwork) { Get-DemoHostIp } else { 'localhost' }
$base = "http://${hostIp}:$Port"
Write-Information 'AmisAd data-view demo' -InformationAction Continue
Write-Information "  actions: $base/     data: $base/data     slides: $base/slides.html" -InformationAction Continue
if ($servesNetwork) {
    $others = @(Get-DemoHostIpList | Where-Object { $_ -ne $hostIp })
    if ($others) {
        Write-Information "  also on: $(($others | ForEach-Object { "http://${_}:$Port/" }) -join '  ')" -InformationAction Continue
    }
    Write-Information "  on this machine: http://localhost:$Port/" -InformationAction Continue
} else {
    Write-Information '  loopback only - drop -BindAddress localhost to serve the network.' -InformationAction Continue
}
if ($servesNetwork -and $SharePersonaPasswords) {
    Write-Warning "-SharePersonaPasswords: the vault passwords on /api/personas are served in the clear to ANY machine that can reach port $Port."
}
Write-Information "Topology: core=$(if ($CoreIp) { $CoreIp } else { '<unresolved>' })  edge-a=$(if ($EdgeAIp) { $EdgeAIp } else { '<unresolved>' })  edge-b=$(if ($EdgeBIp) { $EdgeBIp } else { '<unresolved>' })" -InformationAction Continue
Write-Information "Framework: $(if ($YurunaRoot) { $YurunaRoot } else { '<not located>' })" -InformationAction Continue
if (-not $CoreIp) {
    Write-Warning 'amisad-core IP not resolved (host driver + handoff both empty) - pass -CoreIp; API calls will fail until then.'
}
$keyStop = Enable-DemoStopKey
Write-Information $(if ($keyStop) { 'Press Ctrl+C, End or Q to stop.' } else { 'Press Ctrl+C to stop.' }) -InformationAction Continue
try {
    # GetContextAsync rather than GetContext: a thread parked in the blocking
    # call cannot be interrupted, which is what makes a naive listener
    # stoppable only by killing the terminal. Polling the task leaves room to
    # notice a stop key - and lets PowerShell act on a real Ctrl+C - between
    # requests.
    $pending = $listener.GetContextAsync()
    while ($listener.IsListening) {
        if ($keyStop -and (Test-DemoStopKey)) {
            Write-Information 'Stopping.' -InformationAction Continue
            break
        }
        try {
            if (-not $pending.Wait(250)) { continue }
        } catch {
            break   # the listener was stopped underneath us
        }
        $ctx = $pending.Result
        $pending = $listener.GetContextAsync()
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
            } elseif ($path -eq '/api/vms') {
                Write-Json $res 200 (Get-VmReport)
            } elseif ($path -eq '/api/subjects') {
                Write-Json $res 200 ([ordered]@{ maya = (Get-SubjectHash 'maya'); pat = (Get-SubjectHash 'pat') })
            } elseif ($path -eq '/api/journal/reset') {
                # The sequence keeps climbing so a client that missed the reset
                # still sees its cursor overtaken rather than silently reused.
                $script:journal.Clear()
                $seq = ++$script:journalSeq
                $entry = [ordered]@{
                    kind = 'reset'
                    seq  = $seq
                    ts   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                }
                $script:journal.Add([pscustomobject]$entry)
                Write-Json $res 200 @{ ok = $true; seq = $seq }
            } elseif ($path -eq '/api/journal') {
                if ($req.HttpMethod -eq 'POST') {
                    $raw = Read-RequestBody $req
                    $obj = $null
                    try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null }
                    if ($null -eq $obj) {
                        Write-Json $res 400 @{ error = 'journal event must be a JSON object' }
                    } else {
                        $seq = ++$script:journalSeq
                        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        $obj | Add-Member -NotePropertyName 'seq' -NotePropertyValue $seq -Force
                        $obj | Add-Member -NotePropertyName 'ts' -NotePropertyValue $ts -Force
                        $script:journal.Add($obj)
                        Write-Json $res 201 @{ seq = $seq; ts = $ts }
                    }
                } else {
                    $since = 0
                    $sinceRaw = $req.QueryString['since']
                    if ($sinceRaw) { [void][int]::TryParse($sinceRaw, [ref]$since) }
                    $events = @($script:journal | Where-Object { $_.seq -gt $since })
                    Write-Json $res 200 ([ordered]@{ latest = $script:journalSeq; events = $events }) 12
                }
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
        } catch {
            try { Write-Json $res 500 @{ error = $_.Exception.Message } } catch {}
            Write-Warning "$($req.HttpMethod) $($req.Url.AbsolutePath) failed: $($_.Exception.Message)"
        }
    }
} finally {
    Disable-DemoStopKey
    $listener.Stop()
    $listener.Close()
    $http.Dispose()
    Write-Information 'AmisAd data-view demo stopped.' -InformationAction Continue
}
