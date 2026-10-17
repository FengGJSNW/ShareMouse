using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ShareMouse;

internal static class WindowsPowerMode
{
    internal static Guid Overlay(int mode) => mode switch
    {
        0 => Guid.Empty,
        1 => new Guid("ded574b5-45a0-4f42-8737-46345c09c238"),
        2 => new Guid("961cc777-2547-4f9d-8174-7d86181b8a7a"),
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    };
    internal static int? Mode(Guid overlay) => overlay == Overlay(0) ? 0 : overlay == Overlay(1) ? 1 : overlay == Overlay(2) ? 2 : null;
    internal static Guid Read()
    {
        var status = PowerGetEffectiveOverlayScheme(out var overlay);
        if (status != 0)
            throw new Win32Exception((int)status);
        return overlay;
    }
    internal static bool Apply(int mode)
    {
        var desired = Overlay(mode);
        var status = PowerSetActiveOverlayScheme(desired);
        if (status != 0)
            throw new Win32Exception((int)status);
        return Read() == desired;
    }
    [DllImport("powrprof.dll")] private static extern uint PowerGetEffectiveOverlayScheme(out Guid overlay);
    [DllImport("powrprof.dll")] private static extern uint PowerSetActiveOverlayScheme(Guid overlay);
}
