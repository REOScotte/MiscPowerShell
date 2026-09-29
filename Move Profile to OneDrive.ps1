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

# Set the Downloads Known Folder location.
$DownloadsPath = Join-Path -Path $OneDrivePath -ChildPath 'Downloads'
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
$DownloadsPath = [System.IO.Path]::GetFullPath($DownloadsPath).TrimEnd('\', '/')

if ($CurrentDownloadsPath -ieq $DownloadsPath) {
    Write-Host "Downloads is already located at '$DownloadsPath'." -ForegroundColor Green
} else {
    if (-not (Test-Path -LiteralPath $DownloadsPath)) {
        New-Item -ItemType Directory -Path $DownloadsPath -Force | Out-Null
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
        throw "Windows still reports Downloads at '$UpdatedDownloadsPath' instead of '$DownloadsPath'."
    }

    Write-Host "Downloads Location set to '$DownloadsPath'. Existing files were not moved." -ForegroundColor Green
}
