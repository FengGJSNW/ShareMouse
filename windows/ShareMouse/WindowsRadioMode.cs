using System;
using System.Runtime.InteropServices;

namespace ShareMouse;

// System radio state, not a keyboard shortcut or registry imitation of airplane mode.
// Interface layout verified against wintouchg and RadioMan; availability is checked at runtime.
internal static class WindowsRadioMode
{
    [ComImport, Guid("DB3AFBFB-08E6-46C6-AA70-BF9A34C30AB7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IRadioManager
    {
        [PreserveSig] int IsRMSupported(out uint supported);
        [PreserveSig] int GetUIRadioInstances(out IntPtr instances);
        [PreserveSig] int GetSystemRadioState(out int enabled, out int hardwareState, out int reason);
        [PreserveSig] int SetSystemRadioState(int enabled);
    }
    internal static int Read() => Execute(false);
    internal static int Toggle() => Execute(true);
    private static int Execute(bool toggle)
    {
        var initialized = CoInitializeEx(IntPtr.Zero, 0);
        IRadioManager? manager = null;
        try
        {
            if (initialized < 0 && initialized != unchecked((int)0x80010106))
                Marshal.ThrowExceptionForHR(initialized);
            var clsid = new Guid("581333F6-28DB-41BE-BC7A-FF201F12F3F6");
            var iid = typeof(IRadioManager).GUID;
            Marshal.ThrowExceptionForHR(CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out manager));
            Marshal.ThrowExceptionForHR(manager.IsRMSupported(out var supported));
            if (supported == 0)
                throw new NotSupportedException("System radio control unavailable");
            Marshal.ThrowExceptionForHR(manager.GetSystemRadioState(out var enabled, out _, out _));
            if (enabled is not (0 or 1))
                throw new NotSupportedException("Unknown system radio state");
            if (toggle)
            {
                enabled = enabled == 0 ? 1 : 0;
                Marshal.ThrowExceptionForHR(manager.SetSystemRadioState(enabled));
            }
            return enabled;
        }
        finally { if (manager is not null) Marshal.FinalReleaseComObject(manager); if (initialized >= 0) CoUninitialize(); }
    }
    [DllImport("ole32.dll")] private static extern int CoInitializeEx(IntPtr reserved, uint mode);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("ole32.dll")] private static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IRadioManager manager);
}
