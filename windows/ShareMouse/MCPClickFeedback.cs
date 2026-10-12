using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace ShareMouse;

// Passive, click-through presentation. No native cursor replacement or intermediate
// input injection. Only unrelated click endpoints may use a curve; moves stay straight.
internal sealed class MCPClickFeedback {
    private Window? window;
    private readonly Pulse visual=new();
    private readonly Stopwatch clock=new();
    private bool rendering,moving,curved;
    private Point from,target;
    private double duration;
    private void EnsureWindow() {
        if(window is not null)return;
        window=new Window {Width=56,Height=56,WindowStyle=WindowStyle.None,ResizeMode=ResizeMode.NoResize,
            AllowsTransparency=true,Background=Brushes.Transparent,ShowInTaskbar=false,ShowActivated=false,
            Topmost=true,Focusable=false,IsHitTestVisible=false,Tag="MCP presentation",Content=visual};
        window.SourceInitialized+=(_,_)=> {
            var handle=new WindowInteropHelper(window).Handle;
            SetWindowLongW(handle,-20,GetWindowLongW(handle,-20)|0x08000020);
            HwndSource.FromHwnd(handle)?.AddHook(NoActivation);
        };
    }
    public int Preview(int x,int y,string kind) {
        if(!Theme.Motion || !GetCursorPos(out var source)) {Stop();return 0;}
        from=new Point(source.X,source.Y);target=new Point(x,y);
        var distance=(target-from).Length;
        if(distance<=3) {Stop();return 0;}
        duration=Math.Clamp(.13+distance/4600,.16,.34);
        curved=kind is "click" or "double_click";moving=true;
        visual.Pointer=true;visual.Progress=0;
        Start(from);return (int)Math.Ceiling(duration*1000);
    }
    public void Show(int x,int y) {
        moving=false;visual.Pointer=false;visual.Reduced=!Theme.Motion;visual.Progress=0;
        duration=visual.Reduced?.2:.55;Start(new Point(x,y));
    }
    private void Start(Point point) {
        EnsureWindow();visual.InvalidateVisual();window!.Show();Position(point);clock.Restart();
        if(!rendering) {CompositionTarget.Rendering+=Frame;rendering=true;}
    }
    private void Position(Point point) {
        var hwnd=new WindowInteropHelper(window!).Handle;
        // Physical pixels, including negative origins. Re-read DPI after crossing monitors.
        for(var pass=0;pass<2;pass++) {
            var size=(int)Math.Round(56*GetDpiForWindow(hwnd)/96.0);
            SetWindowPos(hwnd,new IntPtr(-1),(int)Math.Round(point.X)-size/2,(int)Math.Round(point.Y)-size/2,size,size,0x0010);
        }
    }
    private void Frame(object? sender,EventArgs e) {
        var t=Math.Clamp(clock.Elapsed.TotalSeconds/duration,0,1);visual.Progress=t;
        if(moving) {
            var eased=t*t*t*(t*(t*6-15)+10);var u=1-eased;
            var x=curved?3*u*u*eased*.25+3*u*eased*eased*.75+eased*eased*eased:eased;
            var y=curved?3*u*u*eased*.08+3*u*eased*eased*.92+eased*eased*eased:eased;
            Position(new Point(from.X+(target.X-from.X)*x,from.Y+(target.Y-from.Y)*y));
        }
        visual.InvalidateVisual();
        // A cancelled preview must never leave a stuck overlay, even if no marker follows.
        if((!moving && t>=1) || clock.Elapsed.TotalSeconds>duration+.1)Stop();
    }
    public void Stop() {
        if(rendering) {CompositionTarget.Rendering-=Frame;rendering=false;}
        clock.Stop();moving=false;window?.Hide();
    }
    private static IntPtr NoActivation(IntPtr hwnd,int msg,IntPtr w,IntPtr l,ref bool handled) {
        if(msg==0x21) {handled=true;return new IntPtr(3);}
        if(msg==0x84) {handled=true;return new IntPtr(-1);}
        return IntPtr.Zero;
    }
    private sealed class Pulse:FrameworkElement {
        private static readonly Geometry Arrow=Geometry.Parse("M 0,0 C -.4,-.4 -1,0 -.8,.7 L 4.65,14.4 Q 5.5,15.2 6.25,14.35 L 8.85,8.85 L 14.35,6.25 Q 15.2,5.5 14.4,4.65 Z");
        public double Progress;
        public bool Reduced,Pointer;
        protected override void OnRender(DrawingContext dc) {
            var center=new Point(ActualWidth/2,ActualHeight/2);
            if(Pointer) {
                dc.PushTransform(new TranslateTransform(center.X,center.Y));
                dc.DrawGeometry(Brushes.Black,new Pen(Brushes.White,.9),Arrow);
                dc.DrawEllipse(Theme.Brush("Accent"),new Pen(Brushes.White,.7),new Point(12,12),2,2);
                dc.Pop();return;
            }
            var t=Progress;var radius=Reduced?12:3.5+14*(1-Math.Pow(1-t,3));
            dc.PushOpacity((1-t)*(1-t)*.8);
            dc.DrawEllipse(null,new Pen(Theme.Brush("Accent"),1.1),center,radius,radius);dc.Pop();
        }
    }
    [StructLayout(LayoutKind.Sequential)]private struct CursorPoint {public int X,Y;}
    [DllImport("user32.dll")]private static extern bool GetCursorPos(out CursorPoint point);
    [DllImport("user32.dll")]private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]private static extern int GetWindowLongW(IntPtr hwnd,int index);
    [DllImport("user32.dll")]private static extern int SetWindowLongW(IntPtr hwnd,int index,int value);
    [DllImport("user32.dll")]private static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
}
