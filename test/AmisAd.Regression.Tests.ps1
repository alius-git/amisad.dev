<#PSScriptInfo
.VERSION 2026.10.28
.GUID 42f1c95a-01eb-4f37-88ea-de8b8892d23d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad regression host demo
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

#requires -version 7
# Run with Invoke-Pester -Path test/AmisAd.Regression.Tests.ps1 (PowerShell 7, Pester 6).
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

Describe 'AmisAd guest deployment contracts' {
    BeforeAll {
        $script:ContractPython = $null
        foreach ($candidate in @(Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($candidate.Source -match '[\\/]WindowsApps[\\/]') { continue }
            $probe = [Diagnostics.Process]::new()
            $started = $false
            try {
                $probe.StartInfo = [Diagnostics.ProcessStartInfo]::new()
                $probe.StartInfo.FileName = $candidate.Source
                $probe.StartInfo.UseShellExecute = $false
                $probe.StartInfo.RedirectStandardOutput = $true
                $probe.StartInfo.RedirectStandardError = $true
                $probe.StartInfo.ArgumentList.Add('-c')
                $probe.StartInfo.ArgumentList.Add('import sys; print(sys.version_info[0])')
                $started = $probe.Start()
                if ($started -and $probe.WaitForExit(5000) -and $probe.ExitCode -eq 0 -and
                    $probe.StandardOutput.ReadToEnd().Trim() -eq '3') {
                    $script:ContractPython = $candidate.Source
                    break
                }
            } catch {
                # A launcher or unavailable alias is not a usable interpreter.
                $script:ContractPython = $null
            } finally {
                if ($started -and -not $probe.HasExited) { $probe.Kill($true) }
                $probe.Dispose()
            }
        }
    }

    It 'passes the native <Suite> contracts' -TestCases @(
        @{ Suite = 'bash_contracts.py' }
        @{ Suite = 'cluster_ready_contracts.py' }
        @{ Suite = 'image_import_contracts.py' }
        @{ Suite = 'slice_runtime_stop_contracts.py' }
    ) {
        param($Suite)
        if (-not $script:ContractPython) {
            Set-ItResult -Skipped -Because 'A runnable Python 3 interpreter is required.'
            return
        }
        $output = & $script:ContractPython -B (Join-Path $script:RepoRoot "poc/test/$Suite") -v 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
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
$script:Kind = ''
$script:ControlHung = $false
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VMName)
    if ($PSCmdlet.ShouldProcess($VMName, 'fixture start')) {
        $record = @{ success = $script:Accept; errorMessage = 'fixture refused' }
        if ($script:Kind) { $record['kind'] = $script:Kind; $record['controlHung'] = $script:ControlHung }
        return $record
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
        $result.kind | Should -Be 'not-running'
        $result.controlHung | Should -BeFalse
    }

    It 'reads the failure kind and the control verdict a driver puts in its record' {
        & (Get-Module AmisAdFixtureHost) { $script:Accept = $false; $script:State = 'stopped'; $script:Kind = 'apple-event'; $script:ControlHung = $true }
        try {
            $result = Start-VMConfirmed -Name 'fixture-vm' -Confirm:$false
            $result.started | Should -BeFalse
            $result.kind | Should -Be 'apple-event'
            $result.controlHung | Should -BeTrue
        } finally {
            & (Get-Module AmisAdFixtureHost) { $script:Kind = ''; $script:ControlHung = $false }
        }
    }

    It 'reads a record without those fields as an ordinary refusal' {
        & (Get-Module AmisAdFixtureHost) { $script:Accept = $false; $script:State = 'stopped' }
        $result = Start-VMConfirmed -Name 'fixture-vm' -Confirm:$false
        $result.kind | Should -Be 'none'
        $result.controlHung | Should -BeFalse
    }

    It 'preserves the VM identity, numeric error and capacity evidence from a refused start' {
        Mock Start-VM -ModuleName AmisAd.Lab -MockWith {
            @{ success = $false; errorMessage = 'C: cannot allocate 12 GiB'; kind = 'storage-capacity';
               errorCode = '0x80070070'; hostStorage = @{ status = 'insufficient'; requiredBytes = 12GB; freeBytes = 9GB };
               hostMemory = @{ availableBytes = 24GB } }
        }
        $result = Start-VMConfirmed -Name 'amisad-core' -Confirm:$false
        $result.started | Should -BeFalse
        $result.vmName | Should -Be 'amisad-core'
        $result.errorCode | Should -Be '0x80070070'
        $result.hostStorage.requiredBytes | Should -Be 12GB
        $result.hostStorage.freeBytes | Should -Be 9GB
        $result.hostMemory.availableBytes | Should -Be 24GB
    }

    It 'recognizes older driver <ErrorCode> without requiring new result fields' -ForEach @(
        @{ ErrorCode = '0x80070070' }
        @{ ErrorCode = '0x80070027' }
    ) {
        $script:DriverDiskFullCode = $ErrorCode
        Mock Start-VM -ModuleName AmisAd.Lab -MockWith {
            @{ success = $false; errorMessage = "The system could not allocate VMRS ($script:DriverDiskFullCode)." }
        }
        $result = Start-VMConfirmed -Name 'amisad-core' -Confirm:$false
        $result.started | Should -BeFalse
        $result.errorCode | Should -Be $ErrorCode
        $result.kind | Should -Be 'storage-capacity'
    }
}

Describe 'AmisAd edge admission' {
    It 'stops after numeric disk-full <ErrorCode> without a classified failure kind' -ForEach @(
        @{ ErrorCode = '0x80070070' }
        @{ ErrorCode = '0x80070027' }
    ) {
        $script:DriverDiskFullCode = $ErrorCode
        Mock Start-VMConfirmed -ModuleName AmisAd.Lab -MockWith {
            @{ started = $false; reason = 'VMRS volume full'; kind = 'none'; errorCode = $script:DriverDiskFullCode }
        }
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.State['amisad-edge-a'].Attempts | Should -Be 1
        $result.State['amisad-edge-a'].errorCode | Should -Be $ErrorCode
        $result.State['amisad-edge-b'].Attempts | Should -Be 0
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -Times 1 -Exactly
        Should -Invoke Start-Sleep -ModuleName AmisAd.Lab -Times 0 -Exactly
    }

    It 'stops after a storage refusal and preserves its evidence without blind retries' {
        Mock Start-VMConfirmed -ModuleName AmisAd.Lab -MockWith {
            @{ started = $false; reason = 'VMRS volume full'; kind = 'storage-capacity'; errorCode = '0x80070070';
               vmName = 'amisad-edge-a'; hostStorage = @{ status = 'insufficient'; freeBytes = 1GB } }
        }
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.State['amisad-edge-a'].Attempts | Should -Be 1
        $result.State['amisad-edge-a'].hostStorage.freeBytes | Should -Be 1GB
        $result.State['amisad-edge-b'].Attempts | Should -Be 0
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -Times 1 -Exactly
        Should -Invoke Start-Sleep -ModuleName AmisAd.Lab -Times 0 -Exactly
        $failure = Get-AmisAdEdgeFailure -EdgeStartup $result
        $failure.FailureClass | Should -Be 'provisioning_failure'
        $failure.DependencyFailures[0].errorCode | Should -Be '0x80070070'
        $failure.DependencyFailures[0].hostStorage.freeBytes | Should -Be 1GB
    }

    BeforeEach {
        $script:EdgeTrace = [System.Collections.Generic.List[string]]::new()
        Mock Start-VMConfirmed -ModuleName AmisAd.Lab -MockWith {
            param($Name)
            $script:EdgeTrace.Add("start:$Name")
            return @{ started = $true; reason = $null }
        }
        Mock Remove-Item -ModuleName AmisAd.Lab -MockWith { }
        Mock Start-Sleep -ModuleName AmisAd.Lab -MockWith { }
        Mock Test-Path -ModuleName AmisAd.Lab -MockWith { $true }
        Mock Get-Item -ModuleName AmisAd.Lab -MockWith {
            param($LiteralPath)
            $script:EdgeTrace.Add("report:$LiteralPath")
            return [pscustomobject]@{ LastWriteTime = (Get-Date).AddMinutes(1) }
        }
        Mock Get-Content -ModuleName AmisAd.Lab -MockWith {
            param($LiteralPath)
            if ($LiteralPath -like '*edge-b*') { return '192.0.2.12' }
            return '192.0.2.11'
        }
    }

    It 'starts both edges before waiting and returns their fresh addresses' {
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeTrue
        $result.Address['amisad-edge-a'] | Should -Be '192.0.2.11'
        $result.Address['amisad-edge-b'] | Should -Be '192.0.2.12'
        # When each report was written is kept for the failure evidence.
        $result.ReportedAt['amisad-edge-a'] | Should -Match 'Z$' -Because 'the report time is recorded in UTC'
        ($result.Lines -join "`n") | Should -Match 'amisad-edge-a reported 192\.0\.2\.11 at '
        $script:EdgeTrace[0] | Should -Be 'start:amisad-edge-a'
        $script:EdgeTrace[1] | Should -Be 'start:amisad-edge-b'
    }

    It 'retains the start failure and refuses admission when an edge never starts' {
        Mock Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-b' } -MockWith {
            return @{ started = $false; reason = 'fixture start denied' }
        }
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.Missing | Should -Contain 'amisad-edge-b'
        $result.State['amisad-edge-b'].Reason | Should -Be 'fixture start denied'
        $result.Address.ContainsKey('amisad-edge-b') | Should -BeFalse
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-b' } -Times 3 -Exactly
    }

    It 'rejects a stale, blank, or malformed report (<Case>)' -TestCases @(
        @{ Case = 'stale'; Stale = $true; Address = '192.0.2.11' }
        @{ Case = 'blank'; Stale = $false; Address = '' }
        @{ Case = 'malformed'; Stale = $false; Address = 'not an address' }
    ) {
        param($Case, $Stale, $Address)
        $null = @($Case, $Stale, $Address)
        Mock Get-Item -ModuleName AmisAd.Lab -MockWith {
            return [pscustomobject]@{ LastWriteTime = if ($Stale) { (Get-Date).AddHours(-1) } else { (Get-Date).AddMinutes(1) } }
        }.GetNewClosure()
        Mock Get-Content -ModuleName AmisAd.Lab -MockWith { return $Address }.GetNewClosure()
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.Missing.Count | Should -Be 2
        $result.Address.Count | Should -Be 0
    }

    It 'does not remove reports or start VMs during a rehearsal' {
        $null = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -WhatIf
        Should -Invoke Remove-Item -ModuleName AmisAd.Lab -Times 0 -Exactly
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -Times 0 -Exactly
    }

    It 'stops at a start that reports the control channel hung and skips the remaining edge' {
        Mock Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-a' } -MockWith {
            return @{ started = $false; reason = 'UTM control channel stopped acting'; kind = 'apple-event'; controlHung = $true }
        }
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.ControlHung | Should -BeTrue
        $result.HungEdge | Should -Be 'amisad-edge-a'
        $result.Missing | Should -Contain 'amisad-edge-a'
        $result.Missing | Should -Contain 'amisad-edge-b'
        $result.State['amisad-edge-a'].Kind | Should -Be 'apple-event'
        $result.State['amisad-edge-a'].Attempts | Should -Be 1
        $result.State['amisad-edge-b'].Reason | Should -Match 'not attempted.*amisad-edge-a'
        $result.State['amisad-edge-b'].Attempts | Should -Be 0
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-a' } -Times 1 -Exactly
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-b' } -Times 0 -Exactly
        ($result.Lines -join "`n") | Should -Match 'no further start is attempted'
    }

    It 'keeps retrying a refusal that does not report the channel hung' {
        Mock Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-b' } -MockWith {
            return @{ started = $false; reason = 'denied'; kind = 'apple-event'; controlHung = $false }
        }
        $result = Start-AmisAdEdge -LogRoot $script:Logs -ReadyTimeoutSeconds 0 -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.ControlHung | Should -BeFalse
        $result.State['amisad-edge-b'].Kind | Should -Be 'apple-event'
        $result.State['amisad-edge-b'].Attempts | Should -Be 3
        Should -Invoke Start-VMConfirmed -ModuleName AmisAd.Lab -ParameterFilter { $Name -eq 'amisad-edge-b' } -Times 3 -Exactly
    }
}

Describe 'AmisAd edge failure classification' {
    BeforeAll {
        function Get-EdgeStartupFixture {
            param([hashtable]$State, [string[]]$Missing, [bool]$ControlHung = $false, [string]$HungEdge = '')
            return @{ Ok = $false; State = $State; Address = @{}; Missing = $Missing; Lines = [string[]]@(); ControlHung = $ControlHung; HungEdge = $HungEdge }
        }
    }

    It 'files a hung control channel as hypervisor_unresponsive, naming the edge that saw it' {
        $startup = Get-EdgeStartupFixture -ControlHung $true -HungEdge 'amisad-edge-a' -Missing @('amisad-edge-a', 'amisad-edge-b') -State @{
            'amisad-edge-a' = @{ Started = $false; Ready = $false; Reason = 'control channel stopped acting'; Kind = 'apple-event'; Attempts = 1 }
            'amisad-edge-b' = @{ Started = $false; Ready = $false; Reason = 'not attempted: the hypervisor control channel stopped acting on start requests (reported for amisad-edge-a)'; Kind = 'apple-event'; Attempts = 0 }
        }
        $failure = Get-AmisAdEdgeFailure -EdgeStartup $startup
        $failure.FailureClass | Should -Be 'hypervisor_unresponsive'
        $failure.ErrorMessage | Should -Match 'first seen on amisad-edge-a'
        $failure.ErrorMessage | Should -Match 'amisad-edge-b \(not attempted'
        $failure.DependencyFailures.Count | Should -Be 2
        $failure.DependencyFailures[0].area | Should -Be 'amisad-edge'
        $failure.DependencyFailures[0].vmName | Should -Be 'amisad-edge-a'
        $failure.DependencyFailures[0].outcome | Should -Be 'start-not-acted'
        $failure.DependencyFailures[0].kind | Should -Be 'apple-event'
        $failure.DependencyFailures[0].attempts | Should -Be 1
    }

    It 'files every other way an edge stays down as provisioning_failure with one row per edge' {
        $startup = Get-EdgeStartupFixture -Missing @('amisad-edge-a', 'amisad-edge-b') -State @{
            'amisad-edge-a' = @{ Started = $true; Ready = $false; Reason = 'started but never reported a fresh valid IP address'; Kind = 'none'; Attempts = 1 }
            'amisad-edge-b' = @{ Started = $false; Ready = $false; Reason = "start reported success but the VM is 'stopped' after 60s"; Kind = 'not-running'; Attempts = 3 }
        }
        $failure = Get-AmisAdEdgeFailure -EdgeStartup $startup
        $failure.FailureClass | Should -Be 'provisioning_failure'
        $failure.ErrorMessage | Should -Match '^Region edges are not live: amisad-edge-a \(started but never reported'
        $rows = @{}
        foreach ($row in $failure.DependencyFailures) { $rows[$row.vmName] = $row }
        $rows['amisad-edge-a'].outcome | Should -Be 'no-ip-report'
        $rows['amisad-edge-b'].outcome | Should -Be 'start-failed'
        $rows['amisad-edge-b'].attempts | Should -Be 3
        $rows['amisad-edge-b'].detail | Should -Match "VM is 'stopped'"
    }

    It 'reads a state recorded by an older module without the new fields' {
        $startup = Get-EdgeStartupFixture -Missing @('amisad-edge-b') -State @{ 'amisad-edge-b' = @{ Started = $false; Ready = $false; Reason = 'fixture start denied' } }
        $startup.Remove('ControlHung'); $startup.Remove('HungEdge')
        $failure = Get-AmisAdEdgeFailure -EdgeStartup $startup
        $failure.FailureClass | Should -Be 'provisioning_failure'
        $failure.DependencyFailures[0].kind | Should -Be 'none'
        $failure.DependencyFailures[0].attempts | Should -Be 0
    }
}

Describe 'AmisAd lab failure record' {
    BeforeAll {
        $script:RecordFramework = Join-Path $TestDrive 'record-framework'
        $modulesDir = Join-Path $script:RecordFramework 'test/modules'
        New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
        foreach ($name in 'Test.SequenceFailureState', 'Test.StateFile') {
            "function Get-$($name -replace '\.', '')Marker { return '$name' }`nExport-ModuleMember -Function Get-$($name -replace '\.', '')Marker" |
                Set-Content -LiteralPath (Join-Path $modulesDir "$name.psm1")
        }
        @'
function Write-CycleInfraFailure {
    param([string]$Stage, [string]$FailureClass, [string]$Severity, [string]$GuestKey, [string]$VMName, [string]$ErrorMessage, [string]$HostType, [hashtable]$HostMemory, [hashtable[]]$DependencyFailures = @())
    $captured = @{ Stage = $Stage; FailureClass = $FailureClass; Severity = $Severity; GuestKey = $GuestKey; VMName = $VMName; HostMemory = $HostMemory; ErrorMessage = $ErrorMessage; HostType = $HostType; DependencyFailures = @($DependencyFailures) }
    $captured | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $env:YURUNA_LOG_DIR 'captured.json')
}
Export-ModuleMember -Function Write-CycleInfraFailure
'@ | Set-Content -LiteralPath (Join-Path $modulesDir 'Test.RunnerInnerLoop.psm1')
        $script:SavedLogDir = $env:YURUNA_LOG_DIR
    }
    AfterAll {
        $env:YURUNA_LOG_DIR = $script:SavedLogDir
        Remove-Module Test.SequenceFailureState, Test.StateFile, Test.RunnerInnerLoop -Force -ErrorAction SilentlyContinue
    }

    It 'hands the classified record, its rows and the host type to the framework writer' {
        $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'record-log'
        New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
        $rows = [hashtable[]]@(@{ area = 'amisad-edge'; vmName = 'amisad-edge-b'; outcome = 'start-not-acted'; detail = 'hung'; kind = 'apple-event'; attempts = 1 })
        $written = Write-AmisAdLabFailure -YurunaRoot $script:RecordFramework -HostType 'host.macos.utm' -Stage 'Start-AmisAdEdge' `
            -FailureClass 'hypervisor_unresponsive' -ErrorMessage 'The hypervisor control channel stopped acting' -DependencyFailures $rows
        $written | Should -BeTrue
        $captured = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_LOG_DIR 'captured.json') | ConvertFrom-Json
        $captured.Stage | Should -Be 'Start-AmisAdEdge'
        $captured.FailureClass | Should -Be 'hypervisor_unresponsive'
        $captured.Severity | Should -Be 'hard'
        $captured.GuestKey | Should -Be '(orchestration)'
        $captured.HostType | Should -Be 'host.macos.utm'
        $captured.ErrorMessage | Should -Be 'The hypervisor control channel stopped acting'
        @($captured.DependencyFailures).Count | Should -Be 1
        $captured.DependencyFailures[0].vmName | Should -Be 'amisad-edge-b'
    }

    It 'writes nothing and reports so outside a cycle' {
        $env:YURUNA_LOG_DIR = ''
        $written = Write-AmisAdLabFailure -YurunaRoot $script:RecordFramework -HostType 'host.macos.utm' -Stage 'Start-AmisAdEdge' `
            -FailureClass 'provisioning_failure' -ErrorMessage 'no cycle'
        $written | Should -BeFalse
    }

    It 'preserves storage evidence with a public writer that has no HostStorage parameter' {
        $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'storage-record-log'
        New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
        $startup = @{ kind = 'storage-capacity'; errorCode = '0x80070070'; hostStorage = @{ freeBytes = 9GB; requiredBytes = 12GB };
                      hostMemory = @{ availableBytes = 24GB } }
        Write-AmisAdLabFailure -YurunaRoot $script:RecordFramework -HostType 'host.windows.hyper-v' -Stage 'Start-AmisAdCore' `
            -FailureClass 'provisioning_failure' -ErrorMessage 'VMRS volume full' -VMName 'amisad-core' -StartupFailure $startup | Should -BeTrue
        $captured = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_LOG_DIR 'captured.json') | ConvertFrom-Json
        $captured.VMName | Should -Be 'amisad-core'
        $captured.Severity | Should -Be 'hard'
        $captured.FailureClass | Should -Be 'provisioning_failure'
        $captured.HostMemory.availableBytes | Should -Be 24GB
        $captured.DependencyFailures[0].hostStorage.freeBytes | Should -Be 9GB
        $captured.DependencyFailures[0].errorCode | Should -Be '0x80070070'
    }

    It 'never fails the stage when the framework writer is missing' {
        $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'record-log-missing'
        New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
        $written = Write-AmisAdLabFailure -YurunaRoot (Join-Path $TestDrive 'no-such-framework') -HostType 'host.macos.utm' -Stage 'Start-AmisAdEdge' `
            -FailureClass 'provisioning_failure' -ErrorMessage 'no framework'
        $written | Should -BeFalse
    }
}

Describe 'AmisAd topology storage admission' {
    BeforeEach {
        $script:StorageDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Write-AmisAdLabFailure -ModuleName AmisAd.Lab -MockWith { $true }
    }
    AfterEach {
        if (Get-Command Test-VMStorageCapacity -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path 'function:Test-VMStorageCapacity' -Force
        }
    }

    It 'records unavailable evidence and remains compatible with a public driver lacking the optional helper' {
        $result = Test-AmisAdStorageAdmission -YurunaRoot $script:FixtureRoot -HostType 'host.windows.hyper-v' -LogDir $script:StorageDir -Stage 'BeforeProvisioning' -IncludeDiskGrowth
        $result.allowed | Should -BeTrue
        $result.status | Should -Be 'unknown'
        $result.reason | Should -Match 'unavailable'
        $record = Get-Content -LiteralPath (Join-Path $script:StorageDir 'storage-admission.BeforeProvisioning.json') -Raw | ConvertFrom-Json
        $record.status | Should -Be 'unknown'
        Should -Invoke Write-AmisAdLabFailure -ModuleName AmisAd.Lab -Times 0 -Exactly
    }

    It 'checks the declared concurrent runtime plus explicit growth before provisioning and refuses a known shortage' {
        Set-Item -Path 'function:global:Test-VMStorageCapacity' -Value {
            param([string[]]$VMName, [hashtable]$StartupMemoryBytes, [hashtable]$AdditionalStorageBytes, [long]$ReserveBytes, [long]$ProvisioningMemoryBytes)
            $script:CapacityArgs = @{ VMName = $VMName; Memory = $StartupMemoryBytes; Growth = $AdditionalStorageBytes; Reserve = $ReserveBytes; Provisioning = $ProvisioningMemoryBytes }
            return @{ allowed = $false; status = 'insufficient'; reason = 'C: needs 86 GiB, 56 GiB available'; volumes = @(@{ volume = 'C:'; freeBytes = 56GB }) }
        }
        $result = Test-AmisAdStorageAdmission -YurunaRoot $script:FixtureRoot -HostType 'host.windows.hyper-v' -LogDir $script:StorageDir -Stage 'BeforeProvisioning' -IncludeDiskGrowth
        $result.allowed | Should -BeFalse
        @($script:CapacityArgs.VMName).Count | Should -Be 4
        ($script:CapacityArgs.Memory.Values | Measure-Object -Sum).Sum | Should -Be 20GB
        ($script:CapacityArgs.Growth.Values | Measure-Object -Sum).Sum | Should -Be 64GB
        $script:CapacityArgs.Memory['amisad-build'] | Should -Be 0
        $script:CapacityArgs.Reserve | Should -Be 2GB
        $script:CapacityArgs.Provisioning | Should -Be 12GB
        Should -Invoke Write-AmisAdLabFailure -ModuleName AmisAd.Lab -Times 1 -Exactly -ParameterFilter {
            $Stage -eq 'StorageAdmission-BeforeProvisioning' -and $FailureClass -eq 'provisioning_failure' -and $StartupFailure.hostStorage.status -eq 'insufficient'
        }
    }

    It 'rechecks final starts without charging the already provisioned disk growth again' {
        Set-Item -Path 'function:global:Test-VMStorageCapacity' -Value {
            param([string[]]$VMName, [hashtable]$StartupMemoryBytes, [hashtable]$AdditionalStorageBytes, [long]$ReserveBytes)
            $script:CapacityArgs = @{ VMName = $VMName; Memory = $StartupMemoryBytes; Growth = $AdditionalStorageBytes; Reserve = $ReserveBytes }
            return @{ allowed = $true; status = 'ready'; reason = '' }
        }
        $result = Test-AmisAdStorageAdmission -YurunaRoot $script:FixtureRoot -HostType 'host.windows.hyper-v' -LogDir $script:StorageDir -Stage 'BeforeStart'
        $result.allowed | Should -BeTrue
        @($script:CapacityArgs.VMName).Count | Should -Be 3
        $script:CapacityArgs.VMName | Should -Not -Contain 'amisad-build'
        ($script:CapacityArgs.Memory.Values | Measure-Object -Sum).Sum | Should -Be 20GB
        $script:CapacityArgs.Growth.Count | Should -Be 0
        Should -Invoke Write-AmisAdLabFailure -ModuleName AmisAd.Lab -Times 0 -Exactly
    }
}

Describe 'AmisAd topology entry points' {
    BeforeAll {
        $script:EntryProject = Join-Path $TestDrive 'entry-project'
        $script:EntryFramework = Join-Path $TestDrive 'entry-framework'
        foreach ($directory in 'test', 'poc/build') { New-Item -ItemType Directory -Path (Join-Path $script:EntryProject $directory) -Force | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $script:EntryFramework 'test') -Force | Out-Null
        foreach ($file in 'Debug-TestSequence.ps1', 'Remove-TestVMFiles.ps1') { Set-Content -LiteralPath (Join-Path $script:EntryFramework "test/$file") -Value '# fixture' }
        foreach ($file in 'test/Initialize-Lab.ps1', 'poc/build/run-tests.ps1') { Copy-Item -LiteralPath (Join-Path $script:RepoRoot $file) -Destination (Join-Path $script:EntryProject $file) }
        @'
function Resolve-YurunaRoot { param($Explicit) return $Explicit }
function Initialize-AmisAdHost { param($YurunaRoot) return 'host.windows.hyper-v' }
function Test-HostRequirement { param($HostType) return $true }
'@ | Set-Content -LiteralPath (Join-Path $script:EntryProject 'test/AmisAd.HostCommon.ps1')
        @'
function Resolve-StashService { param($YurunaRoot, $Pin) return @{ Address = '192.0.2.1'; Lines = @() } }
Export-ModuleMember -Function Resolve-StashService
'@ | Set-Content -LiteralPath (Join-Path $script:EntryProject 'test/AmisAd.StashService.psm1')
        @'
function Add-Trace { param($Text) Add-Content -LiteralPath $env:AMISAD_FIXTURE_TRACE -Value $Text }
function Test-AmisAdStorageAdmission {
    param($YurunaRoot, $HostType, $LogDir, $Stage, [switch]$IncludeDiskGrowth)
    Add-Trace "admission:$Stage"
    return @{ allowed = $env:AMISAD_FIXTURE_BLOCK -ne $Stage; reason = 'fixture capacity shortage' }
}
function Invoke-AmisAdStage { param($Name) Add-Trace "stage:$Name"; return 0 }
function Invoke-AmisAdCleanup { return 0 }
function Stop-LabConsole { }
function Remove-LegacyDemoKey { }
function Stop-VMForce { return $true }
function Remove-InstallMedia { }
function Set-EdgeMemory { }
function Get-VMState { return 'stopped' }
function Start-AmisAdEdge {
    Add-Trace 'start:edges'
    return @{ Ok = $true; Lines = @(); Address = @{}; ReportedAt = @{} }
}
function Sync-AmisAdDemoKey {
    Add-Trace 'start:core'
    return @{ Ok = $false; Lines = @(); Stage = 'Start-AmisAdCore'; FailureClass = 'provisioning_failure'; VMName = 'amisad-core';
              Reason = 'amisad-core did not start: VMRS volume full'; StartupFailure = @{ errorCode = '0x80070070'; hostStorage = @{ freeBytes = 9GB } } }
}
function Save-AmisAdEdgeAddressEvidence {
    param($EdgeVm, $EdgeAddress, $ReportedAt, $LogDir, $AdditionalVm)
    Add-Trace "diagnostics:$AdditionalVm"
    return @{ Lines = @(); Written = $true }
}
function Write-AmisAdLabFailure {
    param($YurunaRoot, $HostType, $Stage, $FailureClass, $ErrorMessage, $VMName, $StartupFailure)
    @{ Stage = $Stage; VMName = $VMName; StartupFailure = $StartupFailure } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$env:AMISAD_FIXTURE_TRACE.json"
    return $true
}
Export-ModuleMember -Function *
'@ | Set-Content -LiteralPath (Join-Path $script:EntryProject 'test/AmisAd.Lab.psm1')
        $script:SavedFixtureTrace = $env:AMISAD_FIXTURE_TRACE
        $script:SavedFixtureBlock = $env:AMISAD_FIXTURE_BLOCK
    }
    AfterAll {
        $env:AMISAD_FIXTURE_TRACE = $script:SavedFixtureTrace
        $env:AMISAD_FIXTURE_BLOCK = $script:SavedFixtureBlock
    }

    It '<Entry> stops at <Gate> before the next VM operation' -TestCases @(
        @{ Entry = 'test/Initialize-Lab.ps1'; Gate = 'BeforeProvisioning'; Stages = 0 }
        @{ Entry = 'test/Initialize-Lab.ps1'; Gate = 'BeforeStart'; Stages = 4 }
        @{ Entry = 'poc/build/run-tests.ps1'; Gate = 'BeforeProvisioning'; Stages = 0 }
        @{ Entry = 'poc/build/run-tests.ps1'; Gate = 'BeforeStart'; Stages = 4 }
    ) {
        param($Entry, $Gate, $Stages)
        $env:AMISAD_FIXTURE_TRACE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:AMISAD_FIXTURE_BLOCK = $Gate
        $arguments = @('-YurunaRoot', $script:EntryFramework, '-LogDir', $script:Logs)
        Invoke-AmisAdScript -ScriptPath (Join-Path $script:EntryProject $Entry) -ScriptArguments $arguments `
            -OutputPath "$env:AMISAD_FIXTURE_TRACE.out" -ErrorPath "$env:AMISAD_FIXTURE_TRACE.err" | Should -Be 1
        $trace = @(Get-Content -LiteralPath $env:AMISAD_FIXTURE_TRACE)
        $trace | Should -Contain "admission:$Gate"
        @($trace | Where-Object { $_ -like 'stage:*' }).Count | Should -Be $Stages
        @($trace | Where-Object { $_ -like 'start:*' }).Count | Should -Be 0
    }

    It '<Entry> records the core startup cause and captures the failed core' -TestCases @(
        @{ Entry = 'test/Initialize-Lab.ps1' }
        @{ Entry = 'poc/build/run-tests.ps1' }
    ) {
        param($Entry)
        $env:AMISAD_FIXTURE_TRACE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:AMISAD_FIXTURE_BLOCK = ''
        $arguments = @('-YurunaRoot', $script:EntryFramework, '-LogDir', $script:Logs)
        Invoke-AmisAdScript -ScriptPath (Join-Path $script:EntryProject $Entry) -ScriptArguments $arguments `
            -OutputPath "$env:AMISAD_FIXTURE_TRACE.out" -ErrorPath "$env:AMISAD_FIXTURE_TRACE.err" | Should -Be 1
        $record = Get-Content -LiteralPath "$env:AMISAD_FIXTURE_TRACE.json" -Raw | ConvertFrom-Json
        $record.Stage | Should -Be 'Start-AmisAdCore'
        $record.VMName | Should -Be 'amisad-core'
        $record.StartupFailure.errorCode | Should -Be '0x80070070'
        @(Get-Content -LiteralPath $env:AMISAD_FIXTURE_TRACE) | Should -Contain 'diagnostics:amisad-core'
        $errorText = Get-Content -LiteralPath "$env:AMISAD_FIXTURE_TRACE.err" -Raw
        $errorText | Should -Match 'VMRS volume full'
        $errorText | Should -Not -Match 'do not trust'
    }
}

Describe 'AmisAd control snapshot' {
    AfterEach {
        # Unqualified on purpose: Remove-Item does not resolve a global:
        # qualifier on the function drive from a nested scope, so the fake
        # would otherwise outlive the test that defined it.
        if (Get-Command Save-UtmControlSnapshot -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path 'function:Save-UtmControlSnapshot' -Force
        }
    }
    BeforeAll {
        $script:SnapshotStartup = @{
            Ok = $false; Address = @{}; Lines = [string[]]@(); ControlHung = $true; HungEdge = 'amisad-edge-b'
            Missing = @('amisad-edge-a', 'amisad-edge-b')
            State = @{
                'amisad-edge-a' = @{ Started = $true; Ready = $false; Reason = 'started but never reported a fresh valid IP address'; Kind = 'none'; Attempts = 1 }
                'amisad-edge-b' = @{ Started = $false; Ready = $false; Reason = 'hung'; Kind = 'apple-event'; Attempts = 1 }
            }
        }
    }

    It 'records nothing on a host whose driver has no snapshot verb' {
        $result = Save-AmisAdControlSnapshot -EdgeStartup $script:SnapshotStartup -LogDir $script:Logs
        $result | Should -BeNullOrEmpty
    }

    It 'asks the driver for the stage log directory and the edge that started but never reported' {
        $script:SnapshotArgs = $null
        Set-Item -Path 'function:global:Save-UtmControlSnapshot' -Value {
            [CmdletBinding(SupportsShouldProcess)] param([string]$OutputDirectory, [string]$Trigger, [string]$VMName)
            $script:SnapshotArgs = @{ OutputDirectory = $OutputDirectory; Trigger = $Trigger; VMName = $VMName }
            return [pscustomobject]@{ Written = $true; Path = (Join-Path $OutputDirectory "utm-control-snapshot.$Trigger.json") }
        }
        $result = Save-AmisAdControlSnapshot -EdgeStartup $script:SnapshotStartup -LogDir $script:Logs
        $result.Written | Should -BeTrue
        $script:SnapshotArgs.OutputDirectory | Should -Be $script:Logs
        $script:SnapshotArgs.Trigger | Should -Be 'initialize-lab-edge-start'
        $script:SnapshotArgs.VMName | Should -Be 'amisad-edge-a'
    }

    It 'never fails the stage when the driver verb throws' {
        Set-Item -Path 'function:global:Save-UtmControlSnapshot' -Value { [CmdletBinding(SupportsShouldProcess)] param([string]$OutputDirectory, [string]$Trigger, [string]$VMName) $null = @($OutputDirectory, $Trigger, $VMName); throw 'no evidence today' }
        $result = Save-AmisAdControlSnapshot -EdgeStartup $script:SnapshotStartup -LogDir $script:Logs
        $result | Should -BeNullOrEmpty
    }

    # Runs last in this block: the driver fakes above must not outlive their
    # tests, or the no-driver case passes only because it happens to run first.
    It 'leaves no driver fake behind for the tests that follow' {
        Get-Command Save-UtmControlSnapshot -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Save-AmisAdControlSnapshot -EdgeStartup $script:SnapshotStartup -LogDir $script:Logs | Should -BeNullOrEmpty
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

# A page on another site can make its own name resolve to 127.0.0.1 (DNS
# rebinding); its requests then reach the demo from a loopback peer.
Describe 'AmisAd demo requests name this machine' {
    BeforeAll {
        function New-DemoRequest {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory request object; changes no system state.')]
            [CmdletBinding()]
            param([string]$Url, [string]$Peer = '127.0.0.1', [string]$Origin = '', [string]$Method = 'GET')
            $headers = @{}
            if ($Origin) { $headers['Origin'] = $Origin }
            [pscustomobject]@{
                Url = [Uri]$Url; HttpMethod = $Method; Headers = $headers
                RemoteEndPoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Peer), 50000)
            }
        }
    }
    It 'answers <Url> with <Expected>' -TestCases @(
        @{ Url = 'http://localhost:8080/'; Expected = $true }
        @{ Url = 'http://127.0.0.1:8080/'; Expected = $true }
        @{ Url = 'http://[::1]:8080/'; Expected = $true }
        @{ Url = 'http://192.0.2.77:8080/'; Expected = $true; Bind = '192.0.2.77' }
        @{ Url = 'http://attacker.example:8080/'; Expected = $false }
    ) {
        param($Url, $Expected, $Bind)
        $bindAddress = if ($Bind) { $Bind } else { 'any' }
        Test-DemoRequestHost -Request (New-DemoRequest -Url $Url) -BindAddress $bindAddress | Should -Be $Expected
    }
    It 'answers to this machine''s own name' {
        Test-DemoRequestHost -Request (New-DemoRequest -Url ('http://' + [Environment]::MachineName + ':8080/')) | Should -BeTrue
    }
    It 'withholds loopback-only data from a rebound name, though the peer is loopback' {
        Test-LoopbackClient (New-DemoRequest -Url 'http://localhost:8080/api/personas') | Should -BeTrue
        Test-LoopbackClient (New-DemoRequest -Url 'http://attacker.example:8080/api/personas') | Should -BeFalse
        Test-LoopbackClient (New-DemoRequest -Url 'http://localhost:8080/api/personas' -Peer '192.0.2.9') | Should -BeFalse
    }
    It 'lets only the demo''s own pages, or a client that names no origin, change state' {
        Test-DemoSameOrigin -Request (New-DemoRequest -Url 'http://localhost:8080/api/journal' -Method POST) | Should -BeTrue
        Test-DemoSameOrigin -Request (New-DemoRequest -Url 'http://localhost:8080/api/journal' -Method POST -Origin 'http://localhost:8080') | Should -BeTrue
        Test-DemoSameOrigin -Request (New-DemoRequest -Url 'http://localhost:8080/api/journal' -Method POST -Origin 'https://attacker.example') | Should -BeFalse
    }
    It 'checks the host, then the origin, before any route in <Server>' -TestCases @(
        @{ Server = 'poc/demo/data-view/serve-data-view.ps1' }, @{ Server = 'poc/demo/by-act/serve-by-act.ps1' }
    ) {
        param($Server)
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot $Server)
        $hostCheck = $text.IndexOf('Test-DemoRequestHost -Request $req')
        $originCheck = $text.IndexOf('Test-DemoSameOrigin -Request $req')
        $firstRoute = $text.IndexOf("elseif (`$path -eq '/api/personas')")
        $hostCheck | Should -BeGreaterThan 0
        $originCheck | Should -BeGreaterThan $hostCheck
        $firstRoute | Should -BeGreaterThan $originCheck
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
                (Get-Item -Force -LiteralPath $run.Dir).UnixMode | Should -Be 'drwx------'
                (Get-Item -Force -LiteralPath $run.Keys).UnixMode | Should -Be '-rw-------'
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
                param([string]$VMName, [string]$User, [string]$Command, [int]$TimeoutSeconds, [string]$Address)
                $null = $TimeoutSeconds
                $script:Calls.Add(@{ VM = $VMName; User = $User; Command = $Command; Address = $Address })
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
            ($script:Calls | ForEach-Object { "$($_.VM)/$($_.User)@$($_.Address)" }) | Should -Be @(
                'amisad-core/amisad-core-admin@', 'amisad-core/amisad-core-admin@',
                'amisad-edge-a/amisad-edge-a-admin@192.0.2.11', 'amisad-edge-a/amisad-edge-a-admin@192.0.2.11',
                'amisad-edge-b/amisad-edge-b-admin@192.0.2.12', 'amisad-edge-b/amisad-edge-b-admin@192.0.2.12',
                'amisad-core/amisad-core-admin@', 'amisad-core/amisad-core-admin@')
            $script:Calls[2].Command | Should -Be 'true' -Because 'an address report does not prove sshd is accepting logins'
            $script:Calls[3].Command | Should -Match ([regex]::Escape($script:PublicLine))
            $script:Calls[6].Command | Should -Match 'amisad-edge-a-admin@192\.0\.2\.11 true$'
            $script:Calls[7].Command | Should -Match 'amisad-edge-b-admin@192\.0\.2\.12 true$'
            ($result.Lines -join "`n") | Should -Match 'Reaching amisad-edge-a at 192\.0\.2\.11, the address it reported'
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

        It 'reports the core startup stage and evidence before any guest or key operation' {
            Set-KeyFixtureState -State 'off'
            Mock Start-VMConfirmed -ModuleName AmisAd.Lab -MockWith {
                @{ started = $false; reason = 'VMRS volume full'; vmName = 'amisad-core'; kind = 'storage-capacity';
                   errorCode = '0x80070070'; hostStorage = @{ status = 'insufficient'; freeBytes = 9GB } }
            }
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Stage | Should -Be 'Start-AmisAdCore'
            $result.VMName | Should -Be 'amisad-core'
            $result.StartupFailure.errorCode | Should -Be '0x80070070'
            $result.StartupFailure.hostStorage.freeBytes | Should -Be 9GB
            ($result.Lines -join "`n") | Should -Not -Match 'key hand-off failed|do not trust'
            $script:Calls.Count | Should -Be 0
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

        It 'waits for an edge to answer SSH at its reported address, and names that address when it never does' {
            $script:Answers['probe|amisad-edge-a'] = @{ success = $false; exitCode = 255; output = 'Connection refused' }
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -InvokeGuest $script:Guest -PollSeconds 0 -ReadySeconds 0 `
                -EdgeAddress @{ 'amisad-edge-a' = '192.0.2.11'; 'amisad-edge-b' = '192.0.2.12' } -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Reason | Should -Match 'amisad-edge-a did not answer SSH at 192\.0\.2\.11'
            ($script:Calls | Where-Object { $_.Command -like 'umask 077*' }).Count | Should -Be 0
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

    Context 'the default SSH channel when host discovery finds nothing' {
        # The edges reported fresh addresses, but the host's own discovery
        # returns nothing for them -- Invoke-GuestSsh then dials the bare VM
        # name, which DNS cannot resolve. The hand-off must reach each edge at
        # the address it reported, through the framework's -ResolvedAddress.
        BeforeEach {
            $script:AmisAdSshCalls = [System.Collections.Generic.List[hashtable]]::new()
            $script:AmisAdPublicLine = $script:PublicLine
            Set-Item -Path 'function:global:Invoke-GuestSsh' -Value {
                param([string]$VMName, [string]$User, [string]$Command, [int]$TimeoutSeconds, [string]$ResolvedAddress)
                $null = $TimeoutSeconds
                $script:AmisAdSshCalls.Add(@{ VM = $VMName; User = $User; Command = $Command; ResolvedAddress = $ResolvedAddress })
                if ($VMName -like 'amisad-edge-*' -and -not $ResolvedAddress) {
                    return @{ success = $false; exitCode = 255; output = "ssh: Could not resolve hostname ${VMName}: Name or service not known" }
                }
                $output = if ($Command -like 'cat *amisad-demo-key.pub*') { $script:AmisAdPublicLine } else { '' }
                return @{ success = $true; exitCode = 0; output = $output }
            }
            Set-Item -Path 'function:global:Get-VMIp' -Value { param([string]$VMName) $null = $VMName; return '' }
        }
        AfterEach {
            # Unqualified on purpose: Remove-Item does not resolve a global:
            # qualifier on the function drive from a nested scope.
            foreach ($fake in 'Invoke-GuestSsh', 'Get-VMIp') {
                if (Get-Command $fake -CommandType Function -ErrorAction SilentlyContinue) { Remove-Item -Path "function:$fake" -Force }
            }
        }

        It 'installs the key at the reported address and keeps the VM name and user' {
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -PollSeconds 0 -ReadySeconds 5 `
                -EdgeAddress @{ 'amisad-edge-a' = '192.168.7.161'; 'amisad-edge-b' = '192.168.7.162' } -Confirm:$false
            $result.Ok | Should -BeTrue -Because ($result.Lines -join "`n")
            $edgeCalls = @($script:AmisAdSshCalls | Where-Object { $_.VM -like 'amisad-edge-*' })
            $edgeCalls.Count | Should -BeGreaterThan 0
            foreach ($call in $edgeCalls) {
                $call.User | Should -Be "$($call.VM)-admin"
                $call.ResolvedAddress | Should -Be $(if ($call.VM -eq 'amisad-edge-a') { '192.168.7.161' } else { '192.168.7.162' })
            }
            # The core has no reported address, so it keeps ordinary discovery.
            @($script:AmisAdSshCalls | Where-Object { $_.VM -eq 'amisad-core' -and $_.ResolvedAddress }).Count | Should -Be 0
        }

        It 'still uses discovery for an edge that reported nothing' {
            $result = Sync-AmisAdDemoKey -YurunaRoot $script:FixtureRoot -PollSeconds 0 -ReadySeconds 0 `
                -EdgeAddress @{ 'amisad-edge-b' = '192.168.7.162' } -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Reason | Should -Match 'amisad-edge-a did not answer SSH at its discovered address'
            ($result.Lines -join "`n") | Should -Match 'No reported address for amisad-edge-a'
        }
    }
}

Describe 'AmisAd edge address evidence' {
    BeforeEach {
        $script:EvidenceDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:AmisAdNetworkCaptures = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach {
        # Unqualified on purpose: Remove-Item does not resolve a global:
        # qualifier on the function drive from a nested scope.
        foreach ($fake in 'Get-VMIp', 'Save-VMNetworkState') {
            if (Get-Command $fake -CommandType Function -ErrorAction SilentlyContinue) { Remove-Item -Path "function:$fake" -Force }
        }
    }

    It 'records the reported address, its time, what discovery returns now, and the network capture' {
        Set-Item -Path 'function:global:Get-VMIp' -Value { param([string]$VMName) if ($VMName -eq 'amisad-edge-b') { return '192.168.7.162' } return '' }
        Set-Item -Path 'function:global:Save-VMNetworkState' -Value {
            param([string]$VMName, [string]$OutputDirectory)
            $script:AmisAdNetworkCaptures.Add("$VMName|$OutputDirectory")
            return $true
        }
        $result = Save-AmisAdEdgeAddressEvidence -EdgeVm 'amisad-edge-a', 'amisad-edge-b' -LogDir $script:EvidenceDir `
            -EdgeAddress @{ 'amisad-edge-a' = '192.168.7.161'; 'amisad-edge-b' = '192.168.7.162' } `
            -ReportedAt @{ 'amisad-edge-a' = '2026-10-18T13:24:10.0000000Z' }
        $result.Written | Should -BeTrue
        $text = Get-Content -LiteralPath $result.Path -Raw
        $text | Should -Match '"reportedAtUtc": "2026-10-18T13:24:10\.0000000Z"'
        $record = $text | ConvertFrom-Json
        $a = $record.edges | Where-Object vm -eq 'amisad-edge-a'
        $a.reportedAddress | Should -Be '192.168.7.161'
        $a.discoveryChecked | Should -BeTrue
        $a.discoveredAddress | Should -BeNullOrEmpty
        $a.networkStateSaved | Should -BeTrue
        ($record.edges | Where-Object vm -eq 'amisad-edge-b').discoveredAddress | Should -Be '192.168.7.162'
        $script:AmisAdNetworkCaptures | Should -Be @("amisad-edge-a|$(Join-Path $script:EvidenceDir 'amisad-edge-a')", "amisad-edge-b|$(Join-Path $script:EvidenceDir 'amisad-edge-b')")
        ($result.Lines -join "`n") | Should -Match 'amisad-edge-a: reported 192\.168\.7\.161; discovery now returns nothing'
    }

    It 'never fails the stage when discovery throws, and records the error' {
        Set-Item -Path 'function:global:Get-VMIp' -Value { param([string]$VMName) $null = $VMName; throw 'WMI query timed out' }
        $result = Save-AmisAdEdgeAddressEvidence -EdgeVm 'amisad-edge-a' -LogDir $script:EvidenceDir
        $result.Written | Should -BeTrue
        $a = (Get-Content -LiteralPath $result.Path -Raw | ConvertFrom-Json).edges[0]
        $a.discoveryError | Should -Match 'WMI query timed out'
        $a.networkStateSaved | Should -BeNullOrEmpty -Because 'a host whose driver has no capture verb records none'
    }

    It 'keeps both edge snapshots and the failed core snapshot on disk' {
        Set-Item -Path 'function:global:Save-VMNetworkState' -Value {
            param([string]$VMName, [string]$OutputDirectory)
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
            @{ vmName = $VMName } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'vm-network.state.json')
            return $true
        }
        $result = Save-AmisAdEdgeAddressEvidence -EdgeVm 'amisad-edge-a', 'amisad-edge-b' -AdditionalVm 'amisad-core' -LogDir $script:EvidenceDir
        $result.Written | Should -BeTrue
        foreach ($vm in 'amisad-edge-a', 'amisad-edge-b', 'amisad-core') {
            $record = Get-Content -LiteralPath (Join-Path $script:EvidenceDir "$vm/vm-network.state.json") -Raw | ConvertFrom-Json
            $record.vmName | Should -Be $vm
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


Describe 'Stash dependency failure evidence' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'AmisAd.StashService.psm1') -Force -DisableNameChecking
        $script:StashFramework = Join-Path $TestDrive 'stash-framework'
        $extensionDir = Join-Path $script:StashFramework 'test/extension/stash-service'
        New-Item -ItemType Directory -Path $extensionDir -Force | Out-Null
        @'
function Test-StashServiceHost { param([string]$Address) return $Address -eq '10.0.0.10' }
function Publish-StashServiceHost { param([string]$Address) $env:AMISAD_TEST_STASH_PUBLISHED = $Address }
Export-ModuleMember -Function Test-StashServiceHost, Publish-StashServiceHost
'@ | Set-Content -LiteralPath (Join-Path $extensionDir 'default.psm1')
        $modulesDir = Join-Path $script:StashFramework 'test/modules'
        New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
        @'
function Get-ExtensionHostAddress {
    param([string]$HostType)
    if ($env:AMISAD_TEST_STASH_MODE -eq 'discovery-error') { throw 'Aggregator request failed' }
    if ($env:AMISAD_TEST_STASH_MODE -eq 'unreachable') { return '10.0.0.9' }
    if ($env:AMISAD_TEST_STASH_MODE -eq 'healthy') { return '10.0.0.10' }
    return @()
}
function Get-ExtensionHostLastOutcome {
    return @{ Area = 'stash-service'; Outcome = 'no-host'; Detail = '404 -- no live host'; Uri = 'http://pool/api/extension-hosts?area=stash-service' }
}
Export-ModuleMember -Function Get-ExtensionHostAddress, Get-ExtensionHostLastOutcome
'@ | Set-Content -LiteralPath (Join-Path $modulesDir 'Test.Extension.psm1')
        $script:SavedStashPin = $env:YURUNA_STASH_SERVICE_HOST
    }
    BeforeEach {
        $env:YURUNA_STASH_SERVICE_HOST = ''
        $env:AMISAD_TEST_STASH_PUBLISHED = ''
        Mock -ModuleName AmisAd.StashService Start-Sleep {}
    }
    AfterAll {
        $env:YURUNA_STASH_SERVICE_HOST = $script:SavedStashPin
        $env:AMISAD_TEST_STASH_MODE = ''
        $env:AMISAD_TEST_STASH_PUBLISHED = ''
        Remove-Module Test.Extension, default, AmisAd.StashService -ErrorAction SilentlyContinue
    }
    It 'retains the discovery endpoint and its no-host response for every failed attempt' {
        $env:AMISAD_TEST_STASH_MODE = 'no-host'
        $r = Resolve-StashService -YurunaRoot $script:StashFramework
        $r.Address | Should -BeNullOrEmpty
        $r.Failures.Count | Should -Be 4
        $r.Failures[3].area | Should -Be 'stash-service'
        $r.Failures[3].outcome | Should -Be 'no-host'
        $r.Failures[3].endpoint | Should -Be 'http://pool/api/extension-hosts?area=stash-service'
        $r.Failures[3].detail | Should -Be '404 -- no live host'
        $r.Failures[3].attempt | Should -Be 4
    }
    It 'retains a discovery exception instead of reusing an unrelated pool outcome' {
        $env:AMISAD_TEST_STASH_MODE = 'discovery-error'
        $r = Resolve-StashService -YurunaRoot $script:StashFramework
        $r.Failures[0].outcome | Should -Be 'discovery-error'
        $r.Failures[0].detail | Should -Be 'Aggregator request failed'
    }
    It 'retains the health endpoint when a discovered stash does not answer' {
        $env:AMISAD_TEST_STASH_MODE = 'unreachable'
        $r = Resolve-StashService -YurunaRoot $script:StashFramework
        $r.Address | Should -BeNullOrEmpty
        $r.Failures[0].area | Should -Be 'stash-service'
        $r.Failures[0].address | Should -Be '10.0.0.9'
        $r.Failures[0].endpoint | Should -Be 'http://10.0.0.9/healthz'
        $r.Failures[0].outcome | Should -Be 'unreachable'
        $env:AMISAD_TEST_STASH_PUBLISHED | Should -BeNullOrEmpty
    }
    It 'still publishes a verified stash and returns no failure evidence' {
        $env:AMISAD_TEST_STASH_MODE = 'healthy'
        $r = Resolve-StashService -YurunaRoot $script:StashFramework
        $r.Address | Should -Be '10.0.0.10'
        $r.Failures.Count | Should -Be 0
        $env:AMISAD_TEST_STASH_PUBLISHED | Should -Be '10.0.0.10'
    }
}
