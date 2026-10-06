Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace KnownFolderRedirector;

public static class Redirector
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern int SHSetKnownFolderPath([In] ref Guid rfid, uint dwFlags, IntPtr hToken, string pszPath);

    public static void RedirectFolder(string folderGuidString, string newPath)
    {
        var folderGuid = Guid.Parse(folderGuidString);
        int hr = SHSetKnownFolderPath(ref folderGuid, 0, IntPtr.Zero, newPath);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
    }
}
'@

# Resolves a canonical name or legacy registry string to its GUID
function Get-KnownFolderGuidByName {
    param([string]$Name)

    $BaseRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions'
    $FolderKeys = Get-ChildItem -Path $BaseRegPath -ErrorAction SilentlyContinue

    foreach ($Key in $FolderKeys) {
        $Props = Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue
        if ($Props.Name -ieq $Name -or $Props.RelativePath -ieq $Name) {
            return $Key.PSChildName.Trim('{', '}').ToUpper()
        }
    }
    return $null
}

# Dynamically determines the Known Folder GUID given an absolute path
function Get-KnownFolderGuidFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )

    # Normalize input path (expands relative links, trailing slashes, and handles casing)
    $TargetFolder = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    # 1. Scan HKCU User Shell Folders (Current User Active Paths)
    $UserShellReg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $UserProps = Get-ItemProperty -Path $UserShellReg -ErrorAction SilentlyContinue

    if ($UserProps) {
        foreach ($Prop in $UserProps.psobject.Properties) {
            if ($Prop.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }

            $ExpandedPath = [Environment]::ExpandEnvironmentVariables($Prop.Value)
            if (-not [string]::IsNullOrWhiteSpace($ExpandedPath)) {
                $NormalizedRegPath = [System.IO.Path]::GetFullPath($ExpandedPath).TrimEnd('\')

                if ($NormalizedRegPath -ieq $TargetFolder) {
                    # If registry key name is already a GUID (e.g., Downloads)
                    if ($Prop.Name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -or 
                        $Prop.Name -match '^{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}}?$') {
                        return $Prop.Name.Trim('{', '}').ToUpper()
                    }

                    # If registry key name is a legacy string (e.g., 'Personal' for Documents)
                    $ResolvedGuid = Get-KnownFolderGuidByName -Name $Prop.Name
                    if ($ResolvedGuid) { return $ResolvedGuid }
                }
            }
        }
    }

    # 2. Scan HKLM User Shell Folders (Public / Shared Paths)
    $PublicShellReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $PublicProps = Get-ItemProperty -Path $PublicShellReg -ErrorAction SilentlyContinue

    if ($PublicProps) {
        foreach ($Prop in $PublicProps.psobject.Properties) {
            if ($Prop.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }

            $ExpandedPath = [Environment]::ExpandEnvironmentVariables($Prop.Value)
            if (-not [string]::IsNullOrWhiteSpace($ExpandedPath)) {
                $NormalizedRegPath = [System.IO.Path]::GetFullPath($ExpandedPath).TrimEnd('\')

                if ($NormalizedRegPath -ieq $TargetFolder) {
                    if ($Prop.Name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -or 
                        $Prop.Name -match '^{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}}?$') {
                        return $Prop.Name.Trim('{', '}').ToUpper()
                    }

                    $ResolvedGuid = Get-KnownFolderGuidByName -Name $Prop.Name
                    if ($ResolvedGuid) { return $ResolvedGuid }
                }
            }
        }
    }

    # 3. Fallback: Scan HKLM FolderDescriptions default paths (%USERPROFILE% / %PUBLIC%)
    $BaseRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions'
    $FolderKeys = Get-ChildItem -Path $BaseRegPath -ErrorAction SilentlyContinue

    foreach ($Key in $FolderKeys) {
        $Props = Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue
        if ($Props.RelativePath) {
            $Parent = $Props.ParentFolder
            $Root = if ($Parent -in '{DF457347-3E29-4378-A67E-692640243293}', '{DFDF76A2-C82A-4D63-906A-5644AC457385}', '{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}') {
                $env:PUBLIC
            } else {
                $env:USERPROFILE
            }

            $DefaultPath = Join-Path -Path $Root -ChildPath $Props.RelativePath
            $NormalizedDefault = [System.IO.Path]::GetFullPath($DefaultPath).TrimEnd('\')

            if ($NormalizedDefault -ieq $TargetFolder) {
                return $Key.PSChildName.Trim('{', '}').ToUpper()
            }
        }
    }

    throw "Could not determine a Known Folder GUID matching path: '$Path'"
}

# Redirects a folder by supplying its current path directly
function Set-KnownFolderPathByPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$CurrentPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$NewPath
    )

    $guid = Get-KnownFolderGuidFromPath -Path $CurrentPath
    [KnownFolderRedirector.Redirector]::RedirectFolder($guid, $NewPath)
    Write-Host "Successfully redirected path '$CurrentPath' [$guid] to: $NewPath"
}

$userProfile = $env:USERPROFILE

Get-ChildItem -Path $userProfile -Directory | ForEach-Object {
    Set-KnownFolderPathByPath -CurrentPath $_.FullName -NewPath "$env:USERPROFILE\OneDrive\$($_.Name)"
}