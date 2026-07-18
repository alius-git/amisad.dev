# Lab helper: publish the committed amisad.dev tree to the Yuruna status
# server as /yuruna-repo/project-poc.tar.gz (the guest fetches it in lab
# iteration mode - see the scenario-001 sequence header). Run after every
# commit; serves HEAD, so uncommitted changes never reach the guest.
param([string]$YurunaRoot = 'c:\git\yuruna')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$out = Join-Path $YurunaRoot 'project-poc.tar.gz'
git -C $repo archive --format=tar.gz -o $out HEAD
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
Write-Host "published $(git -C $repo rev-parse --short HEAD) -> $out"
