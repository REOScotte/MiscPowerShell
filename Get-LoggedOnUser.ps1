enum LogonType {
    Local = 0
    Interactive = 2
    Network = 3
    Batch = 4
    Service = 5
    Proxy = 6
    Unlock = 7
    NetworkCleartext = 8
    NewCredentials = 9
    RemoteInteractive = 10
    CachedInteractive = 11
    CachedRemoteInteractive = 12
    CachedUnlock = 13
}

function Get-LoggedonUser {
    [CmdletBinding()]
    param(
        $ComputerName = 'localhost',
        [LogonType[]]$LogonType = [enum]::GetValues('LogonType')
    )

    process {
        $logonSessions = @(Get-CimInstance -ClassName Win32_LogonSession -ComputerName $ComputerName)
        $loggedOnUsers = @(Get-CimInstance -ClassName Win32_LoggedOnUser -ComputerName $ComputerName)

        $loggedonUsers | ForEach-Object {
            $loggedonUser = $_
            $logonSession = $logonSessions | Where-Object { $_.PSComputerName -eq $loggedonUser.PSComputerName -and $_.LogonId -eq $loggedonUser.Dependent.LogonId }
            
            if ($logonSession.LogonType -in $LogonType.value__) {
                [PSCustomObject]@{
                    ComputerName          = $loggedOnUser.PSComputerName
                    LogonId               = $loggedOnUser.Dependent.LogonId
                    Username              = "$($loggedOnUser.Antecedent.Domain)\$($loggedOnUser.Antecedent.Name)"
                    LogonType             = [LogonType]$logonSession.LogonType
                    AuthenticationPackage = $logonSession.AuthenticationPackage
                    StartType             = $logonSession.StartTime
                }
            }
        }
    }
}

Get-LoggedonUser -ComputerName srmsppmfp01p -LogonType RemoteInteractive
