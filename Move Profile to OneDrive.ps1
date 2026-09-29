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

if (-not ('DownloadsShellFileOperation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

[ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem
{
    [PreserveSig] int BindToHandler(IntPtr bindContext, ref Guid handlerId, ref Guid interfaceId, out IntPtr result);
    [PreserveSig] int GetParent(out IShellItem parent);
    [PreserveSig] int GetDisplayName(uint displayNameType, out IntPtr displayName);
    [PreserveSig] int GetAttributes(uint attributeMask, out uint attributes);
    [PreserveSig] int Compare(IShellItem other, uint hint, out int order);
}

[ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IFileOperation
{
    [PreserveSig] int Advise(IntPtr progressSink, out uint cookie);
    [PreserveSig] int Unadvise(uint cookie);
    [PreserveSig] int SetOperationFlags(uint flags);
    [PreserveSig] int SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
    [PreserveSig] int SetProgressDialog(IntPtr progressDialog);
    [PreserveSig] int SetProperties(IntPtr properties);
    [PreserveSig] int SetOwnerWindow(IntPtr window);
    [PreserveSig] int ApplyPropertiesToItem(IShellItem item, IntPtr progressSink);
    [PreserveSig] int ApplyPropertiesToItems(IntPtr items, IntPtr progressSink);
    [PreserveSig] int RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
    [PreserveSig] int RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string newName);
    [PreserveSig] int MoveItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
    [PreserveSig] int MoveItems(IntPtr items, IShellItem destination);
    [PreserveSig] int CopyItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
    [PreserveSig] int CopyItems(IntPtr items, IShellItem destination);
    [PreserveSig] int DeleteItem(IShellItem item, IntPtr progressSink);
    [PreserveSig] int DeleteItems(IntPtr items, IntPtr progressSink);
    [PreserveSig] int NewItem(IShellItem destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string templateName, IntPtr progressSink);
    [PreserveSig] int PerformOperations();
    [PreserveSig] int GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
}

public static class DownloadsShellFileOperation
{
    private static readonly Guid ShellItemId = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
    private static readonly Guid FileOperationClassId = new Guid("3AD05575-8857-4850-9277-11B85BDB8E09");

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path,
        IntPtr bindContext,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint apartmentModel);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    public static void MoveContents(string sourcePath, string destinationPath)
    {
        Exception failure = null;
        Thread thread = new Thread(() =>
        {
            bool initialized = false;
            try
            {
                int initializeResult = CoInitializeEx(IntPtr.Zero, 2);
                if (initializeResult < 0)
                    Marshal.ThrowExceptionForHR(initializeResult);
                initialized = true;

                MoveContentsOnStaThread(sourcePath, destinationPath);
            }
            catch (Exception exception)
            {
                failure = exception;
            }
            finally
            {
                if (initialized)
                    CoUninitialize();
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure != null)
            throw new InvalidOperationException("The Shell file operation failed.", failure);
    }

    private static void MoveContentsOnStaThread(string sourcePath, string destinationPath)
    {
        IFileOperation operation = null;
        IShellItem destination = null;
        try
        {
            Type operationType = Type.GetTypeFromCLSID(FileOperationClassId, true);
            operation = (IFileOperation)Activator.CreateInstance(operationType);
            Check(operation.SetOperationFlags(0x0040 | 0x0200));
            Guid shellItemId = ShellItemId;
            SHCreateItemFromParsingName(destinationPath, IntPtr.Zero, ref shellItemId, out destination);

            foreach (string childPath in Directory.EnumerateFileSystemEntries(sourcePath))
            {
                IShellItem source = null;
                try
                {
                    shellItemId = ShellItemId;
                    SHCreateItemFromParsingName(childPath, IntPtr.Zero, ref shellItemId, out source);
                    Check(operation.MoveItem(source, destination, null, IntPtr.Zero));
                }
                finally
                {
                    if (source != null && Marshal.IsComObject(source))
                        Marshal.FinalReleaseComObject(source);
                }
            }

            Check(operation.PerformOperations());
            bool aborted;
            Check(operation.GetAnyOperationsAborted(out aborted));
            if (aborted)
                throw new OperationCanceledException("The Shell move operation was canceled.");
        }
        finally
        {
            if (destination != null && Marshal.IsComObject(destination))
                Marshal.FinalReleaseComObject(destination);
            if (operation != null && Marshal.IsComObject(operation))
                Marshal.FinalReleaseComObject(operation);
        }
    }

    private static void Check(int result)
    {
        if (result < 0)
            Marshal.ThrowExceptionForHR(result);
    }
}
'@
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
    $sourceSnapshot = Get-DownloadsFileSnapshot -Path $SourceDownloadsPath
    Write-Host "Moving Downloads contents from '$SourceDownloadsPath' to '$DownloadsPath'..." -ForegroundColor Yellow
    [DownloadsShellFileOperation]::MoveContents($SourceDownloadsPath, $DownloadsPath)

    $remainingItems = @(Get-ChildItem -LiteralPath $SourceDownloadsPath -Force -ErrorAction Stop)
    if ($remainingItems.Count -gt 0) {
        throw "The Shell operation left $($remainingItems.Count) item(s) in the original Downloads folder. The Known Folder location was not changed."
    }

    $targetSnapshot = Get-DownloadsFileSnapshot -Path $DownloadsPath
    $mismatches = @(
        foreach ($relativePath in $sourceSnapshot.Keys) {
            if ($sourceSnapshot[$relativePath] -notin $targetSnapshot.Values) {
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
    $remainingItems = @(Get-ChildItem -LiteralPath $SourceDownloadsPath -Force -ErrorAction Stop)
    if ($remainingItems.Count -eq 0) {
        Remove-Item -LiteralPath $SourceDownloadsPath -Force -ErrorAction Stop
    }
}

Write-Host "Downloads moved to '$DownloadsPath' and its Known Folder location was updated." -ForegroundColor Green
