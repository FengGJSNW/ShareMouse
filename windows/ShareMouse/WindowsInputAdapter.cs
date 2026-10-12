using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using ShareMouse.Core;

namespace ShareMouse;

public sealed class WindowsInputAdapter : IDisposable {
    private readonly string id;
    private readonly HwndSource window;
    private readonly HookProc keyboardProc, mouseProc;
    private IntPtr keyboardHook, mouseHook;
    private bool suppressPhysical, cursorHidden;
    private double relativeRemainderX,relativeRemainderY;
    private bool receivingRelative;
    private double wheelRemainderX,wheelRemainderY;
    private readonly Action<string> diagnostic;
    private long slowInjectionAt;
    private int scrollInjected,scrollHooked;private double scrollNativeMaxMs,scrollNativeTotalMs;private long scrollReportAt;
    private int relativeInjected; private long relativeDiagnosticAt; private double relativeInjectedX,relativeInjectedY;
    [StructLayout(LayoutKind.Sequential)] private struct CursorInfo { public uint Size,Flags;public IntPtr Cursor;public Point Position; }
    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CursorInfo info);
    public bool RelativePointerCaptured {get {var info=new CursorInfo {Size=(uint)Marshal.SizeOf<CursorInfo>()};return !cursorHidden&&GetCursorInfo(ref info)&&(info.Flags&1)==0;}}

    private HwndSource? cursorCover;
    private readonly Dictionary<uint,CapturedInput> fallbackMoves=[];
    private long rawMotionAt;
    private bool timerResolution;
    private Point? hookPosition;
    private readonly HashSet<string> injectedKeys=[];
    public Func<CapturedInput, bool>? Captured;
    public Action? ScreensChanged;
    private static readonly UIntPtr marker = new(0x534d494e);
    public WindowsInputAdapter(string id, HwndSource window, Action<string>? diagnostic=null) { this.id = id; this.window = window; this.diagnostic=diagnostic??(_=>{}); keyboardProc = Keyboard; mouseProc = Mouse; window.AddHook(Message); AppDomain.CurrentDomain.ProcessExit+=RestoreOnExit; AppDomain.CurrentDomain.UnhandledException+=RestoreOnFailure; }
    public void Start() {
        if (keyboardHook != IntPtr.Zero) return;
        // Recover the configured scheme if a previous run left replaced cursors behind.
        if (!SystemParametersInfoW(0x57, 0, IntPtr.Zero, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if(cursorCover is null) {
            cursorCover = new HwndSource(new HwndSourceParameters("ShareMouse cursor cover") {
                Width=32, Height=32, WindowStyle=unchecked((int)0x80000000),
                ExtendedWindowStyle=0x08000080, UsesPerPixelOpacity=true }); // NOACTIVATE | TOOLWINDOW
            cursorCover.CompositionTarget.BackgroundColor=System.Windows.Media.Colors.Transparent;
            // Explicit per-pixel alpha: a bare HwndSource may paint an opaque black surface.
            // Alpha 1 keeps hit testing for WM_SETCURSOR while remaining visually transparent.
            cursorCover.RootVisual=new System.Windows.Controls.Border { Width=32,Height=32,
                Background=new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(1,0,0,0)) };
            cursorCover.AddHook(CursorCoverMessage);
        }
        timerResolution=timeBeginPeriod(1)==0;
        keyboardHook = SetWindowsHookExW(13, keyboardProc, GetModuleHandleW(null), 0);
        mouseHook = SetWindowsHookExW(14, mouseProc, GetModuleHandleW(null), 0);
        var raw = new[] { new RawDevice { UsagePage = 1, Usage = 2, Flags = 0x100, Target = window.Handle } };
        if (keyboardHook == IntPtr.Zero || mouseHook == IntPtr.Zero || !RegisterRawInputDevices(raw, 1, (uint)Marshal.SizeOf<RawDevice>())) {
            StopCapture(); throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
    private IntPtr Keyboard(int code, IntPtr message, IntPtr data) {
        if (code >= 0) {
            var value = Marshal.PtrToStructure<KeyboardHook>(data);
            if (value.Extra != marker) {
                var vk = value.Key;
                if (vk == 16) vk = value.Scan == 0x36 ? 161u : 160u;
                if (vk == 17) vk = (value.Flags & 1) != 0 ? 163u : 162u;
                if (vk == 18) vk = (value.Flags & 1) != 0 ? 165u : 164u;
                var name = vk == 13 && (value.Flags & 1) != 0 ? "NumpadEnter" : keyNames.GetValueOrDefault(vk);
                var kind = message.ToInt32() is 0x100 or 0x104 ? "keyDown" : "keyUp";
                if (name is not null && Captured?.Invoke(new(kind, name)) == true) return new IntPtr(1);
            }
        }
        return CallNextHookEx(keyboardHook, code, message, data);
    }
    private IntPtr Mouse(int code, IntPtr message, IntPtr data) {
        if (code >= 0) {
            var value = Marshal.PtrToStructure<MouseHook>(data);
            if(value.Extra==marker && message.ToInt32() is 0x20A or 0x20E)scrollHooked++;
            if (value.Extra != marker) {
                var kind = message.ToInt32();
                if(kind==0x200) {
                    // A captured game may warp its cursor. Let that software movement reach
                    // the game, but don't recapture it as a physical ownership claim.
                    if(receivingRelative&&suppressPhysical)return CallNextHookEx(mouseHook,code,message,data);
                    GetCursorPos(out var previous);
                    var anchor=suppressPhysical?previous:(hookPosition??previous);
                    hookPosition=value.Point;
                    var dx=value.Point.X-anchor.X; var dy=value.Point.Y-anchor.Y;
                    if(dx!=0 || dy!=0) {
                        var display=System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(value.Point.X,value.Point.Y)); var bounds=display.Bounds;
                        var movement=new CapturedInput("move",DeltaX:dx,DeltaY:dy,HardwareMotion:false,ScreenID:id+":"+display.DeviceName,
                            X:Math.Clamp((value.Point.X-bounds.X)/(double)Math.Max(1,bounds.Width-1),0,1),Y:Math.Clamp((value.Point.Y-bounds.Y)/(double)Math.Max(1,bounds.Height-1),0,1));
                        // Touchpad-generated moves have no matching RAWMOUSE. Delay their fallback
                        // two milliseconds so a hardware raw report can remove the duplicate.
                        if((value.Flags&1)!=0) Captured?.Invoke(movement);
                        else { fallbackMoves[value.Time]=movement; _=FallbackMove(value.Time); }
                    }
                    if(suppressPhysical) return new IntPtr(1);
                }
                CapturedInput? input = kind switch {
                    0x201 => new("buttonDown", Button:0), 0x202 => new("buttonUp", Button:0),
                    0x204 => new("buttonDown", Button:1), 0x205 => new("buttonUp", Button:1),
                    0x207 => new("buttonDown", Button:2), 0x208 => new("buttonUp", Button:2),
                    0x20A => new("scroll", DeltaY:(short)(value.MouseData >> 16) / 3.0),
                    0x20E => new("scroll", DeltaX:(short)(value.MouseData >> 16) / 3.0), _ => null };
                if (input is not null && Captured?.Invoke(input) == true) return new IntPtr(1);
            }
        }
        return CallNextHookEx(mouseHook, code, message, data);
    }
    private IntPtr Message(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (message == 0x7E) ScreensChanged?.Invoke();
        if (message != 0xFF) return IntPtr.Zero;
        uint size = 0; var headerSize = (uint)Marshal.SizeOf<RawHeader>();
        if (GetRawInputData(lParam, 0x10000003, IntPtr.Zero, ref size, headerSize) != 0 || size < headerSize + 24) return IntPtr.Zero;
        var buffer = Marshal.AllocHGlobal((int)size);
        try {
            if (GetRawInputData(lParam, 0x10000003, buffer, ref size, headerSize) != size) return IntPtr.Zero;
            var header = Marshal.PtrToStructure<RawHeader>(buffer);
            if (header.Type != 0) return IntPtr.Zero;
            var offset = (int)headerSize;
            if ((Marshal.ReadInt16(buffer, offset) & 1) != 0) return IntPtr.Zero;
            var timestamp=unchecked((uint)GetMessageTime()); fallbackMoves.Remove(timestamp); rawMotionAt=Environment.TickCount64;
            if(unchecked((uint)Marshal.ReadInt32(buffer,offset+20))==marker.ToUInt32()) return IntPtr.Zero;
            var dx = Marshal.ReadInt32(buffer, offset + 12); var dy = Marshal.ReadInt32(buffer, offset + 16);
            if (dx == 0 && dy == 0) return IntPtr.Zero;
            GetCursorPos(out var point);
            var display = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(point.X, point.Y));
            var bounds = display.Bounds;
            Captured?.Invoke(new("move", DeltaX:dx, DeltaY:dy, HardwareMotion:header.Device!=IntPtr.Zero, ScreenID:id + ":" + display.DeviceName,
                X:(point.X - bounds.X) / (double)Math.Max(1,bounds.Width-1), Y:(point.Y - bounds.Y) / (double)Math.Max(1,bounds.Height-1)));
        } finally { Marshal.FreeHGlobal(buffer); }
        return IntPtr.Zero;
    }
    public void Inject(CapturedInput value, ScreenGeometry? screen, double x, double y) {
        var started=System.Diagnostics.Stopwatch.GetTimestamp();
        double permissionMs=0;
        try { InjectNative(value,screen,x,y,out permissionMs); }
        finally {
            var elapsed=System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            var now=Environment.TickCount64;
            if(value.Type=="scroll") {
                scrollInjected++;scrollNativeTotalMs+=elapsed;scrollNativeMaxMs=Math.Max(scrollNativeMaxMs,elapsed);
                if(now-scrollReportAt>=5000) {
                    scrollReportAt=now;
                    var report=$"InputScrollNativeDelivery calls={scrollInjected} hookCallbacks={scrollHooked} averageMs={scrollNativeTotalMs/scrollInjected:F2} maxMs={scrollNativeMaxMs:F2}";
                    window.Dispatcher.BeginInvoke(()=>diagnostic(report));scrollInjected=scrollHooked=0;scrollNativeTotalMs=scrollNativeMaxMs=0;
                }
            }
            if(elapsed>8 && now-slowInjectionAt>=5000) {
                slowInjectionAt=now;
                var message=$"InputNativeSlow type={value.Type} durationMs={elapsed:F0} permissionMs={permissionMs:F0}";
                window.Dispatcher.BeginInvoke(()=>diagnostic(message));
            }
        }
    }
    private void InjectNative(CapturedInput value, ScreenGeometry? screen, double x, double y,out double permissionMs) {
        permissionMs=0;
        if(value.Type=="relativeBegin"){receivingRelative=true;return;}
        if(value.Type=="relativeEnd"){receivingRelative=false;relativeRemainderX=relativeRemainderY=0;return;}
        if(value.Type!="relativeReset") {
            var started=System.Diagnostics.Stopwatch.GetTimestamp();
            try {WindowsInputStatus.EnsureCanInject();}
            finally {permissionMs=System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds;}
        }
        if(value.Type=="command" || value.Type=="text") {
            var saved=KeyboardMapping.Modifiers.Where(key=>injectedKeys.Contains(key)||(GetAsyncKeyState((int)keyNames.First(p=>p.Value==key).Key)&0x8000)!=0).ToArray();
            var events=new List<NativeInput>(); NativeInput Key(string key,bool down)=>new() { Type=1,Data=new() { Keyboard=new() { Key=(ushort)keyNames.First(p=>p.Value==key).Key,Flags=(down?0u:2u)|(key is "ControlRight" or "AltRight" or "MetaLeft" or "MetaRight"?1u:0u),Extra=marker } } };
            var desktopCommand=value.Command is "desktopPrevious" or "desktopNext" or "overview";
            foreach(var key in saved) if(!desktopCommand || !key.StartsWith("Meta",StringComparison.Ordinal)) events.Add(Key(key,false));
            if(value.Type=="text" && value.Text is {} text && System.Text.Encoding.UTF8.GetByteCount(text)<=4096) {
                foreach(var unit in text) { events.Add(new() { Type=1,Data=new() { Keyboard=new() { Scan=unit,Flags=4,Extra=marker } } }); events.Add(new() { Type=1,Data=new() { Keyboard=new() { Scan=unit,Flags=6,Extra=marker } } }); }
            } else if(value.Command is "desktopPrevious" or "desktopNext" or "overview") {
                var key=value.Command=="overview"?"Tab":value.Command=="desktopPrevious"?"ArrowLeft":"ArrowRight";
                var meta=saved.FirstOrDefault(k=>k.StartsWith("Meta",StringComparison.Ordinal))??"MetaLeft"; var heldMeta=saved.Contains(meta);
                if(!heldMeta) events.Add(Key(meta,true)); if(value.Command!="overview") events.Add(Key("ControlLeft",true));
                events.Add(Key(key,true)); events.Add(Key(key,false)); if(value.Command!="overview") events.Add(Key("ControlLeft",false)); if(!heldMeta) events.Add(Key(meta,false));
            } else { var key=value.Command switch { "copy"=>"KeyC", "cut"=>"KeyX", "paste"=>"KeyV", "undo"=>"KeyZ", "redo"=>"KeyY", _=>null }; if(key is null) return;
                events.Add(Key("ControlLeft",true)); events.Add(Key(key,true)); events.Add(Key(key,false)); events.Add(Key("ControlLeft",false)); }
            foreach(var key in saved) if(!desktopCommand || !key.StartsWith("Meta",StringComparison.Ordinal)) events.Add(Key(key,true));
            var batch=events.ToArray();var result=WindowsInputPump.Send(()=>SendInput((uint)batch.Length,batch,Marshal.SizeOf<NativeInput>()));
            if(result.Count!=(uint)events.Count) { foreach(var modifier in KeyboardMapping.Modifiers) try { Send(Key(modifier,false)); } catch { }; foreach(var commandKey in new[] {"KeyC","KeyX","KeyV","KeyZ","KeyY"}) try { Send(Key(commandKey,false)); } catch { }; throw new Win32Exception(result.Error); }; return;
        }
        var input = new NativeInput();
        if (value.Type is "keyDown" or "keyUp" && value.Key is { } nativeKey) {
            var pair = keyNames.FirstOrDefault(p => p.Value == nativeKey); var vk = nativeKey == "NumpadEnter" ? 13u : pair.Key;
            if (vk == 0) return;
            input.Type = 1; input.Data.Keyboard = new KeyboardInput { Key = (ushort)vk,
                Flags = (value.Type == "keyUp" ? 2u : 0u) | (nativeKey is "NumpadEnter" or "ControlRight" or "AltRight" or "MetaLeft" or "MetaRight" or "Home" or "End" or "PageUp" or "PageDown" or "Delete" or "Insert" or "PrintScreen" or "ContextMenu" || nativeKey.StartsWith("Arrow", StringComparison.Ordinal) ? 1u : 0u), Extra = marker };
        } else if(value.Type=="relativeReset") {receivingRelative=true;relativeRemainderX=relativeRemainderY=0;return;
        } else if(value.Type=="relativeMove") {
            if(!double.IsFinite(value.DeltaX)||!double.IsFinite(value.DeltaY)||Math.Abs(value.DeltaX)>10000||Math.Abs(value.DeltaY)>10000)return;
            relativeRemainderX+=value.DeltaX;relativeRemainderY+=value.DeltaY;
            var dx=(int)Math.Truncate(relativeRemainderX);var dy=(int)Math.Truncate(relativeRemainderY);relativeRemainderX-=dx;relativeRemainderY-=dy;if(dx==0&&dy==0)return;
            input.Data.Mouse=new MouseInput {X=dx,Y=dy,Flags=1,Extra=marker};
        } else if (value.Type == "move" && screen is not null) {
            var display = System.Windows.Forms.Screen.AllScreens.FirstOrDefault(s => id + ":" + s.DeviceName == screen.Id) ?? throw new InvalidOperationException("Display removed.");
            var px = display.Bounds.X + Math.Clamp(x, 0, .99999) * display.Bounds.Width;
            var py = display.Bounds.Y + Math.Clamp(y, 0, .99999) * display.Bounds.Height;
            input.Data.Mouse = new MouseInput { X=(int)Math.Round((px - GetSystemMetrics(76)) * 65535 / Math.Max(1, GetSystemMetrics(78) - 1)),
                Y=(int)Math.Round((py - GetSystemMetrics(77)) * 65535 / Math.Max(1, GetSystemMetrics(79) - 1)), Flags=0x8000 | 0x4000 | 0x2000 | 1, Extra=marker };
        } else if (value.Type is "buttonDown" or "buttonUp") {
            var down = value.Type == "buttonDown"; var flag = value.Button switch { 0 => down ? 2u : 4u, 1 => down ? 8u : 16u, 2 => down ? 32u : 64u, _ => 0u };
            if (flag == 0) return; input.Data.Mouse = new MouseInput { Flags=flag, Extra=marker };
        } else if (value.Type == "scroll") {
            wheelRemainderY+=value.DeltaY*3;wheelRemainderX+=value.DeltaX*3;
            var wy=(int)Math.Truncate(wheelRemainderY);var wx=(int)Math.Truncate(wheelRemainderX);wheelRemainderY-=wy;wheelRemainderX-=wx;
            if(wy!=0)Send(new NativeInput {Data=new InputUnion {Mouse=new MouseInput {Flags=0x800,MouseData=unchecked((uint)wy),Extra=marker}}});
            if(wx==0)return;input.Data.Mouse=new MouseInput {Flags=0x1000,MouseData=unchecked((uint)wx),Extra=marker};
        } else return;
        Send(input);
        if(value.Type=="relativeMove") {
            relativeInjected++;relativeInjectedX+=input.Data.Mouse.X;relativeInjectedY+=input.Data.Mouse.Y;
            var now=Environment.TickCount64;if(now-relativeDiagnosticAt>=5000) {relativeDiagnosticAt=now;diagnostic($"RelativeNativeDelivery frames={relativeInjected} dx={relativeInjectedX:F2} dy={relativeInjectedY:F2} elevated={WindowsInputStatus.IsElevated}");relativeInjected=0;relativeInjectedX=relativeInjectedY=0;}
        }
        if(value.Key is {} tracked && value.Type is "keyDown" or "keyUp") { if(value.Type=="keyDown") injectedKeys.Add(tracked); else injectedKeys.Remove(tracked); }
    }
    private static void Send(NativeInput input) {
        var result=WindowsInputPump.Send(()=>SendInput(1,[input],Marshal.SizeOf<NativeInput>()));
        if(result.Count!=1)throw new Win32Exception(result.Error);
    }
    private async System.Threading.Tasks.Task FallbackMove(uint time) {
        await System.Threading.Tasks.Task.Delay(2);
        if(fallbackMoves.Remove(time,out var value) && !(receivingRelative&&suppressPhysical) && Environment.TickCount64-rawMotionAt>30 && mouseHook!=IntPtr.Zero) Captured?.Invoke(value);
    }
    public void CursorState(bool remoteTarget, bool restrictPhysical) {
        if(!restrictPhysical)receivingRelative=false;
        if(suppressPhysical!=restrictPhysical) hookPosition=null;
        suppressPhysical=restrictPhysical;
        if(cursorHidden==remoteTarget) return;
        if(remoteTarget && cursorCover is not null) {
            GetCursorPos(out var point);
            // A nearly transparent hit-testable window owns only the parked cursor.
            // Physical input is already suppressed by our hooks. Never activate it.
            SetWindowPos(cursorCover.Handle,new IntPtr(-1),point.X-16,point.Y-16,32,32,0x50);
            SetCursor(IntPtr.Zero); cursorHidden=true;
        } else if(!remoteTarget) {
            if(cursorCover is not null) ShowWindow(cursorCover.Handle,0);
            SetCursor(LoadCursorW(IntPtr.Zero,new IntPtr(32512))); cursorHidden=false;
        }
    }
    private IntPtr CursorCoverMessage(IntPtr hwnd,int message,IntPtr wParam,IntPtr lParam,ref bool handled) {
        if(message==0x20 && cursorHidden) {SetCursor(IntPtr.Zero);handled=true;return new IntPtr(1);}
        if(message==0x21) {handled=true;return new IntPtr(3);} // MA_NOACTIVATE
        return IntPtr.Zero;
    }

    private void StopCapture() {
        CursorState(false,false); fallbackMoves.Clear(); hookPosition=null;
        if(timerResolution) timeEndPeriod(1); timerResolution=false;
        if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
        if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
        keyboardHook = mouseHook = IntPtr.Zero;
        RegisterRawInputDevices([new RawDevice { UsagePage=1, Usage=2, Flags=1 }], 1, (uint)Marshal.SizeOf<RawDevice>());
    }
    private void RestoreOnExit(object? sender,EventArgs args)=>CursorState(false,false);
    private void RestoreOnFailure(object sender,UnhandledExceptionEventArgs args)=>CursorState(false,false);
    public void Dispose() { StopCapture(); cursorCover?.Dispose(); cursorCover=null; window.RemoveHook(Message); AppDomain.CurrentDomain.ProcessExit-=RestoreOnExit; AppDomain.CurrentDomain.UnhandledException-=RestoreOnFailure; }
    private static readonly Dictionary<uint,string> keyNames = BuildKeys();
    private static Dictionary<uint,string> BuildKeys() {
        var keys = new Dictionary<uint,string> { [8]="Backspace",[9]="Tab",[13]="Enter",[20]="CapsLock",[27]="Escape",[32]="Space",[33]="PageUp",[34]="PageDown",[35]="End",[36]="Home",[37]="ArrowLeft",[38]="ArrowUp",[39]="ArrowRight",[40]="ArrowDown",[44]="PrintScreen",[93]="ContextMenu",[45]="Insert",[46]="Delete",[91]="MetaLeft",[92]="MetaRight",[106]="NumpadMultiply",[107]="NumpadAdd",[109]="NumpadSubtract",[110]="NumpadDecimal",[111]="NumpadDivide",[144]="NumLock",[160]="ShiftLeft",[161]="ShiftRight",[162]="ControlLeft",[163]="ControlRight",[164]="AltLeft",[165]="AltRight",[186]="Semicolon",[187]="Equal",[188]="Comma",[189]="Minus",[190]="Period",[191]="Slash",[192]="Backquote",[219]="BracketLeft",[220]="Backslash",[221]="BracketRight",[222]="Quote" };
        for (uint code=65; code<=90; code++) keys[code]="Key"+(char)code;
        for (uint digit=0; digit<=9; digit++) { keys[48+digit]="Digit"+digit; keys[96+digit]="Numpad"+digit; }
        for (uint function=1; function<=12; function++) keys[111+function]="F"+function;
        return keys;
    }
    private delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardHook { public uint Key,Scan,Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseHook { public Point Point; public uint MouseData,Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct RawHeader { public uint Type,Size; public IntPtr Device,Parameter; }
    [StructLayout(LayoutKind.Sequential)] private struct RawDevice { public ushort UsagePage,Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X,Y; public uint MouseData,Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Key,Scan; public uint Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyboardInput Keyboard; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeInput { public uint Type; public InputUnion Data; }
    [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint period);
    [DllImport("user32.dll")] private static extern int GetMessageTime();
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool SystemParametersInfoW(uint action,uint parameter,IntPtr value,uint flags);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr LoadCursorW(IntPtr instance,IntPtr name);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd,int command);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hwnd,uint color,byte alpha,uint flags);
    [DllImport("user32.dll")] private static extern IntPtr SetCursor(IntPtr cursor);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SetWindowsHookExW(int hook, HookProc callback, IntPtr module, uint thread);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string? module);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, NativeInput[] inputs, int size);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool RegisterRawInputDevices(RawDevice[] devices, uint count, uint size);
    [DllImport("user32.dll")] private static extern uint GetRawInputData(IntPtr input, uint command, IntPtr data, ref uint size, uint headerSize);
}
