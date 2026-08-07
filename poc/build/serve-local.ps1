<#PSScriptInfo
.VERSION 2026.08.09
.GUID 42f28106-215e-4fc9-8c1c-5cfcc18afd53
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

# Lab helper: publish the committed amisad.dev tree to the Yuruna status
# server as /yuruna-repo/project-poc.tar.gz (the guest fetches it in lab
# iteration mode - see the s001.fulfillment sequence header). Run after every
# commit; serves HEAD, so uncommitted changes never reach the guest.
param([string]$YurunaRoot = 'c:\git\yuruna')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$out = Join-Path $YurunaRoot 'project-poc.tar.gz'
git -C $repo archive --format=tar.gz -o $out HEAD
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
Write-Information "published $(git -C $repo rev-parse --short HEAD) -> $out" -InformationAction Continue
