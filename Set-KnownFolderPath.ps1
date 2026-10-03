$Code = @'
using System;
using System.Runtime.InteropServices;

namespace KnownFolderRedirector
{
    public class Redirector
    {
        public static void RedirectFolder(string folderGuidString, string newPath)
        {
            Guid folderGuid = new Guid(folderGuidString);

            KF_REDIRECT_FLAGS flags = KF_REDIRECT_FLAGS.KF_REDIRECT_COPY_CONTENTS |
                                      KF_REDIRECT_FLAGS.KF_REDIRECT_DEL_SOURCE_CONTENTS |
                                      KF_REDIRECT_FLAGS.KF_REDIRECT_OWNER_USER;

            IKnownFolderManager manager = (IKnownFolderManager)new KnownFolderManager();

            string errorMsg;
            manager.Redirect(
                ref folderGuid,
                IntPtr.Zero,
                flags,
                newPath,
                0,
                IntPtr.Zero,
                out errorMsg);
        }
    }

    [ComImport, Guid("4df0c730-df9d-4ae3-9153-aa6b82e9795a")]
    public class KnownFolderManager { }

    [ComImport, Guid("8BE2D872-86AA-4d47-B776-32CCA40C7018"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IKnownFolderManager
    {
        void FolderIdFromCsidl(int nCsidl, out Guid pfid);
        void FolderIdToCsidl([In] ref Guid rfid, out int pnCsidl);
        void GetFolderIds(out IntPtr ppKFId, out uint pCount);
        void GetFolder([In] ref Guid rfid, [MarshalAs(UnmanagedType.Interface)] out object ppkf);
        void GetFolderByName(string pszCanonicalName, out object ppkf);
        void RegisterFolder([In] ref Guid rfid, IntPtr pKFD);
        void UnregisterFolder([In] ref Guid rfid);
        void FindFolderFromPath(string pszPath, int mode, out object ppkf);
        void FindFolderFromIDList(IntPtr pidl, out object ppkf);

        void Redirect(
            [In] ref Guid rfid,
            [In] IntPtr hwnd,
            [In] KF_REDIRECT_FLAGS flags,
            [In, MarshalAs(UnmanagedType.LPWStr)] string pszTargetPath,
            [In] uint cFolders,
            [In] IntPtr pExclusion,
            [Out, MarshalAs(UnmanagedType.LPWStr)] out string ppszError);
    }

    [Flags]
    public enum KF_REDIRECT_FLAGS : uint
    {
        KF_REDIRECT_USER_EXCLUSIVE = 0x00000001,
        KF_REDIRECT_COPY_SOURCE_DACL = 0x00000002,
        KF_REDIRECT_OWNER_USER = 0x00000004,
        KF_REDIRECT_SET_CLIENT_GUID = 0x00000008,
        KF_REDIRECT_KEEP_PINNED = 0x00000010,
        KF_REDIRECT_EXCLUDE_ALL_KNOWN_SUBFOLDERS = 0x00000020,
        KF_REDIRECT_WITH_UI = 0x00000040,
        KF_REDIRECT_UNPIN = 0x00000080,
        KF_REDIRECT_PIN = 0x00000100,
        KF_REDIRECT_COPY_CONTENTS = 0x00000200,
        KF_REDIRECT_DEL_SOURCE_CONTENTS = 0x00000400,
        KF_REDIRECT_CHECK_ONLY = 0x00000800
    }
}
'@

# Compile the COM redirector once in the session
Add-Type -TypeDefinition $Code

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
            $Root = if ($Parent -in '{DF457347-3E29-4378-A67E-692640243293}', 'DF457347-3E29-4378-A67E-692640243293') {
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