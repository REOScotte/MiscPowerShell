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

# Calculate the Network IP for messages.
$netBytes = [System.BitConverter]::GetBytes([UInt32]$networkUInt32)
[Array]::Reverse($netBytes)
$networkIP = ([System.Net.IPAddress]::new($netBytes)).IPAddressToString

# Calculate the Subnet Mask.
$maskBytes = [System.BitConverter]::GetBytes([UInt32]$maskUInt32)
[Array]::Reverse($maskBytes)
$mask = ([System.Net.IPAddress]::new($maskBytes)).IPAddressToString

# Start at the beginning with a null IP
$unusedIP   = $null
$testUInt32 = $networkUInt32 + 1

Write-Host "Finding a free IP in the $networkIP/$prefixLength subnet." -ForegroundColor Green

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
    Write-Host "No available IP address found in this subnet: $networkIP/$prefixLength" -ForegroundColor Red
    return
}

$wsbPath = "$env:TEMP\SandboxWithStaticIP.wsb"

$wsb = @"
<Configuration>
  <LogonCommand>
    <Command><![CDATA[cmd.exe /c "netsh interface ip set address name=Ethernet static $unusedIP $mask $gateway && netsh interface ip set dns name=Ethernet static $gateway"]]></Command>
  </LogonCommand>
</Configuration>
"@

$wsb | Out-File -FilePath $wsbPath -Encoding ascii

Write-Host "Starting Windows Sandbox and configuring its network with these setttings:" -ForegroundColor Green
[PSCustomObject]@{
    'IP Address'    = $unusedIP
    'Subnet Mask'   = $mask
    'Gateway'       = $gateway
    'DNS Address'   = $gateway
} | Format-Table

Invoke-Item $wsbPath