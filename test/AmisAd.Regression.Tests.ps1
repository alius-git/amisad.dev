<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42f1c95a-01eb-4f37-88ea-de8b8892d23d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad regression host demo
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

#requires -version 7
# Run with Invoke-Pester -Path test/AmisAd.Regression.Tests.ps1 (PowerShell 7, Pester 5).
# Fixtures never import a real vault or run Docker/VM commands.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $PSScriptRoot 'AmisAd.Lab.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'poc/demo/AmisAd.DemoHost.psm1') -Force -DisableNameChecking
    $script:FixtureRoot = Join-Path $TestDrive "framework with spaces and 'quotes'"
    [void](New-Item -ItemType Directory -Path $script:FixtureRoot)
    $script:Logs = Join-Path $script:FixtureRoot 'logs'
    [void](New-Item -ItemType Directory -Path $script:Logs)
}

Describe 'AmisAd child process boundaries' {
    BeforeAll {
        $script:Sweep = Join-Path $script:FixtureRoot 'sweep.ps1'
        @'
param([string[]]$Prefix)
ConvertTo-Json -InputObject ([ordered]@{ Prefix = $Prefix; Extra = $args }) -Compress |
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'prefixes.jsonl')
if ($Prefix[0] -eq 'fail-') { exit 17 }
exit 0
'@ | Set-Content -LiteralPath $script:Sweep
        $script:Sequence = Join-Path $script:FixtureRoot 'sequence.ps1'
        @'
param([string]$Sequence, [switch]$NoProjectClone, [switch]$NoConfigGate)
ConvertTo-Json -InputObject ([ordered]@{ Sequence = $Sequence; NoProjectClone = [bool]$NoProjectClone; NoConfigGate = [bool]$NoConfigGate }) -Compress
for ($i = 0; $i -lt 2000; $i++) {
    [Console]::Out.WriteLine('out:' + ('x' * 100))
    [Console]::Error.WriteLine('err:' + ('y' * 100))
}
exit 23
'@ | Set-Content -LiteralPath $script:Sequence
    }

    It 'delivers every cleanup prefix literally rather than as comma-bearing native arguments' {
        $result = @(Invoke-AmisAdCleanup -SweepScript $script:Sweep -Prefix @('amisad-', 'amisad.', 'test-') -LogDir $script:Logs)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 0
        $records = @(Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'prefixes.jsonl') | ConvertFrom-Json)
        ($records.Prefix -join '|') | Should -Be 'amisad-|amisad.|test-'
        foreach ($record in $records) {
            $record.Prefix.Count | Should -Be 1
            $record.Extra.Count | Should -Be 0
        }
    }

    It 'stops cleanup on child failure without invoking the remaining prefix' {
        $path = Join-Path $script:FixtureRoot 'prefixes.jsonl'
        Clear-Content -LiteralPath $path
        Invoke-AmisAdCleanup -SweepScript $script:Sweep -Prefix @('first-', 'fail-', 'never-') -LogDir $script:Logs | Should -Be 17
        $records = @(Get-Content -LiteralPath $path | ConvertFrom-Json)
        ($records.Prefix -join '|') | Should -Be 'first-|fail-'
    }

    It 'refuses an empty prefix before any sweep starts' {
        $path = Join-Path $script:FixtureRoot 'prefixes.jsonl'
        Clear-Content -LiteralPath $path
        { Invoke-AmisAdCleanup -SweepScript $script:Sweep -Prefix @('first-', ' ') -LogDir $script:Logs } | Should -Throw
        (Get-Content -LiteralPath $path -Raw) | Should -BeNullOrEmpty
    }

    It 'preserves paths and arguments with spaces while draining both output pipes' {
        $result = @(Invoke-AmisAdStage -Name 'test stage' -Sequence 'sequence with spaces' -HostType 'host.ubuntu.kvm' `
            -SequenceScript $script:Sequence -LogDir $script:Logs -NoProjectClone -NoConfigGate)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 23
        $output = @(Get-Content -LiteralPath (Join-Path $script:Logs 'test stage.out.log'))
        $record = $output[0] | ConvertFrom-Json
        $record.Sequence | Should -Be 'sequence with spaces'
        $record.NoProjectClone | Should -BeTrue
        $record.NoConfigGate | Should -BeTrue
        $output.Count | Should -Be 2001
        @(Get-Content -LiteralPath (Join-Path $script:Logs 'test stage.err.log')).Count | Should -Be 2000
    }

    It 'keeps project cloning enabled when the caller has not opted out' {
        Invoke-AmisAdStage -Name 'default stage' -Sequence 'default' -HostType 'host.macos.utm' `
            -SequenceScript $script:Sequence -LogDir $script:Logs | Should -Be 23
        $record = Get-Content -LiteralPath (Join-Path $script:Logs 'default stage.out.log') -TotalCount 1 | ConvertFrom-Json
        $record.NoProjectClone | Should -BeFalse
        $record.NoConfigGate | Should -BeFalse
    }
}

Describe 'AmisAd shared VM start helper' {
    BeforeAll {
        $fixtureModule = Join-Path $script:FixtureRoot 'AmisAdFixtureHost.psm1'
        @'
$script:Accept = $true
$script:State = 'running'
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VMName)
    if ($PSCmdlet.ShouldProcess($VMName, 'fixture start')) {
        return @{ success = $script:Accept; errorMessage = 'fixture refused' }
    }
}
function Get-VMState {
    param([string]$VMName)
    $null = $VMName
    return $script:State
}
Export-ModuleMember -Function Start-VM, Get-VMState
'@ | Set-Content -LiteralPath $fixtureModule
        Import-Module $fixtureModule -Global -Force
    }

    AfterAll { Remove-Module AmisAdFixtureHost -Force }

    It 'finds the explicitly initialized global host contract from module scope' {
        $result = Start-VMConfirmed -Name 'fixture-vm' -Confirm:$false
        $result.started | Should -BeTrue
        $result.reason | Should -BeNullOrEmpty
    }

    It 'propagates a refused start rather than treating a status record as success' {
        & (Get-Module AmisAdFixtureHost) { $script:Accept = $false }
        $result = Start-VMConfirmed -Name 'fixture-vm' -Confirm:$false
        $result.started | Should -BeFalse
        $result.reason | Should -Be 'fixture refused'
    }

    It 'requires observed running state even when the start request succeeds' {
        & (Get-Module AmisAdFixtureHost) { $script:Accept = $true; $script:State = 'stopped' }
        $result = Start-VMConfirmed -Name 'fixture-vm' -RunningTimeoutSeconds 0 -Confirm:$false
        $result.started | Should -BeFalse
        $result.reason | Should -Match "VM is 'stopped'"
    }
}

Describe 'AmisAd demo module inputs' {
    BeforeAll {
        $vaultDir = Join-Path $script:FixtureRoot 'test/extension/authentication'
        [void](New-Item -ItemType Directory -Path $vaultDir -Force)
        @'
function Get-Password {
    param([string]$Username)
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'reads.txt') -Value $Username
    return "fixture:$Username"
}
Export-ModuleMember -Function Get-Password
'@ | Set-Content -LiteralPath (Join-Path $vaultDir 'default.psm1')
        $script:VaultReads = Join-Path $vaultDir 'reads.txt'
    }

    It 'uses the explicit root/personas from a caller scope and caches matching inputs' {
        $first = & {
            $root = $script:FixtureRoot
            $names = @('fixture-one', 'fixture-two')
            Get-PersonaSecret -YurunaRoot $root -Usernames $names
        }
        $first.Count | Should -Be 2
        $first[0].username | Should -Be 'fixture-one'
        $first[1].password | Should -Be 'fixture:fixture-two'
        $again = Get-PersonaSecret -YurunaRoot $script:FixtureRoot -Usernames @('fixture-one', 'fixture-two')
        $again.Count | Should -Be 2
        @(Get-Content -LiteralPath $script:VaultReads).Count | Should -Be 2
        $changed = Get-PersonaSecret -YurunaRoot $script:FixtureRoot -Usernames @('fixture-three')
        $changed.Count | Should -Be 1
        $changed[0].username | Should -Be 'fixture-three'
        @(Get-Content -LiteralPath $script:VaultReads).Count | Should -Be 3
        (ConvertTo-Json -InputObject $changed -Compress) | Should -Match '^\['
    }

    It 'returns unavailable records for a missing root without reusing another root cache' {
        $result = Get-PersonaSecret -YurunaRoot '' -Usernames @('fixture-three')
        $result.Count | Should -Be 1
        $result[0].password | Should -Match '^<vault error: framework checkout not located;'
        $result = Get-PersonaSecret -YurunaRoot (Join-Path $script:FixtureRoot 'missing') -Usernames @('fixture-three')
        $result[0].password | Should -Match '^<vault error:'
        @(Get-Content -LiteralPath $script:VaultReads).Count | Should -Be 3
    }

    It 'uses the explicit root handoff when no host driver or environment override exists' {
        Mock Get-Command -ModuleName AmisAd.DemoHost -ParameterFilter { $Name -eq 'Get-VMIp' } -MockWith { $null }
        $handoff = Join-Path $script:FixtureRoot 'test/status/log/handoff'
        [void](New-Item -ItemType Directory -Path $handoff -Force)
        Set-Content -LiteralPath (Join-Path $handoff 'fixture-vm.ip.txt') -Value '192.0.2.15'
        $previous = $env:YURUNA_LOG_DIR
        try {
            $env:YURUNA_LOG_DIR = $null
            Resolve-VmIp -Name 'fixture-vm' -YurunaRoot $script:FixtureRoot | Should -Be '192.0.2.15'
        } finally { $env:YURUNA_LOG_DIR = $previous }
    }
}

Describe 'AmisAd image failure propagation' {
    BeforeAll {
        $script:ImagesWrapper = Join-Path $script:FixtureRoot 'images-wrapper.ps1'
        @'
param([string]$ImagesScript, [switch]$FailLastPush)
$ErrorActionPreference = 'Stop'
function docker {
    $global:LASTEXITCODE = if ($FailLastPush -and $args[0] -eq 'push' -and $args[1] -like '*slice-runtime:latest') { 17 } else { 0 }
}

& $ImagesScript -Push -Registry review.invalid
'@ | Set-Content -LiteralPath $script:ImagesWrapper
    }

    It 'fails the real image script when the final push fails' {
        $out = Join-Path $script:Logs 'images.out.log'
        $err = Join-Path $script:Logs 'images.err.log'
        $arguments = @('-ImagesScript', (Join-Path $script:RepoRoot 'poc/build/images.ps1'), '-FailLastPush')
        Invoke-AmisAdScript -ScriptPath $script:ImagesWrapper -ScriptArguments $arguments -OutputPath $out -ErrorPath $err | Should -Be 1
        (Get-Content -LiteralPath $out -Raw) | Should -Not -Match 'images OK'
        (Get-Content -LiteralPath $err -Raw) | Should -Match 'docker push failed for slice-runtime'
    }

    It 'still succeeds when every mocked build and push succeeds' {
        $out = Join-Path $script:Logs 'images-success.out.log'
        $err = Join-Path $script:Logs 'images-success.err.log'
        $arguments = @('-ImagesScript', (Join-Path $script:RepoRoot 'poc/build/images.ps1'))
        Invoke-AmisAdScript -ScriptPath $script:ImagesWrapper -ScriptArguments $arguments -OutputPath $out -ErrorPath $err | Should -Be 0
        (Get-Content -LiteralPath $out -Raw) | Should -Match 'images OK - 11 images built and pushed'
    }
}

Describe 'AmisAd proxy resource lifetime' {
    BeforeAll {
        if (-not ('AmisAdFixtureHandler' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class AmisAdFixtureContent : StringContent {
    public bool WasDisposed;
    public AmisAdFixtureContent() : base("fixture response", Encoding.UTF8, "application/json") { }
    protected override void Dispose(bool disposing) { WasDisposed = true; base.Dispose(disposing); }
}
public sealed class AmisAdFixtureHandler : HttpMessageHandler {
    public HttpRequestMessage Request;
    public string RequestBody;
    public readonly AmisAdFixtureContent Content = new AmisAdFixtureContent();
    public bool Fail;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Request = request;
        RequestBody = request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        if (Fail) return Task.FromException<HttpResponseMessage>(new HttpRequestException("fixture failure"));
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Gone) { Content = Content });
    }
}
'@
        }
    }

    It 'preserves POST payload/status and disposes both messages in <Server>' -TestCases @(
        @{ Server = 'by-act' }, @{ Server = 'data-view' }
    ) {
        param($Server)
        $sourcePath = Join-Path $script:RepoRoot "poc/demo/$Server/serve-$Server.ps1"
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        $functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Invoke-Proxy', 'Read-RequestBody') }, $false)
        foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
        $handler = [AmisAdFixtureHandler]::new()
        $http = [Net.Http.HttpClient]::new($handler)
        $requestBodyStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"fixture":true}'))
        $request = [pscustomobject]@{ HasEntityBody = $true; InputStream = $requestBodyStream; ContentEncoding = [Text.Encoding]::UTF8; HttpMethod = 'POST'; Url = [uri]'http://localhost/?fixture=1' }
        $output = [IO.MemoryStream]::new()
        $response = [pscustomobject]@{ StatusCode = 0; ContentType = ''; ContentLength64 = 0; Headers = @{}; OutputStream = $output }
        try {
            Invoke-Proxy -Request $request -Response $response -TargetBase 'http://fixture.invalid' -Rest '/example'
            $response.StatusCode | Should -Be 410
            [Text.Encoding]::UTF8.GetString($output.ToArray()) | Should -Be 'fixture response'
            $handler.Request.RequestUri.AbsoluteUri | Should -Be 'http://fixture.invalid/example?fixture=1'
            $handler.RequestBody | Should -Be '{"fixture":true}'
            $handler.Content.WasDisposed | Should -BeTrue
            { $handler.Request.Content.ReadAsStringAsync().GetAwaiter().GetResult() } | Should -Throw
            $requestBodyStream.CanRead | Should -BeFalse
        } finally {
            $http.Dispose(); $requestBodyStream.Dispose(); $output.Dispose()
        }
    }

    It 'still disposes the outgoing request when <Server> cannot send it' -TestCases @(
        @{ Server = 'by-act' }, @{ Server = 'data-view' }
    ) {
        param($Server)
        $sourcePath = Join-Path $script:RepoRoot "poc/demo/$Server/serve-$Server.ps1"
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        $functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Invoke-Proxy', 'Read-RequestBody') }, $false)
        foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
        $handler = [AmisAdFixtureHandler]::new()
        $handler.Fail = $true
        $http = [Net.Http.HttpClient]::new($handler)
        $requestBodyStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"fixture":true}'))
        $request = [pscustomobject]@{ HasEntityBody = $true; InputStream = $requestBodyStream; ContentEncoding = [Text.Encoding]::UTF8; HttpMethod = 'POST'; Url = [uri]'http://localhost/' }
        $output = [IO.MemoryStream]::new()
        $response = [pscustomobject]@{ StatusCode = 0; ContentType = ''; ContentLength64 = 0; Headers = @{}; OutputStream = $output }
        try {
            Invoke-Proxy -Request $request -Response $response -TargetBase 'http://fixture.invalid' -Rest '/example'
            $response.StatusCode | Should -Be 502
            { $handler.Request.Content.ReadAsStringAsync().GetAwaiter().GetResult() } | Should -Throw
        } finally {
            $http.Dispose(); $handler.Content.Dispose(); $requestBodyStream.Dispose(); $output.Dispose()
        }
    }
}
