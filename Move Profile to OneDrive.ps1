$RestartExplorer = $false

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
if (-not ('KnownFolders' -as [type])) {
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
$hklmDesc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions'

# Known Folder descriptions provide the GUIDs; include hidden folders because Windows
# commonly marks redirected user folders as hidden or reparse points.
$ProfileFolderNames = @(
    Get-ChildItem -LiteralPath $UserProfilePath -Directory -Force |
        Where-Object {
            $_.FullName -ne $OneDrivePath -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::System)
        } |
        Select-Object -ExpandProperty Name
)

$FolderCandidates = @(
    foreach ($node in Get-ChildItem -LiteralPath $hklmDesc) {
        $props = Get-ItemProperty -LiteralPath $node.PSPath -ErrorAction SilentlyContinue

        # Category 4 = KF_CATEGORY_PERUSER; only direct profile children are eligible.
        if ($props.Category -eq 4 -and
            $props.RelativePath -in $ProfileFolderNames -and
            -not $props.ParentFolder) {
            [pscustomobject]@{
                Name         = $props.Name
                RelativePath = $props.RelativePath
                Guid         = $node.PSChildName
            }
        }
    }
)

$DynamicGuidMap = @{}

foreach ($group in ($FolderCandidates | Group-Object -Property RelativePath)) {
    $selected = $group.Group |
        Sort-Object `
        @{ Expression = { if ($_.Name -eq $_.RelativePath) { 0 } else { 1 } } },
        @{ Expression = { $_.Name.Length } } |
        Select-Object -First 1
    $DynamicGuidMap[$group.Name] = $selected.Guid
}

if ($Folder) {
    $UnknownFolders = @($Folder | Where-Object { -not $DynamicGuidMap.ContainsKey($_) })
    if ($UnknownFolders.Count -gt 0) {
        throw "Unknown or undiscovered known folder(s): $($UnknownFolders -join ', ')"
    }

    foreach ($name in @($DynamicGuidMap.Keys)) {
        if ($name -notin $Folder) {
            $DynamicGuidMap.Remove($name)
        }
    }
}

Write-Host "Dynamically discovered $($DynamicGuidMap.Count) Per-User Known Folder(s):" -ForegroundColor Cyan
foreach ($key in $DynamicGuidMap.Keys) {
    Write-Host " - $key : $($DynamicGuidMap[$key])"
}
Write-Host ''

# 4. Copy and verify files before updating the Location tab
function Get-FileSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $root = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName.TrimEnd('\', '/')
    $snapshot = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop) {
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            continue
        }

        $relativePath = $file.FullName.Substring($root.Length).TrimStart('\', '/')
        $snapshot[$relativePath] = '{0}:{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
    }

    return $snapshot
}

foreach ($folderName in $DynamicGuidMap.Keys) {
    $guidString = $DynamicGuidMap[$folderName]
    $guid = [Guid]::Parse($guidString)

    $oldPath = Join-Path -Path "$UserProfilePath" -ChildPath "$folderName"
    $newPath = Join-Path -Path "$OneDrivePath" -ChildPath "$folderName"
    $folderRedirected = $false

    if (Test-Path -LiteralPath $oldPath) {
        $sourceItem = Get-Item -LiteralPath $oldPath -Force -ErrorAction Stop
        if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Warning "Skipping '$folderName': '$oldPath' is already a junction or symbolic link."
            continue
        }
    }

    if (-not (Test-Path -LiteralPath $newPath)) {
        New-Item -ItemType Directory -Path $newPath -Force | Out-Null
    }

    if (Test-Path -LiteralPath $oldPath) {
        Write-Host "Copying contents of '$folderName' to '$newPath'..." -ForegroundColor Yellow

        $roboArgs = @(
            "$oldPath",
            "$newPath",
            '/E',
            '/XJ',
            '/COPY:DAT',
            '/DCOPY:DAT',
            '/R:1',
            '/W:1',
            '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NP'
        )
        & robocopy.exe @roboArgs | Out-Null
        $robocopyExitCode = $LASTEXITCODE
        if ($robocopyExitCode -ge 8) {
            Write-Warning "Robocopy failed for '$folderName' with exit code $robocopyExitCode. The source was retained and the folder was not redirected."
            continue
        }

        try {
            $sourceSnapshot = Get-FileSnapshot -Path $oldPath
            $targetSnapshot = Get-FileSnapshot -Path $newPath
            $mismatches = @(
                foreach ($relativePath in $sourceSnapshot.Keys) {
                    if (-not $targetSnapshot.ContainsKey($relativePath) -or
                        $targetSnapshot[$relativePath] -ne $sourceSnapshot[$relativePath]) {
                        $relativePath
                    }
                }
            )
        } catch {
            Write-Warning "Could not verify the copy of '$folderName': $_. The source was retained and the folder was not redirected."
            continue
        }

        if ($mismatches.Count -gt 0) {
            Write-Warning "Copy verification failed for '$folderName' ($($mismatches.Count) file(s) missing or different). The source was retained and the folder was not redirected."
            continue
        }

        if ($folderName -eq 'Documents') {
            $junctionCleanupFailed = $false
            foreach ($junctionName in @('My Pictures', 'My Music', 'My Videos')) {
                $junctionPath = Join-Path -Path $oldPath -ChildPath $junctionName
                $junction = Get-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
                if ($null -ne $junction -and ($junction.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    & $env:ComSpec /d /c rmdir "$junctionPath" | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Could not remove legacy junction '$junctionPath' (exit code $LASTEXITCODE). The source was retained and the folder was not redirected."
                        $junctionCleanupFailed = $true
                        break
                    }
                }
            }
            if ($junctionCleanupFailed) {
                continue
            }
        }

        try {
            [KnownFolders]::SHSetKnownFolderPath($guid, 0, [IntPtr]::Zero, $newPath)
            $folderRedirected = $true
            Write-Host "Updated Location Tab for '$folderName' -> '$newPath'" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to update Location Tab for '$folderName': $_. The verified copy remains at '$newPath'; the source was retained."
            continue
        }

        try {
            Remove-Item -LiteralPath $oldPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "The folder was redirected, but the old source '$oldPath' could not be fully removed: $_"
        }
    } else {
        try {
            [KnownFolders]::SHSetKnownFolderPath($guid, 0, [IntPtr]::Zero, $newPath)
            $folderRedirected = $true
            Write-Host "Updated Location Tab for '$folderName' -> '$newPath' (source folder was absent)." -ForegroundColor Green
        } catch {
            Write-Warning "Failed to update Location Tab for '$folderName': $_"
        }
    }

    if ($folderRedirected -and -not (Test-Path -LiteralPath $oldPath)) {
        try {
            New-Item -ItemType Junction -Path $oldPath -Target $newPath -ErrorAction Stop | Out-Null
            $junction = Get-Item -LiteralPath $oldPath -Force -ErrorAction Stop
            $junction.Attributes = $junction.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
            Write-Host "Created profile junction '$oldPath' -> '$newPath'" -ForegroundColor Green
        } catch {
            Write-Warning "Could not create profile junction '$oldPath': $_"
        }
    }
}

# 5. Create compatibility junctions with original Hidden/System attributes and Deny ACL
Write-Host "`nCreating legacy compatibility junctions in OneDrive Documents..." -ForegroundColor Cyan
$OneDriveDocs = Join-Path -Path "$OneDrivePath" -ChildPath 'Documents'
$OneDrivePics = Join-Path -Path "$OneDrivePath" -ChildPath 'Pictures'
$OneDriveMusic = Join-Path -Path "$OneDrivePath" -ChildPath 'Music'
$OneDriveVids = Join-Path -Path "$OneDrivePath" -ChildPath 'Videos'

if ((-not $Folder -or 'Documents' -in $Folder) -and (Test-Path -LiteralPath $OneDriveDocs)) {
    $compatLinks = @(
        @{ Name = 'My Pictures'; Target = $OneDrivePics },
        @{ Name = 'My Music'; Target = $OneDriveMusic },
        @{ Name = 'My Videos'; Target = $OneDriveVids }
    )

    foreach ($link in $compatLinks) {
        $linkPath = Join-Path -Path "$OneDriveDocs" -ChildPath $link.Name
        if (-not (Test-Path -LiteralPath $linkPath) -and (Test-Path -LiteralPath $link.Target)) {
            try {
                New-Item -ItemType Junction -Path $linkPath -Target $link.Target -ErrorAction Stop | Out-Null
                $item = Get-Item -LiteralPath $linkPath -Force -ErrorAction Stop
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System

                & icacls.exe $linkPath /l /deny 'Everyone:(RD)' | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "icacls failed with exit code $LASTEXITCODE"
                }

                Write-Host " - Replicated legacy stub for: $($link.Name)" -ForegroundColor Green
            } catch {
                Write-Warning "Could not fully create compatibility junction '$linkPath': $_"
            }
        }
    }
}

# 6. Restart File Explorer targeting ONLY the current user's session process
if ($RestartExplorer) {
    Write-Host "`nRestarting File Explorer for the current user session..." -ForegroundColor Cyan
    $CurrentSessionId = (Get-Process -Id $PID).SessionId

    $ExplorerProcesses = Get-Process -Name explorer -ErrorAction SilentlyContinue
    foreach ($Proc in $ExplorerProcesses) {
        if ($Proc.SessionId -eq $CurrentSessionId) {
            Stop-Process -Id $Proc.Id -Force -ErrorAction Stop
        }
    }

    Start-Process explorer.exe
}