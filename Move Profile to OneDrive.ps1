Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# Set error handling
$ErrorActionPreference = "Stop"

# 1. Detect OneDrive Path Safely
$OneDrivePath =$env:OneDriveConsumer

if (-not $OneDrivePath) { 
    $OneDrivePath =$env:OneDriveCommercial 
}
if (-not $OneDrivePath) { 
    $OneDrivePath =$env:OneDrive 
}

if (-not $OneDrivePath -or -not (Test-Path -Path "$OneDrivePath" -ErrorAction Ignore)) {
    Write-Error "OneDrive directory not found. Please ensure OneDrive is signed in."
    exit
}

Write-Host "Target OneDrive Path: $OneDrivePath`n" -ForegroundColor Green

# 2. Add C# Win32 API safely
if (-not ("KnownFolders" -as [type])) {
    $KnownFoldersApiDefinition = @'
    using System;
    using System.Runtime.InteropServices;

    public class KnownFolders
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

# 3. Dynamic Per-User Discovery via Category Filter
$UserProfilePath = $env:USERPROFILE
$hklmDesc = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions"

# Get visible root folders in your profile (excluding OneDrive)
$VisibleRootFolders = Get-ChildItem -Path "$UserProfilePath" -Directory -Force | Where-Object {
    (-not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)) -and 
    (-not ($_.Attributes -band [System.IO.FileAttributes]::System)) -and
    ($_.FullName -ne $OneDrivePath)
}
$VisibleRootFolderNames = @($VisibleRootFolders.Name)

$DynamicGuidMap = @{}
$FolderDescriptions = Get-ChildItem -Path "$hklmDesc"

foreach ($node in $FolderDescriptions) {
    $guid = $node.PSChildName
    $props = Get-ItemProperty -Path $node.PSPath -ErrorAction SilentlyContinue

    # Category 4 = KF_CATEGORY_PERUSER (User-specific folders only)
    if ($props.Category -eq 4) {
        $relPath = $props.RelativePath

        if ($relPath -and ($relPath -in $VisibleRootFolderNames)) {
            $DynamicGuidMap[$relPath] = $guid
        }
    }
}

Write-Host "Dynamically discovered $($DynamicGuidMap.Count) Per-User Known Folder(s):" -ForegroundColor Cyan
foreach ($key in $DynamicGuidMap.Keys) {
    Write-Host " - $key : $($DynamicGuidMap[$key])"
}
Write-Host ""

# 3.5 Remove legacy junctions from source Documents to allow clean auto-delete
$SourceDocs = Join-Path -Path "$UserProfilePath" -ChildPath "Documents"
if (Test-Path -Path "$SourceDocs") {
    $LegacyJunctions = @("My Pictures", "My Music", "My Videos")
    foreach ($junc in $LegacyJunctions) {
        $juncPath = Join-Path -Path "$SourceDocs" -ChildPath $junc
        $item = Get-Item -Path "$juncPath" -Force -ErrorAction SilentlyContinue
        
        # Check if it exists and is a junction/reparse point
        if ($null -ne $item -and $item.Attributes -match "ReparsePoint") {
            Write-Host "Removing legacy junction '$junc' from source to prepare for migration..." -ForegroundColor Yellow
            cmd /c rmdir "$juncPath" | Out-Null
        }
    }
}

# 4. Move files using Robocopy and update Location tab
foreach ($folderName in $DynamicGuidMap.Keys) {
    $guidString = $DynamicGuidMap[$folderName]
    $guid = [Guid]::Parse($guidString)

    $oldPath = Join-Path -Path "$UserProfilePath" -ChildPath "$folderName"
    $newPath = Join-Path -Path "$OneDrivePath" -ChildPath "$folderName"

    if (-not (Test-Path -Path "$newPath")) {
        New-Item -ItemType Directory -Path "$newPath" -Force | Out-Null
    }

    if (Test-Path -Path "$oldPath") {
        Write-Host "Migrating contents of '$folderName' to '$newPath'..." -ForegroundColor Yellow
        
        $roboArgs = @(
            "$oldPath", 
            "$newPath", 
            "/E",       # Copy all subdirectories, including empty ones
            "/MOVE",    # Move files and directories (delete from source after copying)
            "/XJ",      # EXCLUDE Junction points (Fixes legacy hidden shortcut errors)
            "/R:1",     # 1 retry on locked files
            "/W:1",     # 1 second wait between retries
            "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NP"
        )
        & robocopy $roboArgs | Out-Null
    }

    try {
        [KnownFolders]::SHSetKnownFolderPath($guid, 0, [IntPtr]::Zero, $newPath)
        Write-Host "Updated Location Tab for '$folderName' -> '$newPath'" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to update Location Tab for '$folderName': $_"
    }
}

# 5. Create compatibility junctions with original Hidden/System attributes and Deny ACL
Write-Host "`nCreating legacy compatibility junctions in OneDrive Documents..." -ForegroundColor Cyan
$OneDriveDocs = Join-Path -Path "$OneDrivePath" -ChildPath "Documents"
$OneDrivePics = Join-Path -Path "$OneDrivePath" -ChildPath "Pictures"
$OneDriveMusic = Join-Path -Path "$OneDrivePath" -ChildPath "Music"
$OneDriveVids = Join-Path -Path "$OneDrivePath" -ChildPath "Videos"

if (Test-Path -Path "$OneDriveDocs") {
    $compatLinks = @(
        @{ Name = "My Pictures"; Target = $OneDrivePics },
        @{ Name = "My Music"; Target = $OneDriveMusic },
        @{ Name = "My Videos"; Target = $OneDriveVids }
    )

    foreach ($link in $compatLinks) {
        $linkPath = Join-Path -Path "$OneDriveDocs" -ChildPath $link.Name
        if (-not (Test-Path -Path "$linkPath")) {
            if (Test-Path -Path $link.Target) {
                cmd /c mklink /j "$linkPath" "$($link.Target)" | Out-Null

                $item = Get-Item -Path "$linkPath" -Force
                $item.Attributes =$item.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System

                cmd /c icacls "$linkPath" /l /deny "Everyone:(RD)" | Out-Null

                Write-Host " - Replicated legacy stub for: $($link.Name)" -ForegroundColor Green
            }
        }
    }
}

# 6. Restart File Explorer targeting ONLY the current user's session process
Write-Host "`nRestarting File Explorer for the current user session..." -ForegroundColor Cyan
$CurrentSessionId = (Get-Process -Id $PID).SessionId

$ExplorerProcesses = Get-Process -Name explorer
foreach ($Proc in $ExplorerProcesses) {
    if ($Proc.SessionId -eq $CurrentSessionId) {
        Stop-Process -Id $Proc.Id -Force
    }
}

Start-Process explorer.exe