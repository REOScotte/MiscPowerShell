#netsh http show sslcert
$binding = $null
$allBindings = @()

# Parse existing bindings
netsh http show sslcert | ForEach-Object {
    # After each blank line, output the existing binding and reset $binding to null so a new one can be built.
    if ( $_.Trim() -eq '' ) {
        if ($binding) {
            $allBindings += [PSCustomObject]$binding
        }

        $binding = $null
    }

    # If the line isn't a property, move to the next line, otherwise get the name and value of the property
    if ( $_ -notmatch '^ (.*)\s+: (.*)$' ) {
        return
    } else {
        $name = $matches[1].Trim()
        $value = $matches[2].Trim()
    }

    # The IP:port property signifies the beginning of a binding definition so initialize a new binding
    if ( $name -in @('IP:port', 'Hostname:port', 'Central Certificate Store') ) {
        $binding = [ordered]@{}
    }

    if ( $value -eq '(null)' ) {
        $value = $null
    }
    
    if ( $value -eq 'Enabled' ) {
        $value = $true
    }
    
    if ( $value -eq 'Disabled' ) {
        $value = $false
    }
        
    $binding[$name] = $value
} 

foreach ($binding in $allBindings) {
    $bindingName = $binding.PSObject.Properties.Value[0]
    
    $parts = $bindingName.Split(':')

    $bindingType = if     ($parts.Count -eq 2 -and $parts[0] -as [ipaddress] -and $parts[1] -as [uint16]) {'ipport'}
                   elseif ($parts.Count -eq 2 -and $parts[1] -as [uint16]) {'hostnameport'}
                   elseif ($parts.Count -eq 1 -and $parts[0] -as [uint16]) {'ccs'}
                   else   {throw "Invalid value for BindingName - $BindingName."}

    netsh http delete sslcert $bindingType=$BindingName
}
