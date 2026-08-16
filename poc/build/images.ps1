<#PSScriptInfo
.VERSION 2026.08.16
.GUID 42a2eacb-2a3b-4355-b2b9-cb0661aadd16
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc docker images
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# AmisAd POC container images. Not part of the `bazel build //...` gate -
# Docker may be absent on dev machines. Builds every service image from the
# workspace root (the Dockerfiles expect it) and optionally pushes.
param(
    [string]$Registry = 'localhost:5000',
    [switch]$Push
)
$ErrorActionPreference = 'Stop'
$poc = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error 'docker not found - install Docker to build images'
    exit 1
}

$services = @(
    'seller-svc', 'resource-svc', 'ads-svc', 'insights-svc', 'platform-svc',
    'audit-svc', 'connect-svc', 'fabric-coordinator', 'identity-mock', 'ledger-svc'
)

Push-Location $poc
try {
    foreach ($svc in $services) {
        $tag = "$Registry/amisad/${svc}:latest"
        docker build -f "components/services/$svc/Dockerfile" -t $tag .
        if ($LASTEXITCODE -ne 0) { throw "docker build failed for $svc" }
        if ($Push) {
            docker push $tag
            if ($LASTEXITCODE -ne 0) { throw "docker push failed for $svc" }
        }
    }
    # slice-runtime image (runs on edge VMs, not in the cluster)
    $tag = "$Registry/amisad/slice-runtime:latest"
    docker build -f 'components/edge/slice-runtime/Dockerfile' -t $tag .
    if ($LASTEXITCODE -ne 0) { throw 'docker build failed for slice-runtime' }
    if ($Push) { docker push $tag }

    Write-Information "images OK - 11 images built$(if ($Push) { ' and pushed' })" -InformationAction Continue
}
finally {
    Pop-Location
}
