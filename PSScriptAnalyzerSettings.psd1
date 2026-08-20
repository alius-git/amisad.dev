<#PSScriptInfo
.VERSION 2026.08.20
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
    # PSScriptAnalyzer settings for amisad.dev.
    #
    # Deliberately the SAME rule set as the framework repo rather than a
    # relaxed one: this repo's PowerShell is demo and lab-support code that an
    # operator runs on the same machines, so a finding that matters there
    # matters here. Copied rather than referenced because a settings file is
    # discovered by path and cannot include another across repositories.
    #
    # Auto-discovered by `Invoke-ScriptAnalyzer -Path . -Recurse`
    # (see CONTRIBUTING.md). Findings of every severity are reported:
    # Information-severity results (missing comment help, undeclared
    # output types, positional-parameter calls) are NOT filtered out, so
    # they surface alongside Errors and Warnings.

    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
