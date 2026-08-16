<#PSScriptInfo
.VERSION 2026.08.16
.GUID 425d945d-2301-4544-a649-eeff38675bca
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc toolchain doctor
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# AmisAd POC toolchain doctor. All three toolchains are REQUIRED (plus Bazel):
# fails fast with a clear message before any build starts.
# Optional tools (docker, helm, kubectl) are reported but do not fail the check.
$ErrorActionPreference = 'Stop'

$failures = @()

function Test-Tool {
    param(
        [string]$Name,
        [string[]]$Candidates,
        [string]$VersionArgs,
        [bool]$Required,
        [string]$Hint
    )
    foreach ($c in $Candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) {
            try { $v = (& $c $VersionArgs.Split(' ') 2>&1 | Select-Object -First 1) } catch { $v = 'version check failed' }
            Write-Information ("  OK       {0,-10} {1}" -f $Name, $v)
            return
        }
    }
    if ($Required) {
        Write-Information ("  MISSING  {0,-10} REQUIRED - {1}" -f $Name, $Hint)
        $script:failures += $Name
    } else {
        Write-Information ("  missing  {0,-10} optional - {1}" -f $Name, $Hint)
    }
}

$InformationPreference = 'Continue'
Write-Information "AmisAd POC doctor - required toolchains:"
Test-Tool -Name 'bazel'   -Candidates @('bazelisk', 'bazel') -VersionArgs '--version' -Required $true  -Hint 'install bazelisk (https://github.com/bazelbuild/bazelisk); .bazelversion pins Bazel'
Test-Tool -Name 'rust'    -Candidates @('cargo')             -VersionArgs '--version' -Required $true  -Hint 'install rustup (https://rustup.rs)'
Test-Tool -Name 'node'    -Candidates @('node')              -VersionArgs '--version' -Required $true  -Hint 'install Node.js LTS (https://nodejs.org)'
Test-Tool -Name 'npm'     -Candidates @('npm')               -VersionArgs '--version' -Required $true  -Hint 'ships with Node.js'
Test-Tool -Name 'flutter' -Candidates @('flutter')           -VersionArgs '--version' -Required $true  -Hint 'install the Flutter SDK (https://flutter.dev)'
Write-Information 'Optional (needed for images/deploys, not for bazel build):'
Test-Tool -Name 'docker'  -Candidates @('docker')            -VersionArgs '--version' -Required $false -Hint 'needed by build/images.ps1'
Test-Tool -Name 'helm'    -Candidates @('helm')              -VersionArgs 'version --short' -Required $false -Hint 'needed to lint/deploy workloads/'
Test-Tool -Name 'kubectl' -Candidates @('kubectl')           -VersionArgs 'version --client' -Required $false -Hint 'needed for cluster deploys'

if ($failures.Count -gt 0) {
    Write-Error ("doctor FAILED - missing required toolchains: {0}" -f ($failures -join ', '))
    exit 1
}
Write-Information "doctor OK - all required toolchains present"
