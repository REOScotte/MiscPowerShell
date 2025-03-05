$ignore = {
    $_.FullName -notlike '*\desktop.ini' -and
    $_.FullName -notlike '*\Thumbs.db' -and
    $_.FullName -notlike '*\*.DS_Store' -and
    $_.FullName -notlike "$localFolder\Music\*" -and
    $_.FullName -notlike "$localFolder\Videos\*"
}

<#
Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force
Install-Module Microsoft.Graph -Scope CurrentUser
#>

$localFolder = $env:OneDriveConsumer

$Scope = @('Files.Read')
Connect-MgGraph -Scopes $Scope

#region XorHash from https://www.powershellgallery.com/packages/AADInternals/0.2.7/Content/OneDrive_utils.ps1
# QuickXorHash by Microsoft https://docs.microsoft.com/en-us/onedrive/developer/code-snippets/quickxorhash
# Dec 9th 2019
$xorhash_code = @"
using System;
 
public class QuickXorHash : System.Security.Cryptography.HashAlgorithm
{
    private const int BitsInLastCell = 32;
    private const byte Shift = 11;
    private const int Threshold = 600;
    private const byte WidthInBits = 160;
 
    private UInt64[] _data;
    private Int64 _lengthSoFar;
    private int _shiftSoFar;
 
    public QuickXorHash()
    {
        this.Initialize();
    }
 
    protected override void HashCore(byte[] array, int ibStart, int cbSize)
    {
        unchecked
        {
            int currentShift = this._shiftSoFar;
 
            // The bitvector where we'll start xoring
            int vectorArrayIndex = currentShift / 64;
 
            // The position within the bit vector at which we begin xoring
            int vectorOffset = currentShift % 64;
            int iterations = Math.Min(cbSize, QuickXorHash.WidthInBits);
 
            for (int i = 0; i < iterations; i++)
            {
                bool isLastCell = vectorArrayIndex == this._data.Length - 1;
                int bitsInVectorCell = isLastCell ? QuickXorHash.BitsInLastCell : 64;
 
                // There's at least 2 bitvectors before we reach the end of the array
                if (vectorOffset <= bitsInVectorCell - 8)
                {
                    for (int j = ibStart + i; j < cbSize + ibStart; j += QuickXorHash.WidthInBits)
                    {
                        this._data[vectorArrayIndex] ^= (ulong)array[j] << vectorOffset;
                    }
                }
                else
                {
                    int index1 = vectorArrayIndex;
                    int index2 = isLastCell ? 0 : (vectorArrayIndex + 1);
                    byte low = (byte)(bitsInVectorCell - vectorOffset);
 
                    byte xoredByte = 0;
                    for (int j = ibStart + i; j < cbSize + ibStart; j += QuickXorHash.WidthInBits)
                    {
                        xoredByte ^= array[j];
                    }
                    this._data[index1] ^= (ulong)xoredByte << vectorOffset;
                    this._data[index2] ^= (ulong)xoredByte >> low;
                }
                vectorOffset += QuickXorHash.Shift;
                while (vectorOffset >= bitsInVectorCell)
                {
                    vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1;
                    vectorOffset -= bitsInVectorCell;
                }
            }
 
            // Update the starting position in a circular shift pattern
            this._shiftSoFar = (this._shiftSoFar + QuickXorHash.Shift * (cbSize % QuickXorHash.WidthInBits)) % QuickXorHash.WidthInBits;
        }
 
        this._lengthSoFar += cbSize;
    }
 
    protected override byte[] HashFinal()
    {
        // Create a byte array big enough to hold all our data
        byte[] rgb = new byte[(QuickXorHash.WidthInBits - 1) / 8 + 1];
 
        // Block copy all our bitvectors to this byte array
        for (Int32 i = 0; i < this._data.Length - 1; i++)
        {
            Buffer.BlockCopy(
                BitConverter.GetBytes(this._data[i]), 0,
                rgb, i * 8,
                8);
        }
 
        Buffer.BlockCopy(
            BitConverter.GetBytes(this._data[this._data.Length - 1]), 0,
            rgb, (this._data.Length - 1) * 8,
            rgb.Length - (this._data.Length - 1) * 8);
 
        // XOR the file length with the least significant bits
        // Note that GetBytes is architecture-dependent, so care should
        // be taken with porting. The expected value is 8-bytes in length in little-endian format
        var lengthBytes = BitConverter.GetBytes(this._lengthSoFar);
        System.Diagnostics.Debug.Assert(lengthBytes.Length == 8);
        for (int i = 0; i < lengthBytes.Length; i++)
        {
            rgb[(QuickXorHash.WidthInBits / 8) - lengthBytes.Length + i] ^= lengthBytes[i];
        }
 
        return rgb;
    }
 
    public override sealed void Initialize()
    {
        this._data = new ulong[(QuickXorHash.WidthInBits - 1) / 64 + 1];
        this._shiftSoFar = 0;
        this._lengthSoFar = 0;
    }
 
    public override int HashSize
    {
        get
        {
            return QuickXorHash.WidthInBits;
        }
    }
}
"@
Add-Type -TypeDefinition $xorhash_code -Language CSharp    
Remove-Variable $xorhash_code

function Get-XorHash
{
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$True)]
        [string]$FileName
    )
    Process
    {
        # Get the full path..
        $fullpath = (Get-Item -LiteralPath $FileName -Force).FullName

        # Create a stream to read bytes
        $stream = [System.IO.FileStream]::new($fullpath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read)

        # Create the hash object and do the magic
        $xorhash = [quickxorhash]::new()
        $hash = $xorhash.ComputeHash($stream)
        $b64Hash = [convert]::ToBase64String($hash)   

        # Return
        $b64Hash
    }
}
#endregion

function Get-MgDriveItemHashes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphDriveItem]$DriveItem
        ,
        [string]$Parent
        ,
        [string]$LocalFolder
    )

    process {
        $name   = $DriveItem.Name
        $path   = "$Parent\$name" -replace "^\\root", $LocalFolder
#        $parent = $DriveItem.ParentReference.Path
#        if ($parent) {
#            $name = $name.Replace('+', '%2B')
#            $parent = $parent.Replace('+', '%2B')
#            $path = [System.Web.HttpUtility]::UrlDecode(("$parent/$name").Replace('/drive/root:',''))
#            $path = "$parent/$name".Replace('/drive/root:','')
#        } else {
#            $path = '/'
#        }

        if ($DriveItem.File.Hashes.Crc32Hash -or $DriveItem.File.Hashes.QuickXorHash -or $DriveItem.File.Hashes.Sha1Hash -or $DriveItem.File.Hashes.Sha256Hash) {
            $type = 'File'
        } else {
            $type = 'Folder'
            Write-Host "Getting Remote Path - $path"
            Get-MgDriveItemChild -DriveId me -DriveItemId $DriveItem.Id -All | Get-MgDriveItemHashes -Parent $path -LocalFolder $LocalFolder
        }

        [PSCustomObject]@{
            #Id           = $DriveItem.Id
            #Type         = $type
            #Path         = $path
            #Size         = $DriveItem.Size
            #WebUrl       = $DriveItem.WebUrl
            #LastModified = $DriveItem.LastModifiedDateTime
            #Created      = $DriveItem.CreatedDateTime
            #Crc32Hash    = $DriveItem.File.Hashes.Crc32Hash
            QuickXorHash = $DriveItem.File.Hashes.QuickXorHash
            #Sha1Hash     = $DriveItem.File.Hashes.Sha1Hash
            #Sha256Hash   = $DriveItem.File.Hashes.Sha256Hash
            LocalName    = $path
            #Item         = $DriveItem
        }
        #"$path`t$($DriveItem.File.Hashes.Sha1Hash)"
    }
}

$getRemoteFilesStartTime = Get-Date
$remoteFiles = @{}
Get-MgDriveRoot -DriveId me | Get-MgDriveItemHashes -LocalFolder $LocalFolder | ForEach-Object {
    $remoteFiles."$($_.LocalName)" = $_.QuickXorHash
}

#$remoteSize = ($remoteFiles | Where-Object Type -eq File | Select-Object -ExpandProperty Size | Measure -Sum).Sum
#$rootSize   = ($remoteFiles | Where-Object Path -eq '/').Size

# Size discrepancy
#$remoteSize - $rootSize

#$remoteFiles | ? fullname -Like "*/"

$getLocalFilesStartTime = Get-Date
$localFiles = Get-ChildItem $localFolder -Recurse -Force | Where-Object -FilterScript $ignore

$getLocalHashesStartTime = Get-Date
$localFiles | Where-Object { ([int]$_.Attributes -band 4096) -eq 0 -and -not $_.QuickXorHash } | ForEach-Object {
    if ($_.PSIsContainer) {
            Write-Host "Getting Local Path - $($_.FullName)"
    } else {
        $localHash = try {
            #($_ | Get-FileHash -Algorithm SHA1 -ErrorAction Stop).Hash
            Get-XorHash -FileName $_.FullName
        } catch {
            "Unable to calculate"
        }
        $_ | Add-Member -MemberType NoteProperty -Name RemoteQuickXorHash -Value $remoteFiles."$($_.FullName)" -Force
        $_ | Add-Member -MemberType NoteProperty -Name QuickXorHash -Value $localHash -Force
    }
}

$getRemoteFilesStartTime
$getLocalFilesStartTime
$getLocalHashesStartTime
Get-Date

$localFiles | Where-Object { ([int]$_.Attributes -band 4096) -eq 0 -and $_.QuickXorHash -ne $_.RemoteQuickXorHash } | Select-Object FullName, QuickXorHash, RemoteQuickXorHash | Out-GridView

#$diff = Compare-Object $localFiles.Fullname $remoteFiles.Keys

#$diff | Out-GridView

#$plus=$remoteFiles|? Fullname -like "*\Work\Documents\School\*"
#$p = $plus|ogv -PassThru
