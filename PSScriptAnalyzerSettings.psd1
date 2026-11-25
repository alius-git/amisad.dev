<#PSScriptInfo
.VERSION 2026.11.26
.GUID 4216f4d7-1557-4e7a-b03c-530e2a763249
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS amisad pssa-settings
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

@{
    # The framework repo's rule set, not a relaxed one: this repository's
    # PowerShell runs on the same machines. It is copied because a settings
    # file cannot include another across repositories. Every severity is
    # reported, and tools/Analyzer.SilentCatch.psm1 is a byte-identical copy of
    # the framework's rule for catch blocks that discard the error. The
    # analyzer resolves CustomRulePath against the current location, so run it
    # from the repository root: Invoke-ScriptAnalyzer -Path . -Recurse.

    IncludeDefaultRules = $true
    CustomRulePath = @('tools/Analyzer.SilentCatch.psm1')

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}
