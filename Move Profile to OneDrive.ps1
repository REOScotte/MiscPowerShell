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

# 2. Add C# Win32 API safely
if (-not ('KnownFoldersApiV2' -as [type])) {
    $KnownFoldersApiDefinition = @'
    using System;
    using System.Runtime.InteropServices;

    public class KnownFoldersApiV2
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        public static extern void SHSetKnownFolderPath(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
            uint dwFlags,
            IntPtr hToken,
            string pszPath
        );
    }
'@
    Add-Type -TypeDefinition $KnownFoldersApiDefinition
}

# 3. Discover the Downloads Known Folder ID
$hklmDesc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions'
$userShellFoldersPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$UserShellFolderValueNames = @(
    (Get-ItemProperty -LiteralPath $userShellFoldersPath).PSObject.Properties |
        Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notlike 'PS*' } |
        Select-Object -ExpandProperty Name
)

$DownloadsCandidates = @(
    foreach ($node in Get-ChildItem -LiteralPath $hklmDesc) {
        $props = Get-ItemProperty -LiteralPath $node.PSPath -ErrorAction SilentlyContinue

        if ($props.Category -eq 4 -and
            $props.RelativePath -eq 'Downloads' -and
            -not $props.ParentFolder) {
            [pscustomobject]@{
                Name                = $props.Name
                Guid                = $node.PSChildName
                IsNamedRegistration = $UserShellFolderValueNames -contains $props.Name
                IsGuidRegistration  = $UserShellFolderValueNames -contains $node.PSChildName
            }
        }
    }
)

$DownloadsFolder = $DownloadsCandidates |
    Sort-Object `
        @{ Expression = { if ($_.IsNamedRegistration) { 0 } else { 1 } } },
        @{ Expression = { if ($_.IsGuidRegistration) { 0 } else { 1 } } },
        @{ Expression = { if ($_.Name -eq 'Downloads') { 0 } else { 1 } } },
        @{ Expression = { $_.Name.Length } } |
    Select-Object -First 1

if (-not $DownloadsFolder) {
    throw 'Could not find the Downloads Known Folder definition in the registry.'
}

$DownloadsGuid = [Guid]::Parse($DownloadsFolder.Guid)
$DownloadsPath = Join-Path -Path $OneDrivePath -ChildPath 'Downloads'

if (-not (Test-Path -LiteralPath $DownloadsPath)) {
    New-Item -ItemType Directory -Path $DownloadsPath -Force | Out-Null
}

[KnownFoldersApiV2]::SHSetKnownFolderPath($DownloadsGuid, 0, [IntPtr]::Zero, $DownloadsPath)
Write-Host "Downloads Location set to '$DownloadsPath'. Existing files were not moved." -ForegroundColor Green
