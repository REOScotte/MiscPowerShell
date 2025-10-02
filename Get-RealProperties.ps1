<#
.SYNOPSIS
Gets the definition of computed properties and reveals the real underlying properties.

.EXAMPLE
Shows how the calculated properties of Get-Process are calculated.

Get-Process | Get-RealProperties
#>

function Get-RealProperties {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [object]$Object
    )

    begin {
        # Collect the types that are passed in
        $types = [System.Collections.ArrayList]::new()
    }

    process {
        foreach ($item in $Object) {
            $types.Add($item.PSObject.TypeNames[0]) | Out-Null
        }
    }

    end {
        # Just need one copy of each
        $types = $types | Sort-Object -Unique

        foreach ($type in $types) {
            $fd = Get-FormatData -TypeName $type

            $tableControl = $fd.FormatViewDefinition.Control | Where-Object { $_.GetType().Name -eq 'TableControl' }

            0..($tableControl.Headers.Count - 1) | ForEach-Object {
                $label = $tableControl.Headers[$_].Label
                if ($label) {
                    [PSCustomObject]@{
                        Type  = $type
                        Name  = $label
                        Value = $tableControl.Rows.Columns[$_].DisplayEntry
                    }
                    #$output | Add-Member -MemberType NoteProperty -Name $label -Value $tableControl.Rows.Columns[$_].DisplayEntry
                }
            }
            
            # This gets the list of columns directly from Format-Table
            #$columns = $item | Format-Table |
            #    Where-Object { $_.PSObject.TypeNames -eq 'Microsoft.PowerShell.Commands.Internal.Format.FormatStartData' } |
            #    Select-Object -ExpandProperty shapeInfo |
            #    Select-Object -ExpandProperty tableColumnInfoList |
            #    Select-Object -ExpandProperty label 
        }
    }
}