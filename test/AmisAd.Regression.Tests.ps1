<#PSScriptInfo
.VERSION 2026.10.04
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

# The core->edge SSH key. The private half is generated inside vm-core and never
# leaves it; the host reads only the public half and writes it into the edges over
# the harness SSH channel. These cases pin the parts of that hand-off that a wrong
# edit would silently break: what is accepted from a guest, what an edge is told to
# do, what the driver does when a step fails, and that nothing private is read.
Describe 'AmisAd demo key hand-off' {
    BeforeAll {
        # A real ed25519 public key and the fingerprint ssh-keygen -l prints for it.
        $script:PublicLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuJrt/8WhXzBmDf0aFbjuT8mVlK/UqFz1dYvOQddkes amisad-demo'
        $script:Fingerprint = 'SHA256:MIBWBfQogPtFXPwhbwxswZaC3X/QgcOA+EHWOOgYQeM'
        $script:OtherLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMXDzPQHGoQt3kLvzKj5yG2cE1yBC0w0pGZ0pTgLq1Jm harness'
        $script:FakePrivate = "-----BEGIN OPENSSH PRIVATE KEY-----`nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW`n-----END OPENSSH PRIVATE KEY-----"
    }

    Context 'what a guest may hand back' {
        It 'rebuilds one ed25519 line with the fixed comment' {
            ConvertTo-AmisAdDemoPublicKey -Text "$($script:PublicLine)`n" | Should -Be $script:PublicLine
            ConvertTo-AmisAdDemoPublicKey -Text ($script:PublicLine -replace ' amisad-demo$', ' someone@laptop') | Should -Be $script:PublicLine
            ConvertTo-AmisAdDemoPublicKey -Text ($script:PublicLine -replace ' amisad-demo$', '') | Should -Be $script:PublicLine
        }

        It 'refuses <Case> and builds nothing from it' -TestCases @(
            @{ Case = 'a private key block'; Text = "-----BEGIN OPENSSH PRIVATE KEY-----`nb3BlbnNzaC1rZXktdjEAAAAA`n-----END OPENSSH PRIVATE KEY-----" }
            @{ Case = 'nothing'; Text = '' }
            @{ Case = 'two keys'; Text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuJrt/8WhXzBmDf0aFbjuT8mVlK/UqFz1dYvOQddkes a`nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMXDzPQHGoQt3kLvzKj5yG2cE1yBC0w0pGZ0pTgLq1Jm b" }
            @{ Case = 'an RSA key'; Text = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 amisad-demo' }
            @{ Case = 'a truncated key'; Text = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuJrt amisad-demo' }
            @{ Case = 'shell metacharacters in the body'; Text = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI'; reboot; echo '0123456789012345678901234567890123 amisad-demo" }
            @{ Case = 'a key with a command option in front'; Text = 'command="reboot" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuJrt/8WhXzBmDf0aFbjuT8mVlK/UqFz1dYvOQddkes amisad-demo' }
        ) {
            param($Case, $Text)
            $null = $Case
            $arguments = @{ Text = $Text }
            { ConvertTo-AmisAdDemoPublicKey @arguments } | Should -Throw
        }

        It 'prints the fingerprint ssh-keygen prints' {
            Get-AmisAdKeyFingerprint -PublicKey $script:PublicLine | Should -Be $script:Fingerprint
        }
    }

    Context 'what an edge is told to do' {
        BeforeAll {
            $script:Bash = Get-Command bash -ErrorAction SilentlyContinue
            function Invoke-AuthorizeFixture {
                param([string]$Command, [AllowNull()][string]$Existing)
                $work = Join-Path $script:FixtureRoot ('authorize-' + [guid]::NewGuid().ToString('N'))
                $ssh = Join-Path $work 'home/.ssh'
                [void](New-Item -ItemType Directory -Path $ssh -Force)
                if ($null -ne $Existing) { [IO.File]::WriteAllText((Join-Path $ssh 'authorized_keys'), $Existing, [Text.UTF8Encoding]::new($false)) }
                Push-Location $work
                try {
                    # HOME is set inside bash from a relative path, so no host path has to
                    # mean the same thing to the shell and to PowerShell.
                    $output = & $script:Bash.Source -c ('HOME="$PWD/home"; export HOME; ' + $Command) 2>&1
                    $code = $LASTEXITCODE
                } finally { Pop-Location }
                [pscustomobject]@{
                    Code = $code; Output = ($output -join "`n")
                    Keys = Join-Path $ssh 'authorized_keys'; Dir = $ssh
                    Lines = @(if (Test-Path -LiteralPath (Join-Path $ssh 'authorized_keys')) { [IO.File]::ReadAllLines((Join-Path $ssh 'authorized_keys')) })
                }
            }
        }

        It 'carries the public key and nothing private' {
            $command = Get-AmisAdAuthorizeKeyCommand -PublicKey $script:PublicLine
            $command | Should -Match ([regex]::Escape($script:PublicLine))
            $command | Should -Not -Match 'PRIVATE KEY'
            $command | Should -Not -Match 'amisad-demo-key'
            $command | Should -Not -Match "`n"
        }

        It 'will not build a command from text that is not a public key' {
            { Get-AmisAdAuthorizeKeyCommand -PublicKey $script:FakePrivate } | Should -Throw
            { Get-AmisAdAuthorizeKeyCommand -PublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI'; reboot; '0123456789012345678901234567890123" } | Should -Throw
        }

        It 'drops whatever comment the guest put after the key rather than passing it on' {
            $command = Get-AmisAdAuthorizeKeyCommand -PublicKey ($script:PublicLine -replace ' amisad-demo$', " x'; reboot; '")
            $command | Should -Not -Match 'reboot'
            $command | Should -Match ([regex]::Escape("'$($script:PublicLine)'"))
        }

        It 'trusts exactly the key it was given, once, keeping the keys it did not write' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
            $command = Get-AmisAdAuthorizeKeyCommand -PublicKey $script:PublicLine
            $stale = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLD amisad-demo'
            $first = Invoke-AuthorizeFixture -Command $command -Existing "$($script:OtherLine)`n$stale`n"
            $first.Code | Should -Be 0 -Because $first.Output
            $first.Lines | Should -Be @($script:OtherLine, $script:PublicLine)
            # A second pass changes nothing: no duplicate, no reordering.
            $again = Invoke-AuthorizeFixture -Command $command -Existing ($first.Lines -join "`n")
            $again.Code | Should -Be 0 -Because $again.Output
            $again.Lines | Should -Be @($script:OtherLine, $script:PublicLine)
        }

        It 'creates the directory and file when the edge has neither' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
            $run = Invoke-AuthorizeFixture -Command (Get-AmisAdAuthorizeKeyCommand -PublicKey $script:PublicLine) -Existing $null
            $run.Code | Should -Be 0 -Because $run.Output
            $run.Lines | Should -Be @($script:PublicLine)
            if ($IsLinux -or $IsMacOS) {
                (Get-Item -LiteralPath $run.Dir).UnixMode | Should -Be 'drwx------'
                (Get-Item -LiteralPath $run.Keys).UnixMode | Should -Be '-rw-------'
            }
        }

        It 'keeps a key that has no trailing newline and still appends on its own line' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
            $run = Invoke-AuthorizeFixture -Command (Get-AmisAdAuthorizeKeyCommand -PublicKey $script:PublicLine) -Existing $script:OtherLine
            $run.Code | Should -Be 0 -Because $run.Output
            $run.Lines | Should -Be @($script:OtherLine, $script:PublicLine)
        }

        It 'leaves the old authorized_keys untouched when a step fails' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
            # awk is shadowed by a failing stand-in; the chain must stop before the move.
            $command = 'awk() { return 1; }; ' + (Get-AmisAdAuthorizeKeyCommand -PublicKey $script:PublicLine)
            $run = Invoke-AuthorizeFixture -Command $command -Existing "$($script:OtherLine)`n"
            $run.Code | Should -Not -Be 0
            $run.Lines | Should -Be @($script:OtherLine)
        }

        It 'builds the login proof from validated parts only' {
            Get-AmisAdEdgeLoginCommand -EdgeUser 'amisad-edge-a-admin' -EdgeAddress '192.168.122.5' |
                Should -Be 'ssh -i "$HOME/.ssh/amisad-demo-key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 amisad-edge-a-admin@192.168.122.5 true'
            { Get-AmisAdEdgeLoginCommand -EdgeUser 'x; reboot' -EdgeAddress '192.168.122.5' } | Should -Throw
            { Get-AmisAdEdgeLoginCommand -EdgeUser 'amisad-edge-a-admin' -EdgeAddress '1.2.3.4; reboot' } | Should -Throw
        }
    }

    Context 'the legacy key an earlier lab left in the served tree' {
        It 'deletes the private and public file, says so, and leaves other files alone' {
            $root = Join-Path $script:FixtureRoot ('legacy-' + [guid]::NewGuid().ToString('N'))
            $handoff = Join-Path $root 'test/status/handoff'
            [void](New-Item -ItemType Directory -Path $handoff -Force)
            Set-Content -LiteralPath (Join-Path $handoff 'amisad-demo-key') -Value 'synthetic'
            Set-Content -LiteralPath (Join-Path $handoff 'amisad-demo-key.pub') -Value 'synthetic'
            Set-Content -LiteralPath (Join-Path $handoff 'keep.txt') -Value 'unrelated'
            $lines = @(Remove-LegacyDemoKey -YurunaRoot $root)
            $lines.Count | Should -Be 2
            ($lines -join ' ') | Should -Match 'exposed'
            ($lines -join ' ') | Should -Match 'amisad-demo-key'
            Test-Path -LiteralPath (Join-Path $handoff 'amisad-demo-key') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $handoff 'amisad-demo-key.pub') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $handoff 'keep.txt') | Should -BeTrue
        }

        It 'removes the hand-off directory it emptied' {
            $root = Join-Path $script:FixtureRoot ('legacy-' + [guid]::NewGuid().ToString('N'))
            $handoff = Join-Path $root 'test/status/handoff'
            [void](New-Item -ItemType Directory -Path $handoff -Force)
            Set-Content -LiteralPath (Join-Path $handoff 'amisad-demo-key') -Value 'synthetic'
            @(Remove-LegacyDemoKey -YurunaRoot $root).Count | Should -Be 1
            Test-Path -LiteralPath $handoff | Should -BeFalse
        }

        It 'does nothing, and says nothing, on a host that never had one' {
            $root = Join-Path $script:FixtureRoot ('legacy-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $root -Force)
            @(Remove-LegacyDemoKey -YurunaRoot $root).Count | Should -Be 0
        }

        It 'deletes nothing under -WhatIf' {
            $root = Join-Path $script:FixtureRoot ('legacy-' + [guid]::NewGuid().ToString('N'))
            $handoff = Join-Path $root 'test/status/handoff'
            [void](New-Item -ItemType Directory -Path $handoff -Force)
            Set-Content -LiteralPath (Join-Path $handoff 'amisad-demo-key') -Value 'synthetic'
            $null = Remove-LegacyDemoKey -YurunaRoot $root -WhatIf
            Test-Path -LiteralPath (Join-Path $handoff 'amisad-demo-key') | Should -BeTrue
        }
    }

    Context 'the driver that moves the public half' {
        BeforeAll {
            $fixtureModule = Join-Path $script:FixtureRoot 'AmisAdKeyHostFixture.psm1'
            @'
$script:State = 'running'
$script:StartAccepted = $true
function Get-VMState { param([string]$VMName) $null = $VMName; return $script:State }
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VMName)
    if ($PSCmdlet.ShouldProcess($VMName, 'fixture start')) {
        if ($script:StartAccepted) { $script:State = 'running' }
        return @{ success = $script:StartAccepted; errorMessage = 'fixture refused to start' }
    }
}
function Set-KeyFixtureState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test double: sets two module variables.')]
    param([string]$State, [bool]$StartAccepted = $true)
    $script:State = $State
    $script:StartAccepted = $StartAccepted
}
Export-ModuleMember -Function Get-VMState, Start-VM, Set-KeyFixtureState
'@ | Set-Content -LiteralPath $fixtureModule
            Import-Module $fixtureModule -Global -Force

            # A guest double. Answers by what the command is; records every call.
            $script:Calls = [System.Collections.Generic.List[hashtable]]::new()
            $script:Answers = @{}
            $script:Guest = {
                param([string]$VMName, [string]$User, [string]$Command, [int]$TimeoutSeconds)
                $null = $TimeoutSeconds
                $script:Calls.Add(@{ VM = $VMName; User = $User; Command = $Command })
                $kind = if ($Command -eq 'true') { 'probe' }
                    elseif ($Command -like 'cat *amisad-demo-key.pub*') { 'read' }
                    elseif ($Command -like 'umask 077*') { 'authorize' }
                    elseif ($Command -like 'ssh -i *') { 'login' }
                    else { 'other' }
                $key = "$kind|$VMName"
                if ($script:Answers.ContainsKey($key)) { return $script:Answers[$key] }
                if ($script:Answers.ContainsKey($kind)) { return $script:Answers[$kind] }
                return @{ success = $true; exitCode = 0; output = '' }
            }
        }
        BeforeEach {
            $script:Calls.Clear()
            $script:Answers = @{ read = @{ success = $true; exitCode = 0; output = $script:PublicLine } }
            Set-KeyFixtureState -State 'running'
        }
        AfterAll { Remove-Module AmisAdKeyHostFixture -Force -ErrorAction SilentlyContinue }

        It 'reads the public key, authorizes both edges, then proves each login from the core' {
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 `
                -EdgeAddress @{ 'amisad-edge-a' = '192.0.2.11'; 'amisad-edge-b' = '192.0.2.12' } -Confirm:$false
            $result.Ok | Should -BeTrue -Because ($result.Lines -join "`n")
            $result.Fingerprint | Should -Be $script:Fingerprint
            ($script:Calls | ForEach-Object { "$($_.VM)/$($_.User)" }) | Should -Be @(
                'amisad-core/amisad-core-admin', 'amisad-core/amisad-core-admin',
                'amisad-edge-a/amisad-edge-a-admin', 'amisad-edge-b/amisad-edge-b-admin',
                'amisad-core/amisad-core-admin', 'amisad-core/amisad-core-admin')
            $script:Calls[2].Command | Should -Match ([regex]::Escape($script:PublicLine))
            $script:Calls[4].Command | Should -Match 'amisad-edge-a-admin@192\.0\.2\.11 true$'
            $script:Calls[5].Command | Should -Match 'amisad-edge-b-admin@192\.0\.2\.12 true$'
        }

        It 'reads only the public file and never copies the private key anywhere' {
            $null = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 -Confirm:$false
            foreach ($call in $script:Calls) {
                # The private path may appear only as the identity of the login proof, which
                # runs ON the core, and never as something to read out of it.
                if ($call.Command -match 'amisad-demo-key(?!\.pub)') {
                    $call.VM | Should -Be 'amisad-core'
                    $call.Command | Should -Match '^ssh -i "\$HOME/\.ssh/amisad-demo-key" '
                }
                $call.Command | Should -Not -Match '\b(scp|sftp|rsync)\b'
            }
        }

        It 'starts the core when it is not running, and stops when it will not start' {
            Set-KeyFixtureState -State 'off' -StartAccepted $false
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Reason | Should -Match 'did not start'
            $script:Calls.Count | Should -Be 0

            Set-KeyFixtureState -State 'off' -StartAccepted $true
            (Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 -Confirm:$false).Ok | Should -BeTrue
        }

        It 'fails when the core never answers SSH' {
            $script:Answers['probe'] = @{ success = $false; exitCode = 255; output = 'connection timed out' }
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 0 -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Reason | Should -Match 'did not answer SSH'
            ($script:Calls | Where-Object { $_.VM -ne 'amisad-core' }).Count | Should -Be 0
        }

        It 'touches no edge when the core cannot give up a public key (<Case>)' -TestCases @(
            @{ Case = 'the file is missing'; Output = 'cat: No such file or directory'; Success = $false }
            @{ Case = 'it holds a private key'; Output = "-----BEGIN OPENSSH PRIVATE KEY-----`nb3BlbnNzaC1rZXktdjEAAAAA`n-----END OPENSSH PRIVATE KEY-----"; Success = $true }
            @{ Case = 'it holds two keys'; Output = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIuJrt/8WhXzBmDf0aFbjuT8mVlK/UqFz1dYvOQddkes a`nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMXDzPQHGoQt3kLvzKj5yG2cE1yBC0w0pGZ0pTgLq1Jm b"; Success = $true }
        ) {
            param($Case, $Output, $Success)
            $null = $Case
            $script:Answers['read'] = @{ success = $Success; exitCode = $(if ($Success) { 0 } else { 1 }); output = $Output }
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 -Confirm:$false
            $result.Ok | Should -BeFalse
            ($script:Calls | Where-Object { $_.VM -like 'amisad-edge-*' }).Count | Should -Be 0
            # What came out of the guest is never echoed into the report.
            ($result.Lines -join "`n") | Should -Not -Match 'BEGIN OPENSSH PRIVATE KEY'
            ($result.Lines -join "`n") | Should -Not -Match 'b3BlbnNzaC1rZXk'
        }

        It 'stops at the first edge that cannot be authorized and names it' {
            $script:Answers['authorize|amisad-edge-a'] = @{ success = $false; exitCode = 255; output = 'Permission denied (publickey)' }
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Reason | Should -Match 'amisad-edge-a'
            ($script:Calls | Where-Object { $_.VM -eq 'amisad-edge-b' }).Count | Should -Be 0
            ($script:Calls | Where-Object { $_.Command -like 'ssh -i *' }).Count | Should -Be 0
        }

        It 'fails the warm-up when the core cannot log in to an edge with the key' {
            $script:Answers['login|amisad-core'] = @{ success = $false; exitCode = 255; output = 'Permission denied (publickey)' }
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 `
                -EdgeAddress @{ 'amisad-edge-a' = '192.0.2.11'; 'amisad-edge-b' = '192.0.2.12' } -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Reason | Should -Match 'cannot log in to amisad-edge-a'
        }

        It 'skips the login proof, loudly, for an edge with no known address' {
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 5 -Confirm:$false
            $result.Ok | Should -BeTrue
            ($result.Lines -join "`n") | Should -Match 'Skipped the login check for amisad-edge-a'
            ($script:Calls | Where-Object { $_.Command -like 'ssh -i *' }).Count | Should -Be 0
        }

        It 'does nothing under -WhatIf' {
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -WhatIf
            $result.Ok | Should -BeTrue
            $script:Calls.Count | Should -Be 0
        }
    }
}

# Keeping the private key out of every served tree is a property of the whole
# repository, not of one function, so it is held by reading the sources: a later
# edit that brings the old shape back (a key made on the host, a key fetched from
# the status service) fails here before it reaches a lab.
Describe 'AmisAd key handling policy' {
    BeforeAll {
        $script:Sources = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.sh', '*.yml', '*.py', '*.cjs' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|target|node_modules|dist)[\\/]' })
        $script:ThisTest = $PSCommandPath
        $script:LegacyPath = 'handoff' + '[/\\]' + 'amisad-demo-key'
        $script:UsersScript = 'ubuntu.server.24.amisad-core.users.sh'
    }

    It 'invokes ssh-keygen only inside vm-core, never from PowerShell' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:Sources | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $calls = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -like 'ssh-keygen*' }, $true)
            foreach ($call in $calls) { $offenders.Add("$($file.FullName):$($call.Extent.StartLineNumber)") }
        }
        foreach ($file in $script:Sources | Where-Object { $_.Extension -eq '.sh' -and $_.Name -ne $script:UsersScript }) {
            $hits = Select-String -LiteralPath $file.FullName -Pattern '\bssh-keygen\b' | Where-Object { $_.Line -notmatch '^\s*#' }
            foreach ($hit in $hits) { $offenders.Add("$($file.FullName):$($hit.LineNumber)") }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'generates the pair in the vm-core users step' {
        $users = $script:Sources | Where-Object { $_.Name -eq $script:UsersScript }
        $users | Should -Not -BeNullOrEmpty
        $text = Get-Content -LiteralPath $users.FullName -Raw
        $text | Should -Match 'ssh-keygen -q -t ed25519 -N '''' -C ''amisad-demo'' -f "\$DEMO_KEY"'
        $text | Should -Not -Match '\b(wget|curl|amisad_host_fetch)\b'
    }

    It 'never names the legacy served key path outside the tests that guard it' {
        $offenders = $script:Sources | Where-Object { $_.FullName -ne $script:ThisTest -and $_.Name -ne 'download_contracts.py' } |
            Select-String -Pattern $script:LegacyPath
        @($offenders | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) | Should -BeNullOrEmpty
    }

    It 'has no step that downloads anything key-shaped' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:Sources | Where-Object { $_.Extension -in '.sh', '.ps1', '.psm1', '.yml' -and $_.FullName -ne $script:ThisTest }) {
            foreach ($hit in (Select-String -LiteralPath $file.FullName -Pattern '(wget|curl|amisad_host_fetch|Invoke-WebRequest|Invoke-RestMethod|\bscp\b).*(amisad-demo|[-_.]key\b|id_ed25519|id_rsa)')) {
                if ($hit.Line -match '^\s*#') { continue }
                $offenders.Add("$($file.FullName):$($hit.LineNumber): $($hit.Line.Trim())")
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'leaves the scenarios that reach an edge reading the key from the admin home of vm-core' {
        $scenarios = @($script:Sources | Where-Object { $_.Name -match '^ubuntu\.server\.24\.amisad-core\.s\d{3}\..+\.sh$' })
        $scenarios.Count | Should -BeGreaterOrEqual 10
        $usingTheKey = 0
        foreach ($scenario in $scenarios) {
            $text = Get-Content -LiteralPath $scenario.FullName -Raw
            if ($text -notmatch 'amisad-demo-key') { continue }
            $usingTheKey++
            $text | Should -Match 'SSH_OPTS=\(-i "\$REAL_HOME/\.ssh/amisad-demo-key"' -Because $scenario.Name
        }
        $usingTheKey | Should -BeGreaterOrEqual 9 -Because 'the scenarios that start slice-runtime on an edge all log in with the key'
    }
}
