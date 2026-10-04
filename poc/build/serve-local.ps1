<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42bb2598-96d4-4eb2-bbe8-94b041c0e8d5
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

# Compatibility entry point for manual archive publication.
param([string]$YurunaRoot)
& (Join-Path $PSScriptRoot 'Publish-ProjectArchive.ps1') @PSBoundParameters
