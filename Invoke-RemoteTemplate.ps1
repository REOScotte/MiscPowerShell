<#
.SYNOPSIS
Template for a function that supports remote computers

.DESCRIPTION
This template simplifies building functions that will flexibly run locally or remotely.
A script is defined once in the Begin block that implements the desired functionality. 

This function can be run locally, on a remote computer, or in an existing remote session.
The script that's defined in the Begin block is what will run. 

The Process block collects a list of targets.

The End block parses the AST to ensure all variables and preferences are referenced correctly and the $script
is invoked on all the targets.

Optionally, $postScript can be defined in the Begin block. After the main script is finished, it will be run
locally to handle any needed cleanup or other tasks.

Parameters can be added to the param() block, but Session, ComputerName, and InvokeCommandPreferences shouldn't be changed.

.PARAMETER Session
A PSSession object to target

.PARAMETER ComputerName
A remote computer to target

.PARAMETER InvokeCommandParameters
This function uses Invoke-Command to execute on remote computers. This parameter customizes how Invoke-Command
is called. This is primarily for customizing authentication and connection options, but any Parameter that
Invoke-Command supports can be specified and will be splatted to all instances of Invoke-Command. 

Note: This function uses Session, ComputerName, ErrorAction, ErrorVariable, and ToSession
Specifying these Parameters will cause unexpected results, and should not be used.

.PARAMETER Variable
An example variable

.EXAMPLE
Run on Comp1 and Comp2 via ComputerName

Invoke-RemoteTemplate -ComputerName Comp1, Comp2

.EXAMPLE
Run on Comp1 and Comp2 via pipeline string objects

'Comp1', 'Comp2' | Invoke-RemoteTemplate

.EXAMPLE
Run on Comp1 and Comp2 via pipeline session objects

$sessions = New-PSSession -ComputerName Comp1, Comp2
$sessions | Invoke-RemoteTemplate

.EXAMPLE
Run on Comp1 over port 8080

Invoke-RemoteTemplate -ComputerName Comp1 -InvokeCommandParameters @{Port = 8080}

.NOTES
To avoid variable name collisions, the End block uses variable names with the __ prefix. 

$PSBoundParameters is not supported in a script block. To use dynamic parmeters or otherwise
use $PSBoundParameters, assign them to a variable in the Begin block, but outside of $script

Author: Scott Crawford
Created: 2020-09-30
#>

function Invoke-RemoteTemplate {
    [CmdletBinding(DefaultParameterSetName = 'Local', PositionalBinding = $false)]
    param (
        [Parameter(ParameterSetName = 'Session', Mandatory, ValueFromPipeline)]
        [System.Management.Automation.Runspaces.PSSession[]]$Session
        ,
        [Parameter(ParameterSetName = 'Computer', Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name', 'Server', 'CN', 'PSComputerName')]
        [string[]]$ComputerName
        ,
        [hashtable]$InvokeCommandParameters = @{}
        ,
        [string]$Variable
    )

    # The majority of the script is defined here in $script and $postScript. Any other setup can also be done here.
    begin {
        # The End block will run this script on all appropriate targets.
        $script = {
            Stop-Puppy -Name $Variable
        }

        # The End block looks for this optional postScript to call locally after $script is finished being invoked.
        $postScript = {
        
        }
    }

    # The process block builds a collection of targets - $allSessions and $allComputers - which are referenced in the End block.
    # Steps that are unique per target can be done here as well.
    process {
        switch ($PSCmdlet.ParameterSetName) {
            'Session' {
                foreach ($target in $Session) {
                    [array]$allSessions += $target
                    # Do something unique to the target
                }
            }
            'Computer' {
                foreach ($target in $ComputerName) {
                    [array]$allComputers += $target
                    # Do something unique to the target
                }
            }
            'Local' {
                # Do something locally
            }
        }
    }

    # The end block is boilerplate and handles running $script locally or on remote computers and sessions.
    # It parses the AST to set CmdletBinding attributes, parameters, and defined variables.
    # It uses these items to build a $__TotalScript that combines them along with preference variables and the original $script. 
    # Variables used here have a dunderbar (__) prefix to avoid name collisions.
    # This block should not be modified.
    end {
        #region Parse the Abtract Syntax Tree of the current script to pull out CmdletBinding attributes, parameters, and defined variables.
        # Get the entire AST of the function
        $__functionAst = (Get-Command $MyInvocation.MyCommand).ScriptBlock.Ast

        # Get the CmdletBinding attribute of the param block
        $__predicate = {
            param ( [System.Management.Automation.Language.Ast] $AstObject )
            return ( $AstObject -is [System.Management.Automation.Language.AttributeAst] )
        }
        $__CmdletBindingAttribute = $__functionAst.Body.ParamBlock.Attributes.FindAll($__predicate, $false) |
            Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' } |
            Select-Object -ExpandProperty Extent |
            Select-Object -ExpandProperty Text

        # Find the parameters in the param block except for ComputerName, Session, and InvokeCommandParameters
        $__predicate = {
            param ( [System.Management.Automation.Language.Ast] $AstObject )
            return ( $AstObject -is [System.Management.Automation.Language.ParameterAst] )
        }
        $__Parameters = $__functionAst.Body.ParamBlock.Parameters.FindAll($__predicate, $false) |
            Where-Object { $_.Name.VariablePath.UserPath -notin @('ComputerName', 'Session', 'InvokeCommandParameters') } |
            Select-Object -ExpandProperty Name |
            Select-Object -ExpandProperty VariablePath |
            Select-Object -ExpandProperty UserPath

        # Find the variables assigned in the Begin block except for script and postScript
        $__predicate = {
            param ( [System.Management.Automation.Language.Ast] $AstObject )
            return ( $AstObject -is [System.Management.Automation.Language.AssignmentStatementAst] )
        }
        $__BeginVariables = $__functionAst.Body.BeginBlock.Statements.FindAll($__predicate, $false) |
            Select-Object @{n = 'Name'; e = {
                    if ($_.Left.Child.VariablePath.UserPath) {
                        $_.Left.Child.VariablePath.UserPath
                    } else {
                        $_.Left.VariablePath.UserPath
                    } 
                }
            } |
            Where-Object Name -NotIn @('script', 'postScript') |
            Select-Object -ExpandProperty Name
        #endregion
        
        #region Variable script
        # This scriptblock defines that param block for the script. It includes the CmdletBinding attribute found above.
        # It also creates a script that imports each local variable from the $using scope. The $using statements are wrapped in
        # a try/catch block since the $using scope doesn't exist when the script is executed locally and would otherwise error.
        # Ast could pick up variables that aren't always assigned, so its existence is checked before adding to the block.
        # For example, $test won't have a value if condition is false, but Ast will still see it.
        # if ($condition) {$test = 'test'}

        $__LocalVariableNames = @()
        if ($__Parameters) { $__LocalVariableNames += $__Parameters }
        if ($__BeginVariables) { $__LocalVariableNames += $__BeginVariables }

        $__VariableScript = "$__CmdletBindingAttribute`n"
        $__VariableScript += "param()`n"
        $__VariableScript += "`n"
        
        # Add each variable in a try/catch block
        $__VariableScript += "try {`n"
        foreach ($__LocalVariableName in $__LocalVariableNames) {
            $__LocalVariable = Get-Variable | Where-Object Name -EQ $__LocalVariableName
            if ($__LocalVariable) {
                $__VariableValue = $__LocalVariable.Value
                if ($null -eq $__VariableValue) {
                    $__UsingSide = '$null'
                } else {
                    $__TypeName = $__LocalVariable.Value.GetType().FullName

                    # Not all variable types cross the "using" threshold seamlessly. Shims for specific types can be implemented here.
                    $__UsingSide = switch ($__TypeName) {
                        'System.Management.Automation.ScriptBlock' {
                            "[scriptblock]::Create(`$using:$__LocalVariableName)"
                        }
                        'System.Security.AccessControl.DirectorySecurity' {
                            $__TempAclSddl = $__LocalVariable.Value.Sddl
                            $__TempAclSddl | Out-Null # This line just suppresses the PSScriptAnalyzer error since it can't see $__TempAclSddl being used below.
                            "[System.Security.AccessControl.DirectorySecurity]::new();`$$__LocalVariableName.SetSecurityDescriptorSddlForm(`$using:__TempAclSddl)"
                        }
                        default { "`$using:$__LocalVariableName" }
                    }
                }
                $__VariableScript += "    `$$__LocalVariableName = $__UsingSide`n"
            }
        }
        $__VariableScript += "} catch {}`n"
        #endregion

        #region Preference script

        # This scriptblock imports all the current preferences to ensure those settings are passed to $script.
        $__PreferenceScript = {
            try {
                $ConfirmPreference     = $using:ConfirmPreference
                $DebugPreference       = $using:DebugPreference
                $ErrorActionPreference = $using:ErrorActionPreference
                $InformationPreference = $using:InformationPreference
                $ProgressPreference    = $using:ProgressPreference
                $VerbosePreference     = $using:VerbosePreference
                $WarningPreference     = $using:WarningPreference
                $WhatIfPreference      = $using:WhatIfPreference
            } catch {}

            # Some cmdlets have issues with binding the preference variables. This ensures the defaults are set for all.
            # Confirm, Debug, Verbose, and WhatIf are special cases. Since they're switch parameters, the preference variable
            # is evaluated to determine if the switch should be set.
            $PSDefaultParameterValues = @{
                '*:ErrorAction'       = $ErrorActionPreference
                '*:InformationAction' = $InformationPreference
                '*:WarningAction'     = $WarningPreference
            }
            if ($ConfirmPreference -eq 'Low'     ) { $PSDefaultParameterValues += @{'*:Confirm' = $true } }
            if ($DebugPreference   -eq 'Inquire' ) { $PSDefaultParameterValues += @{'*:Debug'   = $true } }
            if ($VerbosePreference -eq 'Continue') { $PSDefaultParameterValues += @{'*:Verbose' = $true } }
            if ($WhatIfPreference.IsPresent      ) { $PSDefaultParameterValues += @{'*:WhatIf'  = $true } }
        }
        #endregion

        #region Assemble the 3 scripts and run them
        # The 3 scripts - Variable, Preference, and the main script are combined into a single scriptblock.
        $__TotalScript = [scriptblock]::Create($__VariableScript + $__PreferenceScript.ToString() + $script.ToString())

        # Run the total script on all applicable targets - computers, sessions, or local.
        switch ($PSCmdlet.ParameterSetName) {
            'Session' {
                if ($allSessions) {
                    Invoke-Command -Session $allSessions -ScriptBlock $__TotalScript -ErrorAction SilentlyContinue -ErrorVariable +__ErrorVar @InvokeCommandParameters
                }
            }
            'Computer' {
                if ($allComputers) {
                    Invoke-Command -ComputerName $allComputers -ScriptBlock $__TotalScript -ErrorAction SilentlyContinue -ErrorVariable +__ErrorVar @InvokeCommandParameters
                }
            }
            'Local' {
                & $__TotalScript
            }
        }
        #endregion

        #region Report any errors collected in $__ErrorVar
        # If the error has an OriginInfo.PSComputerName, it occurred ON the remote computer so the remote error is written here as a warning.
        # If the error has a TargetObject.ComputerName, it occurred trying to connect to a session object so report the computer name.
        # If the error just has a TargetObject, it occured trying to connect to a remote computer, so report the computer name.
        # Otherwise, something strange is happening.
        foreach ($__record in $__ErrorVar) {
            if ($__record.OriginInfo.PSComputerName) {
                Write-Warning "Error: $($__record.Exception.Message) $($__record.OriginInfo.PSComputerName)"
            } elseif ($__record.TargetObject.ComputerName) {
                Write-Warning "Unable to connect to $($__record.TargetObject.ComputerName)"
            } elseif ($__record.TargetObject) {
                Write-Warning "Unable to connect to $($__record.TargetObject)"
            } else {
                throw 'Unexpected error'
            }
        }
        #endregion

        # If a post script was defined in the begin block, call it locally.
        if ($postScript) {
            & $postScript
        }
    }
}
