$skip = @(
    #'Install-OctopusTentacle.ps1'
    #'Get-OctopusTentacleTrustedThumbprint.ps1'
    #'Remove-OctopusTentacleTrustedThumbprint.ps1'
    #'Add-OctopusTentacleTrustedThumbprint.ps1'
    #'Get-OctopusServerThumbprint.ps1'
    #'JHA_OctopusCmdlets_Public.ps1'
)

$files = Get-ChildItem 'C:\Users\secrawford\OneDrive - Jack Henry & Associates\source\repos\JHA\JHA_OctopusCmdlets\JHA_OctopusCmdlets\*.ps1' -Recurse | Where-Object Name -NotIn $skip

$exclude = @(
    #'PSReviewUnusedParameter'
    #'PSAvoidUsingConvertToSecureStringWithPlainText'
    #'PSPossibleIncorrectComparisonWithNull'
    #'PSAvoidUsingWriteHost'
    #'PSUseShouldProcessForStateChangingFunctions'
    #'PSAvoidUsingEmptyCatchBlock'
    #'PSShouldProcess'
    #'PSUseSingularNouns'
    #'PSUseDeclaredVarsMoreThanAssignments'
    #'PSUseCorrectCasing'
)

foreach ($file in $files) {
    Invoke-ScriptAnalyzer -Path $file -ExcludeRule $exclude -Settings ScriptSecurity
    #$content = Get-Content $file -Raw
    #$ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
    #$ast | Select-Object ParamBlock
}