<#PSScriptInfo
.VERSION 2026.09.23
.GUID 4293d062-596a-48e4-adf5-92844ed6854c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab serve
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# Publish a manual HEAD archive; see ../test.md#project-archive-helper.
#
# .PARAMETER YurunaRoot
#   Yuruna framework checkout to publish into. Optional -- see
#   Resolve-YurunaRoot for the discovery order.
param([string]$YurunaRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'test/AmisAd.HostCommon.ps1')
$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$out = Join-Path $YurunaRoot 'project-poc.tar.gz'
git -C $repo archive --format=tar.gz -o $out HEAD
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
Write-Information "published $(git -C $repo rev-parse --short HEAD) -> $out" -InformationAction Continue
