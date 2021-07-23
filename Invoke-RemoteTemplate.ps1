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

.PARAMETER ComputerName
A remote computer to target

.PARAMETER Session
A PSSession object to target

.PARAMETER InvokeCommandParameters
An optional set of parameters used to customize Invoke-Command to support other connection options,
authentication options, throttle limits, end point specifications, etc.
Any Parameter that Invoke-Command supports can be used and this paramater is splatted to all instances of Invoke-Command.

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

Invoke-RemoteTemplate -InvokeCommandParameters @{Port = 8080}

.NOTES
To avoid variable name collisions, the End block uses variable names with the _endBlock_ prefix. 

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

    # The process block builds a collection of targets - $allSessions and $allComputers -  which are referenced in the End block.
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
    # It parses the AST of the begin block to find variables that need to be referenced remotely with $using:
    # It also handles importing the $*Preference variables into remote sessions.
    # Generally, this block should not be modified.
    end {
        #region Parse the Abtract Syntax Tree of the current script to pull out CmdletBinding attributes,parameters, and defined variables.
        # Get the entire AST of the function
        $_endBlock_functionAst = (Get-Command $MyInvocation.MyCommand).ScriptBlock.Ast

        # Get the CmdletBinding attribute of the param block
        $_endBlock_predicate = {
            param ( [System.Management.Automation.Language.Ast] $AstObject )
            return ( $AstObject -is [System.Management.Automation.Language.AttributeAst] )
        }
        $_endBlock_CmdletBindingAttribute = $_endBlock_functionAst.Body.ParamBlock.Attributes.FindAll($_endBlock_predicate, $false) |
            Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' } |
            Select-Object -ExpandProperty Extent |
            Select-Object -ExpandProperty Text

        # Find the parameters in the param block except for ComputerName, Session, and InvokeCommandParameters
        $_endBlock_predicate = {
            param ( [System.Management.Automation.Language.Ast] $AstObject )
            return ( $AstObject -is [System.Management.Automation.Language.ParameterAst] )
        }
        $_endBlock_Parameters = $_endBlock_functionAst.Body.ParamBlock.Parameters.FindAll($_endBlock_predicate, $false) |
            Where-Object { $_.Name.VariablePath.UserPath -notin @('ComputerName', 'Session', 'InvokeCommandParameters') } |
            Select-Object -ExpandProperty Name |
            Select-Object -ExpandProperty VariablePath |
            Select-Object -ExpandProperty UserPath

        # Find the variables assigned in the Begin block except for script and postScript
        $_endBlock_predicate = {
            param ( [System.Management.Automation.Language.Ast] $AstObject )
            return ( $AstObject -is [System.Management.Automation.Language.AssignmentStatementAst] )
        }
        $_endBlock_BeginVariables = $_endBlock_functionAst.Body.BeginBlock.Statements.FindAll($_endBlock_predicate, $false) |
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
        
        #region Param Script
        # This scriptblock defines that param block for the function. It includes the CmdletBinding attribute found above.
        # It also copies PSBoundParameters to another variable. This allows them to be visible when the script is running locally.
        $_endBlock_PSBoundParameters = $PSBoundParameters
        $_endBlock_ParamScript = "
            $_endBlock_CmdletBindingAttribute
            param()
            
            `$PSBoundParameters = `$_endBlock_PSBoundParameters
        "
        #endregion

        #region Variable script
        # Create a script that imports each local variable from the $using scope. The $using statements are wrapped in
        # a try/catch block since the $using scope doesn't exist when the script is executed locally and would otherwise error.
        # Ast could pick up variables that aren't always assigned, so its existence is checked before adding to the block.
        # For example, $test won't have a value if condition is false, but Ast will still see it.
        # if ($condition) {$test = 'test'}
        # PSBoundParameters is also added to pick up DynamicParameters and to pass this info to remote machines.

        $_endBlock_LocalVariableNames = @()
        if ($_endBlock_Parameters)     { $_endBlock_LocalVariableNames += $_endBlock_Parameters     }
        if ($_endBlock_BeginVariables) { $_endBlock_LocalVariableNames += $_endBlock_BeginVariables }

        $_endBlock_VariableScript = "`ntry {`n"
        foreach ($_endBlock_LocalVariableName in $_endBlock_LocalVariableNames) {
            $_endBlock_LocalVariable = Get-Variable | Where-Object Name -EQ $_endBlock_LocalVariableName
            if ($_endBlock_LocalVariable) {
                $_endBlock_VariableValue = $_endBlock_LocalVariable.Value
                if ($_endBlock_VariableValue) {
                    $_endBlock_TypeName = $_endBlock_LocalVariable.Value.GetType().FullName

                    # Not all variable types cross the "using" threshold intact. Specific types can be called out here to correct for that.
                    $_endBlock_UsingSide = switch ($_endBlock_TypeName) {
                        'System.Management.Automation.ScriptBlock' { "[scriptblock]::Create(`$using:$_endBlock_LocalVariableName)" }
                        'System.Security.AccessControl.DirectorySecurity' {
                            $_endBlock_TempAclSddl = $_endBlock_LocalVariable.Value.Sddl
                            "[System.Security.AccessControl.DirectorySecurity]::new();`$$_endBlock_LocalVariableName.SetSecurityDescriptorSddlForm(`$using:_endBlock_TempAclSddl)"
                        }
                        default { "`$using:$_endBlock_LocalVariableName" }
                    }
                } else {
                    $_endBlock_UsingSide = '$null'
                }
                $_endBlock_VariableScript += "    `$$_endBlock_LocalVariableName = $_endBlock_UsingSide`n"
            }
        }
        $_endBlock_VariableScript += "    `$PSBoundParameters = `$using:_endBlock_PSBoundParameters`n"
        $_endBlock_VariableScript += "} catch {}`n"
        #endregion

        #region Import preference variables

        # This scriptblock imports all the current preferences to ensure those settings are passed to $script.
        $_endBlock_PreferenceScript = {
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

        #region Assemble the 4 scripts and run it
        # The 4 scripts - Param, Variable, Preference, and the main script are combined into a single scriptblock.
        $_endBlock_TotalScript = [scriptblock]::Create($_endBlock_ParamScript + $_endBlock_VariableScript + $_endBlock_PreferenceScript.ToString() + $script.ToString())

        # Run the total script on all applicable targets - computers, sessions, or local.
        switch ($PSCmdlet.ParameterSetName) {
            'Session' {
                if ($allSessions) {
                    Invoke-Command -Session $allSessions -ScriptBlock $_endBlock_TotalScript -ErrorAction SilentlyContinue -ErrorVariable +ErrorVar @InvokeCommandParameters
                }
            }
            'Computer' {
                if ($allComputers) {
                    Invoke-Command -ComputerName $allComputers -ScriptBlock $_endBlock_TotalScript -ErrorAction SilentlyContinue -ErrorVariable +ErrorVar @InvokeCommandParameters
                }
            }
            'Local' {
                & $_endBlock_TotalScript
            }
        }
        #endregion

        #region Report any errors collected in $ErrorVar
        # If the error has an OriginInfo.PSComputerName, it occurred ON the remote computer so the remote error is written here as a warning.
        # If the error has a TargetObject.ComputerName, it occurred trying to connect to a session object so report the computer name.
        # If the error just has a TargetObject, it occured trying to connect to a remote computer, so report the computer name.
        # Otherwise, something strange is happening.
        foreach ($record in $ErrorVar) {
            if ($record.OriginInfo.PSComputerName) {
                Write-Warning "Error: $($record.Exception.Message) $($record.OriginInfo.PSComputerName)"
            } elseif ($record.TargetObject.ComputerName) {
                Write-Warning "Unable to connect to $($record.TargetObject.ComputerName)"
            } elseif ($record.TargetObject) {
                Write-Warning "Unable to connect to $($record.TargetObject)"
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
