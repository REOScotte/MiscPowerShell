$Code = @"
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
"@

# Compile the COM redirector once in session
if (-not ("KnownFolderRedirector.Redirector" -as [type])) {
    Add-Type -TypeDefinition $Code
}

# Pure PowerShell registry-driven GUID lookup
function Get-KnownFolderGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    # If already a valid GUID string, format and return directly
    if ($Name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        return $Name.ToUpper()
    }

    $BaseRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions"
    $FolderKeys = Get-ChildItem -Path $BaseRegPath -ErrorAction SilentlyContinue

    foreach ($Key in $FolderKeys) {
        $Props = Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue

        # Match against canonical Name (e.g., 'Downloads', 'Personal') 
        # or RelativePath (e.g., 'Documents', 'Pictures') defined in registry
        if ($Props.Name -ieq $Name -or $Props.RelativePath -ieq $Name) {
            return $Key.PSChildName.Trim('{', '}').ToUpper()
        }
    }

    throw "Could not find a registered Known Folder matching '$Name' in HKLM Registry."
}

# Redirection execution function
function Set-KnownFolderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Folder,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$NewPath
    )

    $guid = Get-KnownFolderGuid -Name $Folder
    [KnownFolderRedirector.Redirector]::RedirectFolder($guid, $NewPath)
    Write-Host "Successfully redirected '$Folder' [$guid] to: $NewPath"
}