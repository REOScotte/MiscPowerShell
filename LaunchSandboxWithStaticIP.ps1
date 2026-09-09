# Find all Internet Connection Sharing networks
$hnsNetworks = Get-HnsNetwork | Where-Object Type -eq 'ICS'

# The active hns network will have an address in one of the gateway addresses, so use its IP
$natIP = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -in $hnsNetworks.Subnets.GatewayAddress -and
    $_.AddressState -eq 'Preferred'
}

# Use the gateway ip and subnet to calculate the sandbox configuration
$gateway      = $natIP.IPAddress
$prefixLength = $natIP.PrefixLength

# Convert the gateway IP to UInt32 for easy iteration
$ipBytes = [System.Net.IPAddress]::Parse($gateway).GetAddressBytes()
[Array]::Reverse($ipBytes)
$ipUInt32 = [System.BitConverter]::ToUInt32($ipBytes, 0)

# Calculate Network and Broadcast boundaries
$maskUInt32      = [UInt32]::MaxValue -shl (32 - $prefixLength)
$networkUInt32   = $ipUInt32 -band $maskUInt32
$broadcastUInt32 = $networkUInt32 -bor (-bnot $maskUInt32)

# Start at the beginning with a null IP
$unusedIP = $null
$testUInt32 = $networkUInt32 + 1

# Iterate upward starting from the first available IP in the network
while ($testUInt32 -lt $broadcastUInt32 -and -not $unusedIP) {
    # Convert back to IP string
    $bytes = [System.BitConverter]::GetBytes([UInt32]$testUInt32)
    [Array]::Reverse($bytes)
    $testIP = ([System.Net.IPAddress]::new($bytes)).IPAddressToString

    # Skip the gateway IP address
    if ($testIP -ne $gateway) {
        Write-Host "Checking IP: $testIP"

        # Trigger ARP resolution (ignore ping pass/fail result)
        Test-Connection -ComputerName $testIP -Count 1 -Quiet | Out-Null

        # Check ARP cache entry
        $neighbor = Get-NetNeighbor -IPAddress $testIP -AddressFamily IPv4 -State Reachable, Permanent -ErrorAction SilentlyContinue

        if (-not $neighbor) {
            $unusedIP = $testIP
        }
    }

    $testUInt32++
}

if ($unusedIP) {
    Write-Host "Found available IP address: $unusedIP" -ForegroundColor Green
} else {
    Write-Host "No available IP address found in this subnet ($gateway/$prefixLength)." -ForegroundColor Red
    return
}

$wsb = @"
<Configuration>
  <LogonCommand>
    <Command>powershell.exe -ExecutionPolicy Bypass -Command "New-NetIPAddress -IPAddress $unusedIP -InterfaceAlias Ethernet -DefaultGateway $gateway -AddressFamily IPv4 -PrefixLength $prefixLength; Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses $gateway"</Command>
  </LogonCommand>
</Configuration>
"@

$wsb | Out-File SandboxWithStaticIP.wsb -Encoding ascii

start SandboxWithStaticIP.wsb