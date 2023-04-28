Add-Type -AssemblyName System.Windows.Forms

$clipboard = Get-Clipboard -Raw

Start-Sleep -Seconds 3

foreach ($c in [char[]]$clipboard) {
    $key = switch ($c) {
        "+"     { '{+}' }
        "^"     { '{^}' }
        "%"     { '{%}' }
        "("     { '{(}' }
        ")"     { '{)}' }
        "{"     { '{{}' }
        "}"     { '{}}' }
        "["     { '{[}' }
        "]"     { '{]}' }
        "~"     { '{~}' }
        "`r"    { $null }
        "`n"    { '~'   }
        default { $c    }
    }

    [System.Windows.Forms.SendKeys]::SendWait($key)
}
