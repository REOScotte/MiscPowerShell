$domain        = Get-ADDomain
$domainDN      = $domain.DistinguishedName
$domainDNSRoot = $domain.DNSRoot

try {
    $step = "Getting zones from domain DNS servers."
    $domainZones = Get-ADObject -Filter "objectClass -eq 'dnsZone'" -SearchBase "CN=MicrosoftDNS,DC=DomainDnsZones,$domainDN" -SearchScope OneLevel -Server "domaindnszones.$domainDNSRoot"
    $step = "Getting zones from forest DNS servers."
    $forestZones = Get-ADObject -Filter "objectClass -eq 'dnsZone'" -SearchBase "CN=MicrosoftDNS,DC=ForestDnsZones,$domainDN" -SearchScope OneLevel -Server "forestdnszones.$domainDNSRoot"
    $step = "Getting zones from domain controllers."
    $dcZones     = Get-ADObject -Filter "objectClass -eq 'dnsZone'" -SearchBase "CN=MicrosoftDNS,CN=System,$($domain.DistinguishedName)" -SearchScope OneLevel
} catch {
    throw "Error '$_' at step '$step'"
}

$allZones = [System.Collections.ArrayList]::new()
foreach ($zone in $domainZones) {
    $allZones += [PSCustomObject]@{
        Location          = 'Domain DNS Servers'
        Name              = $zone.Name
        DistinguishedName = $zone.DistinguishedName
    }
}

foreach ($zone in $forestZones) {
    $allZones += [PSCustomObject]@{
        Location          = 'Forest DNS Servers'
        Name              = $zone.Name
        DistinguishedName = $zone.DistinguishedName
    }
}

foreach ($zone in $dcZones) {
    $allZones += [PSCustomObject]@{
        Location          = 'All Domain Controllers'
        Name              = $zone.Name
        DistinguishedName = $zone.DistinguishedName
    }
}

$pickZone = $allZones | Out-GridView -Title 'Pick a zone to view.' -OutputMode Single

try {
    $step = "Getting records for $pickZone"
    $records = Get-ADObject -Filter "objectClass -eq 'dnsNode'" -SearchBase $pickZone.DistinguishedName -Properties * -Server $server
} catch {
    throw "Error $_ in step $step"
}

# Used below to decode DNS_RPC_NAME which use a form of run length encoding.
function DecodeRLE ([byte[]]$RLE) {
    $i = 0
    $pieces = @()
    do {
        $pieceLength = $RLE[$i]
        $pieceStart  = $i + 1
        $pieceEnd    = $i + $pieceLength
        $piece       = $RLE[$pieceStart..$pieceEnd]
        $i           = $pieceEnd + 1
        $pieces += [System.Text.Encoding]::UTF8.GetString($piece)
    } until ($i -ge $RLE.Length)

    if ($i -eq $RLE.Length) {
        return $pieces
    } else {
        return '[MALFORMED DATA]'
    }
}

$decodedRecords = [System.Collections.ArrayList]::new()
foreach ($record in $records) {
    foreach ($dnsRecord in $record.dnsRecord) {
        $dataLength = [bitconverter]::ToUInt16($dnsRecord[0..1], 0)
        $type       = [bitconverter]::ToUInt16($dnsRecord[2..3], 0)
        $data       = $dnsRecord[24..(23 + $dataLength)]
        $timeStamp  = [bitconverter]::ToUInt32($dnsRecord[20..23], 0)
        $decodedRecords.Add(
            [PSCustomObject]@{
                Name         = $record.Name
                Type         = switch ($type) {
                    1       { 'A'     }
                    2       { 'NS'    }
                    5       { 'CNAME' }
                    6       { 'SOA'   }
                    15      { 'MX'    }
                    16      { 'TXT'   }
                    33      { 'SRV'   }
                    28      { 'AAAA'  }
                    default { $type   }
                }
              # Version      = $dnsRecord[4]
              # Rank         = $dnsRecord[5]A
              # Flags        = [bitconverter]::ToUInt16($dnsRecord[6..7], 0)
              # SerialNumber = [bitconverter]::ToUInt32($dnsRecord[8..11], 0)
                TTL          = [bitconverter]::ToUInt32($dnsRecord[15..12], 0)
              # Reserved     = [bitconverter]::ToUInt32($dnsRecord[16..19], 0)
                TimeStamp    = if ($timeStamp) {
                                   $datetime = ([datetime]'1601-01-01 00:00:00Z').AddHours($timeStamp)
                                   if ($datetime.IsDaylightSavingTime()) {
                                       $datetime.AddHours(1)
                                   } else {
                                       $datetime
                                   }
                               } else {
                                   'static'
                               }
                Data         = switch ($type) {
                    1       {
                                [System.Net.IPAddress]::new($data).IPAddressToString
                            }
                    2       {
                                $length = $data[0] + 1
                                $rle    = $data[2..$length]
                                (DecodeRLE -RLE $rle) -join '.'
                            }
                    5       {
                                $length = $data[0] + 1
                                $rle    = $data[2..$length]
                                (DecodeRLE -RLE $rle) -join '.'
                            }
                    6       {
                                $length = $data[20] + 1
                                $rle    = $data[22..$(20 + $length)]
                                (DecodeRLE -RLE $rle) -join '.'
                            }
                    15      {
                                $priority = [bitconverter]::ToUInt16($data[1..0], 0)
                                $length   = $data[2] + 1
                                $rle      = $data[4..(2 + $length)]
                                "[$priority] $((DecodeRLE -RLE $rle) -join '.')"
                            }
                    16      {
                                (DecodeRLE -RLE $data) -join ', '
                            }
                    28      {
                                [System.Net.IPAddress]::new($data).IPAddressToString
                            }
                    33      {
                                $priority = [bitconverter]::ToUInt16($data[1..0], 0)
                                $weight   = [bitconverter]::ToUInt16($data[3..2], 0)
                                $port     = [bitconverter]::ToUInt16($data[5..4], 0)
                                $length   = $data[6] + 1
                                $rle      = $data[8..(6 + $length)]
                                "[$priority][$weight][$port] $((DecodeRLE -RLE $rle) -join '.')"
                            }
                    default {$data}
                }
              # RawData      = $dnsRecord[24..$dnsRecord.Length]
            }
        ) | Out-Null
    }
}

$decodedRecords | Out-GridView -OutputMode Multiple