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
            #QuickXorHash = $DriveItem.File.Hashes.QuickXorHash
            Sha1Hash     = $DriveItem.File.Hashes.Sha1Hash
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
    $remoteFiles."$($_.LocalName)" = $_.Sha1Hash
}

#$remoteSize = ($remoteFiles | Where-Object Type -eq File | Select-Object -ExpandProperty Size | Measure -Sum).Sum
#$rootSize   = ($remoteFiles | Where-Object Path -eq '/').Size

# Size discrepancy
#$remoteSize - $rootSize

#$remoteFiles | ? fullname -Like "*/"

$getLocalFilesStartTime = Get-Date
$localFiles = Get-ChildItem $localFolder -Recurse -Force | Where-Object -FilterScript $ignore

$getLocalHashesStartTime = Get-Date
$localFiles | Where-Object { ([int]$_.Attributes -band 4096) -eq 0 -and -not $_.Sha1Hash } | ForEach-Object {
    if ($_.PSIsContainer) {
            Write-Host "Getting Local Path - $($_.FullName)"
    } else {
        $localHash = try {
            ($_ | Get-FileHash -Algorithm SHA1 -ErrorAction Stop).Hash
        } catch {
            "Unable to calculate"
        }
        $_ | Add-Member -MemberType NoteProperty -Name RemoteSha1Hash -Value $remoteFiles."$($_.FullName)" -Force
        $_ | Add-Member -MemberType NoteProperty -Name Sha1Hash -Value $localHash -Force
    }
}

$getRemoteFilesStartTime
$getLocalFilesStartTime
$getLocalHashesStartTime
Get-Date

$localFiles | Where-Object { ([int]$_.Attributes -band 4096) -eq 0 -and $_.Sha1Hash -ne $_.RemoteSha1Hash } | Select-Object FullName, Sha1Hash, RemoteSha1Hash | Out-GridView

#$diff = Compare-Object $localFiles.Fullname $remoteFiles.Keys

#$diff | Out-GridView

#$plus=$remoteFiles|? Fullname -like "*\Work\Documents\School\*"
#$p = $plus|ogv -PassThru
