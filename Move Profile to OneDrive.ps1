# Set error handling
$ErrorActionPreference = 'Stop'

# 1. Detect OneDrive Path Safely
$OneDrivePath = $env:OneDriveConsumer

if (-not $OneDrivePath) { 
    $OneDrivePath = $env:OneDriveCommercial 
}
if (-not $OneDrivePath) { 
    $OneDrivePath = $env:OneDrive 
}

if (-not $OneDrivePath -or -not (Test-Path -Path "$OneDrivePath" -ErrorAction Ignore)) {
    Write-Error 'OneDrive directory not found. Please ensure OneDrive is signed in.'
    exit
}

Write-Host "Target OneDrive Path: $OneDrivePath`n" -ForegroundColor Green

# Move Downloads to OneDrive and update its Known Folder location.
$DownloadsPath = [System.IO.Path]::GetFullPath((Join-Path $OneDrivePath 'Downloads')).TrimEnd('\', '/')
$DownloadsGuid = [Guid]'374DE290-123F-4565-9164-39C4925E467B'
$DownloadsValueName = $DownloadsGuid.ToString('B')
$UserShellFoldersPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$UserShellFolders = Get-ItemProperty -LiteralPath $UserShellFoldersPath
$CurrentDownloadsPath = $UserShellFolders.PSObject.Properties[$DownloadsValueName].Value

if (-not $CurrentDownloadsPath) {
    throw "Could not read the current Downloads location from '$UserShellFoldersPath'."
}

$CurrentDownloadsPath = [System.IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($CurrentDownloadsPath)
).TrimEnd('\', '/')
$ProfileDownloadsPath = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Downloads')).TrimEnd('\', '/')

# If an earlier path-only redirect already points to OneDrive, migrate the leftover profile folder.
$SourceDownloadsPath = $CurrentDownloadsPath
if ($CurrentDownloadsPath -ieq $DownloadsPath -and
    (Test-Path -LiteralPath $ProfileDownloadsPath) -and
    $ProfileDownloadsPath -ine $DownloadsPath) {
    $SourceDownloadsPath = $ProfileDownloadsPath
}

if ($SourceDownloadsPath -ieq $DownloadsPath) {
    Write-Host "Downloads is already located at '$DownloadsPath'." -ForegroundColor Green
    return
}

if (Test-Path -LiteralPath $SourceDownloadsPath) {
    $sourceItem = Get-Item -LiteralPath $SourceDownloadsPath -Force -ErrorAction Stop
    if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Downloads source '$SourceDownloadsPath' is a reparse point. Refusing to move it automatically."
    }

    $nestedReparsePoints = @(
        Get-ChildItem -LiteralPath $SourceDownloadsPath -Force -Recurse -ErrorAction Stop |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
    )
    if ($nestedReparsePoints.Count -gt 0) {
        throw "Downloads contains reparse points. Refusing to move it automatically; first item: '$($nestedReparsePoints[0].FullName)'."
    }
}

if (-not (Test-Path -LiteralPath $DownloadsPath)) {
    New-Item -ItemType Directory -Path $DownloadsPath -Force | Out-Null
}

function Get-DownloadsFileSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $root = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName.TrimEnd('\', '/')
    $snapshot = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop) {
        $relativePath = $file.FullName.Substring($root.Length).TrimStart('\', '/')
        $snapshot[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
    }

    return $snapshot
}

if (Test-Path -LiteralPath $SourceDownloadsPath) {
    Write-Host "Moving Downloads contents from '$SourceDownloadsPath' to '$DownloadsPath'..." -ForegroundColor Yellow
    & robocopy.exe $SourceDownloadsPath $DownloadsPath /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NP | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        throw "Robocopy failed with exit code $robocopyExitCode. The original Downloads folder was retained."
    }

    $sourceSnapshot = Get-DownloadsFileSnapshot -Path $SourceDownloadsPath
    $targetSnapshot = Get-DownloadsFileSnapshot -Path $DownloadsPath
    $mismatches = @(
        foreach ($relativePath in $sourceSnapshot.Keys) {
            if (-not $targetSnapshot.ContainsKey($relativePath) -or
                $targetSnapshot[$relativePath] -ne $sourceSnapshot[$relativePath]) {
                $relativePath
            }
        }
    )
    if ($mismatches.Count -gt 0) {
        throw "Downloads copy verification failed for $($mismatches.Count) file(s). The original Downloads folder was retained."
    }
}

if (-not ('DownloadsKnownFolder' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DownloadsKnownFolder
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void SHSetKnownFolderPath(
        [MarshalAs(UnmanagedType.LPStruct)] Guid folderId,
        uint flags,
        IntPtr token,
        string path
    );
}
'@
}

[DownloadsKnownFolder]::SHSetKnownFolderPath($DownloadsGuid, 0, [IntPtr]::Zero, $DownloadsPath)

$UserShellFolders = Get-ItemProperty -LiteralPath $UserShellFoldersPath
$UpdatedDownloadsPath = [Environment]::ExpandEnvironmentVariables(
    $UserShellFolders.PSObject.Properties[$DownloadsValueName].Value
)
$UpdatedDownloadsPath = [System.IO.Path]::GetFullPath($UpdatedDownloadsPath).TrimEnd('\', '/')
if ($UpdatedDownloadsPath -ine $DownloadsPath) {
    throw "Windows still reports Downloads at '$UpdatedDownloadsPath' instead of '$DownloadsPath'. The original folder was retained."
}

if ((Test-Path -LiteralPath $SourceDownloadsPath) -and $SourceDownloadsPath -ine $DownloadsPath) {
    Remove-Item -LiteralPath $SourceDownloadsPath -Recurse -Force -ErrorAction Stop
}

Write-Host "Downloads moved to '$DownloadsPath' and its Known Folder location was updated." -ForegroundColor Green
