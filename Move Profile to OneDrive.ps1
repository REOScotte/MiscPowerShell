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

$DownloadsGuid = [Guid]'374DE290-123F-4565-9164-39C4925E467B'
[DownloadsKnownFolder]::SHSetKnownFolderPath($DownloadsGuid, 0, [IntPtr]::Zero, $DownloadsPath)
Write-Host "Downloads Location set to '$DownloadsPath'. Existing files were not moved." -ForegroundColor Green
