using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using ShareMouse.Core;

namespace ShareMouse;
internal static class WindowsDisplayLayout {
    // DEVMODEW display union; preserve the enumerated mode, changing DM_POSITION only.
    [StructLayout(LayoutKind.Explicit,Size=220)]
    private struct Mode {
        [FieldOffset(68)]public ushort Size;
        [FieldOffset(70)]public ushort DriverExtra;
        [FieldOffset(72)]public uint Fields;
        [FieldOffset(76)]public int X;
        [FieldOffset(80)]public int Y;
        [FieldOffset(84)]public uint Orientation;
        [FieldOffset(88)]public uint FixedOutput;
        [FieldOffset(172)]public uint Width;
        [FieldOffset(176)]public uint Height;
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool EnumDisplaySettings(string device,int mode,ref Mode value);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern int ChangeDisplaySettingsEx(string device,ref Mode mode,IntPtr window,uint flags,IntPtr parameter);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="ChangeDisplaySettingsExW")]private static extern int Commit(string? device,IntPtr mode,IntPtr window,uint flags,IntPtr parameter);
    public static void Apply(ScreenGeometry[] layout,string peerID,string backup) {
        var local=layout.Where(s=>s.PeerID==peerID).ToArray();if(local.Length<2)return;
        var modes=new Dictionary<string,Mode>();var devices=new Dictionary<string,string>();var sizes=new Dictionary<string,(double Width,double Height)>();
        foreach(var screen in local) {
            var device=screen.Id[(peerID.Length+1)..];var mode=new Mode {Size=220};
            if(!EnumDisplaySettings(device,-1,ref mode) || mode.Width==0 || mode.Height==0)throw new IOException("系统屏幕不可用，请重新连接显示器。");
            modes[screen.Id]=mode;devices[screen.Id]=device;sizes[screen.Id]=(mode.Width,mode.Height);
        }
        var plan=ScreenGeometry.NativeLayout(local,sizes)??throw new IOException("同一电脑的屏幕必须相连，且能在系统中保持此排布。");
        var changed=plan.Any(s=>modes[s.Id].X!=s.X || modes[s.Id].Y!=s.Y);if(!changed)return;
        var desired=new Dictionary<string,Mode>();
        foreach(var screen in plan) {
            if(Math.Abs(screen.X)>int.MaxValue || Math.Abs(screen.Y)>int.MaxValue)throw new IOException("屏幕位置超出系统范围。");
            var mode=modes[screen.Id];mode.DriverExtra=0;mode.Fields=0x20;mode.Orientation=0;mode.FixedOutput=0;mode.X=(int)screen.X;mode.Y=(int)screen.Y;
            var result=ChangeDisplaySettingsEx(devices[screen.Id],ref mode,IntPtr.Zero,2,IntPtr.Zero);
            if(result!=0)throw new IOException("系统不支持此屏幕排布，错误码："+result);desired[screen.Id]=mode;
        }
        File.WriteAllText(backup,JsonSerializer.Serialize(local.Select(s=>new {s.Id,Device=devices[s.Id],X=modes[s.Id].X,Y=modes[s.Id].Y})));
        try {
            foreach(var screen in plan) {var mode=desired[screen.Id];var code=ChangeDisplaySettingsEx(devices[screen.Id],ref mode,IntPtr.Zero,0x10000001,IntPtr.Zero);if(code!=0)throw new IOException("保存系统排布失败，错误码："+code+"；可在权限向导中以管理员权限重试。");}
            var committed=Commit(null,IntPtr.Zero,IntPtr.Zero,0,IntPtr.Zero);if(committed!=0)throw new IOException("应用系统排布失败，错误码："+committed);
            foreach(var screen in plan) {var actual=new Mode {Size=220};if(!EnumDisplaySettings(devices[screen.Id],-1,ref actual) || actual.X!=screen.X || actual.Y!=screen.Y)throw new IOException("系统调整了屏幕位置，未能与共享排布匹配。");}
        } catch {
            foreach(var screen in local) {var original=modes[screen.Id];original.DriverExtra=0;original.Fields=0x20;original.Orientation=0;original.FixedOutput=0;ChangeDisplaySettingsEx(devices[screen.Id],ref original,IntPtr.Zero,0x10000001,IntPtr.Zero);}
            Commit(null,IntPtr.Zero,IntPtr.Zero,0,IntPtr.Zero);throw;
        }
    }
}
