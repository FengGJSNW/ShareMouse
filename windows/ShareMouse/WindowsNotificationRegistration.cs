using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
namespace ShareMouse;
internal static class WindowsNotificationRegistration {
    internal const string AppID="ShareMouse.Desktop.Development";
    internal static void Prepare() {
        var executable=Environment.ProcessPath??throw new InvalidOperationException();
        var directory=Environment.GetFolderPath(Environment.SpecialFolder.Programs); Directory.CreateDirectory(directory);
        var shortcut=Path.Combine(directory,"ShareMouse Development.lnk"); var shell=new ShellLink();
        try { var link=(IShellLink)shell; var persist=(IPersistFile)shell;
            if(File.Exists(shortcut)) { persist.Load(shortcut,0); var existing=new StringBuilder(1024); link.GetPath(existing,existing.Capacity,IntPtr.Zero,0); if(!string.Equals(existing.ToString(),executable,StringComparison.OrdinalIgnoreCase)) throw new IOException("Existing shortcut points to another installation."); }
            link.SetPath(executable); link.SetWorkingDirectory(Path.GetDirectoryName(executable)!); link.SetDescription("ShareMouse desktop sharing");
            var key=new PropertyKey { Format=new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),Id=5 }; var value=new PropVariant { Type=31,Pointer=Marshal.StringToCoTaskMemUni(AppID) };
            try { var store=(IPropertyStore)shell; store.SetValue(ref key,ref value); store.Commit(); persist.Save(shortcut,true); } finally { Marshal.FreeCoTaskMem(value.Pointer); }
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppID));
        } finally { Marshal.FinalReleaseComObject(shell); }
    }
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
    [ComImport,Guid("00021401-0000-0000-C000-000000000046")] private class ShellLink { }
    [StructLayout(LayoutKind.Sequential)] private struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit,Size=24)] private struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }
    [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IPropertyStore {
        void GetCount(out uint count); void GetAt(uint index,out PropertyKey key); void GetValue(ref PropertyKey key,out PropVariant value); void SetValue(ref PropertyKey key,ref PropVariant value); void Commit();
    }
    [ComImport,Guid("000214F9-0000-0000-C000-000000000046"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IShellLink {
        void GetPath([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int count,IntPtr data,uint flags);
        void GetIDList(out IntPtr list); void SetIDList(IntPtr list);
        void GetDescription([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int count); void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetWorkingDirectory([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int count); void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        void GetArguments([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int count); void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetHotkey(out short key); void SetHotkey(short key); void GetShowCmd(out int command); void SetShowCmd(int command);
        void GetIconLocation([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int count,out int index); void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path,int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path,uint reserved); void Resolve(IntPtr hwnd,uint flags); void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
}
