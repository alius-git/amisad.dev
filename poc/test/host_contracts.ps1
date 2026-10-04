<#PSScriptInfo
.VERSION 2026.10.11
.GUID 423b0429-a6bf-4b76-884e-a2931b3a7781
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc test host contracts
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The contracts shadow Start-Process and Test-Path with recording doubles.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The doubles stand in for cmdlets and external tools and only record the call.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A double accepts the parameters of the command it replaces and ignores them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'firewall-cmd is an external tool that the contracts double by name.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Read-Functions reads several function definitions from a source file.')]
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root=Split-Path $PSScriptRoot -Parent
# --- REGION: Read-Functions
function Read-Functions($Path,$Names) {
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$null)
    ($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Names}.GetNewClosure(),$true) | ForEach-Object {$_.Extent.Text}) -join "`n"
}
$count=0
# --- REGION: Assert-Contract
function Assert-Contract($Condition,$Message) { if (-not $Condition) {throw $Message};$script:count++ }
. ([scriptblock]::Create((Read-Functions (Join-Path $root 'demo/AmisAd.DemoHost.psm1') @('Invoke-DemoNativeCommand','Add-DemoFirewallRuleLinux','Add-DemoFirewallRuleWindows','Add-DemoFirewallRuleMacOS'))))
# --- REGION: Test-DemoAdministrator
function Test-DemoAdministrator { $script:admin }
# --- REGION: ufw
function ufw { $script:nativeCalls+=,@($args);$global:LASTEXITCODE=$script:nativeExit; if ($args[0] -eq 'status') {'Status: active'} }
# --- REGION: sudo
function sudo { $script:sudoCalls++;$program=$args[0];$rest=$args[1..($args.Count-1)]; & $program @rest }
foreach ($admin in @($true,$false)) {
    $script:admin=$admin
    foreach ($exitCode in @(0,13)) {
        $script:nativeExit=$exitCode;$script:nativeCalls=@();$script:sudoCalls=0
        $actual=Add-DemoFirewallRuleLinux -Port 18080 -Confirm:$false
        Assert-Contract ($actual -eq ($exitCode -eq 0)) 'ufw failure reported success'
        Assert-Contract ($admin -or $script:sudoCalls -gt 0) 'Nonroot status was not elevated'
        if ($exitCode -ne 0) { Assert-Contract ($script:nativeCalls.Count -eq 1) 'Mutation attempted after failed status' }
    }
}
# --- REGION: ufw
function ufw { $global:LASTEXITCODE=0;'Status: inactive' }
# --- REGION: firewall-cmd
function firewall-cmd { $global:LASTEXITCODE=$script:nativeExit;if ($args[0] -eq '--state') {'running'} }
$script:admin=$true
foreach ($exitCode in @(0,13)) {
    $script:nativeExit=$exitCode
    Assert-Contract ((Add-DemoFirewallRuleLinux -Port 18080 -Confirm:$false) -eq ($exitCode -eq 0)) 'firewalld exit ignored'
}
Remove-Item function:firewall-cmd
# --- REGION: Get-NetFirewallRule
function Get-NetFirewallRule { param($DisplayName,$ErrorAction) @{DisplayName=$DisplayName} }
# --- REGION: New-NetFirewallRule
function New-NetFirewallRule { throw 'Existing rule must not be recreated' }
# --- REGION: netsh
function netsh { if ($args[1] -eq 'show') {$global:LASTEXITCODE=1} else {$script:reserved++;$global:LASTEXITCODE=$script:nativeExit} }
foreach ($exitCode in @(0,5)) {
    $script:reserved=0;$script:nativeExit=$exitCode
    Assert-Contract ((Add-DemoFirewallRuleWindows -Port 18080 -RuleName 'fixture' -Confirm:$false) -eq ($exitCode -eq 0)) 'URL ACL failure ignored'
    Assert-Contract ($script:reserved -eq 1) 'Existing firewall rule prevented URL reservation'
}
# --- REGION: Start-Process
function Start-Process { param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru,$WindowStyle) @{ExitCode=5} }
$script:admin=$false
Assert-Contract (-not (Add-DemoFirewallRuleWindows -Port 18080 -RuleName 'fixture' -Confirm:$false)) 'Elevation failure ignored'
# --- REGION: Test-Path
function Test-Path { param($LiteralPath) $true }
# --- REGION: Invoke-DemoNativeCommand
function Invoke-DemoNativeCommand { param($FilePath,[string[]]$ArgumentList,[switch]$Elevated) if ($ArgumentList[0] -eq '--getglobalstate') {'Firewall is enabled'} elseif ($script:nativeExit -ne 0) {throw 'native denied'} }
foreach ($exitCode in @(0,5)) {
    $script:nativeExit=$exitCode
    Assert-Contract ((Add-DemoFirewallRuleMacOS -Confirm:$false) -eq ($exitCode -eq 0)) 'macOS exit ignored'
}
. ([scriptblock]::Create((Read-Functions (Join-Path $root 'build/doctor.ps1') @('Test-Tool'))))
# --- REGION: fakeBad
function fakeBad { $global:LASTEXITCODE=8;'tool 99.0.0' }
# --- REGION: fakeThrow
function fakeThrow { throw 'not executable' }
# --- REGION: fakeGood
function fakeGood { $global:LASTEXITCODE=0;$script:versionText }
foreach ($probe in @(
    @{Name='bazel';Candidates=@('fakeBad','fakeThrow','fakeGood');Version='tool 7.7.1';Fails=0},
    @{Name='bazel';Candidates=@('fakeBad');Version='tool 7.7.1';Fails=1},
    @{Name='rust';Candidates=@('fakeGood');Version='cargo 1.95.0';Fails=1},
    @{Name='rust';Candidates=@('fakeGood');Version='cargo 1.96.1';Fails=0},
    @{Name='node';Candidates=@('fakeGood');Version='v22.11.0';Fails=1},
    @{Name='node';Candidates=@('fakeGood');Version='v22.12.0';Fails=0},
    @{Name='node';Candidates=@('fakeGood');Version='v20.19.0';Fails=0}
)) {
    $script:failures=@();$script:versionText=$probe.Version
    Test-Tool -Name $probe.Name -Candidates $probe.Candidates -VersionArgs '--version' -Required $true -Hint 'fixture'
    Assert-Contract ($script:failures.Count -eq $probe.Fails) 'Doctor accepted an unusable tool'
}
"Host contracts: $count assertions passed; all platform commands are fixtures."
