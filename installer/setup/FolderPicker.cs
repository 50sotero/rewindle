using System;
using System.Runtime.InteropServices;

namespace Rewindle.Setup
{
    // The folder chooser Windows shows everywhere else (address bar, search, a window that can be resized, "New folder"), the
    // same interop the dashboard's add-folder step uses. It only ever returns a file system folder (FOS_FORCEFILESYSTEM), never a
    // library or another virtual folder. What comes back is only a suggestion: the page still checks it and so does the installer.
    // An empty string means the person cancelled. If the shell dialog cannot be created, the older tree-style chooser is used.
    internal static class FolderPicker
    {
        public static string Pick(IntPtr owner, string title, string okButtonLabel, string legacyDescription)
        {
            try
            {
                IFileOpenDialog dialog = CreateFileOpenDialog();
                try
                {
                    uint options;
                    if (dialog.GetOptions(out options) < 0)
                    {
                        options = 0;
                    }
                    options |= FileOpenDialogOptions.PickFolders |
                        FileOpenDialogOptions.ForceFileSystem |
                        FileOpenDialogOptions.PathMustExist |
                        FileOpenDialogOptions.NoChangeDirectory;
                    dialog.SetOptions(options);
                    dialog.SetTitle(title);
                    dialog.SetOkButtonLabel(okButtonLabel);
                    int result = dialog.Show(owner);
                    if (result == HResult.Cancelled)
                    {
                        return string.Empty;
                    }
                    if (result < 0)
                    {
                        Marshal.ThrowExceptionForHR(result);
                    }
                    IShellItem item;
                    int getResult = dialog.GetResult(out item);
                    if (getResult < 0)
                    {
                        Marshal.ThrowExceptionForHR(getResult);
                    }
                    try
                    {
                        IntPtr displayName;
                        int displayResult = item.GetDisplayName(ShellItemDisplayName.DesktopAbsoluteParsing, out displayName);
                        if (displayResult < 0)
                        {
                            Marshal.ThrowExceptionForHR(displayResult);
                        }
                        try
                        {
                            return Marshal.PtrToStringUni(displayName);
                        }
                        finally
                        {
                            if (displayName != IntPtr.Zero)
                            {
                                Marshal.FreeCoTaskMem(displayName);
                            }
                        }
                    }
                    finally
                    {
                        if (item != null && Marshal.IsComObject(item))
                        {
                            Marshal.FinalReleaseComObject(item);
                        }
                    }
                }
                finally
                {
                    if (Marshal.IsComObject(dialog))
                    {
                        Marshal.FinalReleaseComObject(dialog);
                    }
                }
            }
            catch (COMException)
            {
                return ShowLegacy(owner, legacyDescription);
            }
            catch (InvalidCastException)
            {
                return ShowLegacy(owner, legacyDescription);
            }
        }

        private static string ShowLegacy(IntPtr owner, string description)
        {
            using (System.Windows.Forms.FolderBrowserDialog picker = new System.Windows.Forms.FolderBrowserDialog())
            {
                picker.Description = description;
                picker.RootFolder = Environment.SpecialFolder.MyComputer;
                picker.ShowNewFolderButton = true;
                return picker.ShowDialog(new NativeWindowHandle(owner)) == System.Windows.Forms.DialogResult.OK
                    ? picker.SelectedPath
                    : string.Empty;
            }
        }

        private sealed class NativeWindowHandle : System.Windows.Forms.IWin32Window
        {
            public NativeWindowHandle(IntPtr handle)
            {
                Handle = handle;
            }

            public IntPtr Handle { get; private set; }
        }

        private static class FileOpenDialogOptions
        {
            internal const uint NoChangeDirectory = 0x00000008;
            internal const uint PathMustExist = 0x00000800;
            internal const uint ForceFileSystem = 0x00000040;
            internal const uint PickFolders = 0x00000020;
        }

        private static class ShellItemDisplayName
        {
            internal const uint DesktopAbsoluteParsing = 0x80028000;
        }

        private static class HResult
        {
            internal const int Cancelled = unchecked((int)0x800704C7);
        }

        [ComImport]
        [Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        [ClassInterface(ClassInterfaceType.None)]
        private sealed class FileOpenDialogClass
        {
        }

        [ComImport]
        [Guid("D57C7288-D4AD-4768-BE02-9D969532D960")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileOpenDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            [PreserveSig] int SetFileTypes(uint count, IntPtr filters);
            [PreserveSig] int SetFileTypeIndex(uint index);
            [PreserveSig] int GetFileTypeIndex(out uint index);
            [PreserveSig] int Advise(IntPtr events, out uint cookie);
            [PreserveSig] int Unadvise(uint cookie);
            [PreserveSig] int SetOptions(uint options);
            [PreserveSig] int GetOptions(out uint options);
            [PreserveSig] int SetDefaultFolder(IShellItem item);
            [PreserveSig] int SetFolder(IShellItem item);
            [PreserveSig] int GetFolder(out IShellItem item);
            [PreserveSig] int GetCurrentSelection(out IShellItem item);
            [PreserveSig] int SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            [PreserveSig] int GetFileName(out IntPtr name);
            [PreserveSig] int SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            [PreserveSig] int SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            [PreserveSig] int SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            [PreserveSig] int GetResult(out IShellItem item);
            [PreserveSig] int AddPlace(IShellItem item, uint alignment);
            [PreserveSig] int SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
            [PreserveSig] int Close(int result);
            [PreserveSig] int SetClientGuid(ref Guid guid);
            [PreserveSig] int ClearClientData();
            [PreserveSig] int SetFilter(IntPtr filter);
        }

        [ComImport]
        [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            [PreserveSig] int BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid riid, out IntPtr ppv);
            [PreserveSig] int GetParent(out IShellItem parent);
            [PreserveSig] int GetDisplayName(uint sigdnName, out IntPtr name);
            [PreserveSig] int GetAttributes(uint attributes, out uint result);
            [PreserveSig] int Compare(IShellItem item, uint hint, out int result);
        }

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int CoCreateInstance(
            ref Guid clsid,
            IntPtr outer,
            uint context,
            ref Guid iid,
            out IFileOpenDialog instance);

        private static IFileOpenDialog CreateFileOpenDialog()
        {
            Guid clsid = new Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7");
            Guid iid = new Guid("D57C7288-D4AD-4768-BE02-9D969532D960");
            IFileOpenDialog dialog;
            int result = CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref iid, out dialog);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
            return dialog;
        }
    }
}
