using System;
using System.Collections.Generic;
using System.Linq;
using System.Security;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;
using ShareMouse.Core;
namespace ShareMouse;
internal interface NotificationRenderer { void Show(string id,string title,string message,double? progress,bool persistent); void Hide(string id); void Stop(); }
internal sealed class NativeRenderer : NotificationRenderer {
    private ToastNotifier? notifier;
    private readonly Dictionary<string,uint> sequences=new(); private readonly HashSet<string> hidden=new();
    public bool Available=>notifier is not null;
    public bool Enable() { try { WindowsNotificationRegistration.Prepare(); var value=ToastNotificationManager.CreateToastNotifier(WindowsNotificationRegistration.AppID); if(value.Setting!=NotificationSetting.Enabled) return false; notifier=value; return true; } catch { return false; } }
    private static string Tag(string id)=>id.Replace("-","")[..Math.Min(16,id.Replace("-","").Length)];
    public void Show(string id,string title,string message,double? progress,bool persistent) {
        if(notifier is null || hidden.Contains(id)) return; var tag=Tag(id);
        var data=new NotificationData { SequenceNumber=sequences.GetValueOrDefault(id)+1 }; data.Values["progress"]=(progress??1).ToString(System.Globalization.CultureInfo.InvariantCulture); data.Values["label"]=$"{(int)((progress??1)*100)}%"; data.Values["status"]=title; data.Values["title"]=title; data.Values["message"]=message;
        if(progress is not null && sequences.ContainsKey(id) && notifier.Update(data,tag,"ShareMouse")==NotificationUpdateResult.Succeeded) { sequences[id]=data.SequenceNumber; return; }
        var xml=new XmlDocument(); xml.LoadXml("<toast><visual><binding template=\"ToastGeneric\"><text>{title}</text><text>{message}</text>"+(progress is null?"":"<progress value=\"{progress}\" valueStringOverride=\"{label}\" status=\"{status}\"/>")+"</binding></visual></toast>");
        var toast=new ToastNotification(xml) { Tag=tag,Group="ShareMouse",Data=data }; if(!persistent) toast.ExpirationTime=DateTimeOffset.UtcNow.AddSeconds(10);
        toast.Dismissed+=(_,e)=> { if(e.Reason==ToastDismissalReason.UserCanceled) Application.Current.Dispatcher.BeginInvoke(()=>hidden.Add(id)); };
        sequences[id]=data.SequenceNumber; notifier.Show(toast);
    }
    public void Hide(string id) { try { ToastNotificationManager.History.Remove(Tag(id),"ShareMouse",WindowsNotificationRegistration.AppID); } catch { } sequences.Remove(id); }
    public void Stop() { foreach(var id in sequences.Keys.ToArray()) Hide(id); hidden.Clear(); }
}
internal sealed class CustomRenderer : NotificationRenderer {
    public string Corner="bottomRight";
    private readonly Dictionary<string,Window> windows=new(); private readonly HashSet<string> hidden=new(); private readonly Dictionary<string,DispatcherTimer> timers=new(); private readonly List<string> order=new();
    private Window GetWindow(string id,bool textOnly=false) {
        if(windows.TryGetValue(id,out var existing)) return existing;
        var window=new Window { Width=330,Height=156,WindowStyle=WindowStyle.None,ResizeMode=ResizeMode.NoResize,AllowsTransparency=true,Background=Brushes.Transparent,ShowInTaskbar=false,ShowActivated=false,Topmost=true };
        if(textOnly) { window.Focusable=false;window.SourceInitialized+=(_,_)=> { if(HwndSource.FromHwnd(new WindowInteropHelper(window).Handle) is {} source) source.AddHook(PreventActivation); }; }
        windows[id]=window;order.Add(id);return window;
    }
    private static IntPtr PreventActivation(IntPtr handle,int message,IntPtr wParam,IntPtr lParam,ref bool handled) {
        if(message==0x21) { handled=true;return new IntPtr(3); } // WM_MOUSEACTIVATE -> MA_NOACTIVATE; clicks still reach the text links.
        return IntPtr.Zero;
    }
    public void Show(string id,string title,string message,double? progress,bool persistent) {
        if(hidden.Contains(id)) return;
        var window=GetWindow(id);
        var body=new StackPanel { Margin=new Thickness(16) }; var heading=new DockPanel();
        var hide=new Button { Content="×",Padding=new Thickness(5,0,5,0),HorizontalAlignment=HorizontalAlignment.Right };hide.Click+=(_,_)=> { hidden.Add(id); Hide(id); };DockPanel.SetDock(hide,Dock.Right);heading.Children.Add(hide);
        heading.Children.Add(new TextBlock { Text=title,FontWeight=FontWeights.SemiBold }); body.Children.Add(heading);
        foreach(var line in message.Split('\n')) body.Children.Add(new TextBlock {Text=line,TextWrapping=TextWrapping.NoWrap,TextTrimming=TextTrimming.CharacterEllipsis,FontSize=12,Margin=new Thickness(0,3,0,0)}); if(progress is not null) body.Children.Add(new ProgressBar { Value=progress.Value,Maximum=1,Height=5 });
        window.Content=new Border { CornerRadius=new CornerRadius(14),Background=Theme.Brush("Surface"),BorderThickness=new Thickness(1),BorderBrush=Theme.Brush("Border"),Child=body };Present(id,window,persistent);
    }
    public void ShowMCP(string id,string title,string message,bool persistent,Action? exit,Action hide) {
        var window=GetWindow(id,textOnly:true);
        var body=new StackPanel { Margin=new Thickness(2) };var heading=new DockPanel();
        var hideLink=TextLink("隐藏",hide);DockPanel.SetDock(hideLink,Dock.Right);heading.Children.Add(hideLink);
        if(exit is not null) { var exitLink=TextLink("退出接管",exit);DockPanel.SetDock(exitLink,Dock.Right);heading.Children.Add(exitLink); }
        var titleText=MCPText(title,14);titleText.FontWeight=FontWeights.SemiBold;heading.Children.Add(titleText);body.Children.Add(heading);
        var lines=message.Split('\n');foreach(var line in lines) { var text=MCPText(line,12);text.Margin=new Thickness(0,3,0,0);body.Children.Add(text); }
        window.Height=25+lines.Length*19;window.Content=body;Present(id,window,persistent);
    }
    private static TextBlock MCPText(string text,double size)=>new() { Text=text,FontSize=size,Foreground=Brushes.White,TextTrimming=TextTrimming.CharacterEllipsis,VerticalAlignment=VerticalAlignment.Center,Effect=new DropShadowEffect {Color=Colors.Black,BlurRadius=2,ShadowDepth=0,Opacity=1} };
    private static Button TextLink(string title,Action action) {
        var label=MCPText(title,12);label.TextDecorations=TextDecorations.Underline;label.Margin=new Thickness(8,0,0,0);
        var button=new Button { Content=label,Focusable=false,Cursor=System.Windows.Input.Cursors.Hand,Background=Brushes.Transparent,BorderThickness=new Thickness(0),Padding=new Thickness(0),Margin=new Thickness(0) };
        button.Template=new ControlTemplate(typeof(Button)) { VisualTree=new FrameworkElementFactory(typeof(ContentPresenter)) };button.Click+=(_,_)=>action();return button;
    }
    private void Present(string id,Window window,bool persistent) {
        Arrange();window.Show();
        if(persistent && timers.Remove(id,out var previousTimer)) previousTimer.Stop();
        if(!persistent && !timers.ContainsKey(id)) { var timer=new DispatcherTimer { Interval=TimeSpan.FromSeconds(5) }; timers[id]=timer; timer.Tick+=(_,_)=>Hide(id); timer.Start(); }
    }
    private void Arrange() { var screen=System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Control.MousePosition).WorkingArea; var scale=Application.Current.MainWindow is {} main?System.Windows.Media.VisualTreeHelper.GetDpi(main).DpiScaleX:1; var x=screen.X/scale; var y=screen.Y/scale; var width=screen.Width/scale; var height=screen.Height/scale;
        var offset=20.0;foreach(var id in order) { var window=windows[id];window.Left=Corner.EndsWith("Right",StringComparison.Ordinal)?x+width-window.Width-20:x+20;window.Top=Corner.StartsWith("top",StringComparison.Ordinal)?y+offset:y+height-offset-window.Height;offset+=window.Height+10; }
    }
    public void Hide(string id) { if(windows.Remove(id,out var window)) window.Close(); order.Remove(id); if(timers.Remove(id,out var timer)) timer.Stop(); Arrange(); }
    public void Stop() { foreach(var id in windows.Keys.ToArray()) Hide(id); hidden.Clear(); }
}
public sealed class NotificationService : IDisposable {
    private readonly NativeRenderer native=new(); private readonly CustomRenderer custom=new(); private readonly LocalPreferences preferences; private readonly Dictionary<string,string> signatures=new();
    public NotificationService(LocalPreferences preferences) { this.preferences=preferences;ticker.Tick+=(_,_)=>RefreshTransfers(); }
    public bool Configure() { native.Stop(); custom.Stop(); signatures.Clear(); custom.Corner=preferences.Corner;RefreshMCPPresentation();return preferences.Renderer!="native" || native.Enable(); }
    private NotificationRenderer Renderer=>preferences.Renderer=="native" && native.Available?native:custom;
    private readonly Dictionary<string,HashSet<string>> previousLinks=new(),seenLinks=new();
    private readonly Dictionary<string,(string Name,HashSet<string> Labels)> pendingLinks=new();
    private readonly Dictionary<string,DispatcherTimer> linkTimers=new();
    public void Connections(SessionInfo[] sessions) {
        var alive=sessions.Select(s=>s.PeerID).ToHashSet();foreach(var peer in previousLinks.Keys.Where(p=>!alive.Contains(p)).ToArray())previousLinks[peer]=[];
        foreach(var item in sessions) {
            HashSet<string> current=[];if(item.Capabilities.Contains("tcp")||item.Capabilities.Contains("quic"))current.Add("Wi-Fi");if(item.Capabilities.Contains("ble"))current.Add("蓝牙");
            previousLinks.TryGetValue(item.PeerID,out var previous);var seen=seenLinks.GetValueOrDefault(item.PeerID)??[];
            previousLinks[item.PeerID]=current;seenLinks[item.PeerID]=seen.Union(current).ToHashSet();if(previous is null)continue;
            var labels=current.Except(previous).Select(k=>k+" 链路"+(seen.Contains(k)?"已重连":"已连接")).ToHashSet();if(labels.Count==0)continue;
            if(pendingLinks.TryGetValue(item.PeerID,out var pending))labels.UnionWith(pending.Labels);pendingLinks[item.PeerID]=(item.Name,labels);
            if(linkTimers.Remove(item.PeerID,out var old))old.Stop();
            var timer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(600)};linkTimers[item.PeerID]=timer;
            timer.Tick+=(_,_)=> {timer.Stop();linkTimers.Remove(item.PeerID);if(pendingLinks.Remove(item.PeerID,out var value))Toast("设备链路",value.Name+"\n"+string.Join(" · ",value.Labels.Order()));};timer.Start();
        }
    }
    public void InputReconnected(SessionInfo[] sessions,bool bluetoothPreferred) {
        var lines=sessions.Select(item=>item.Name+" · "+(bluetoothPreferred&&item.Capabilities.Contains("ble")?"蓝牙":item.Capabilities.Contains("quic")?"Wi-Fi（QUIC）":item.Capabilities.Contains("tcp")?"Wi-Fi（TCP）":"蓝牙")+" 链路").ToArray();
        if(lines.Length>0)Toast("键鼠重连完成",string.Join("\n",lines));
    }
    public void Toast(string title,string message) { custom.Corner=preferences.Corner; try { Renderer.Show(Guid.NewGuid().ToString("D"),title,message,null,false); } catch { custom.Show(Guid.NewGuid().ToString("D"),title,message,null,false); } }
    private string? mcpControlID,mcpNoticeID;
    public Action ExitMCPControl {get;set;}=()=>{};
    public Action HideMCPToast {get;set;}=()=>{};
    private long? lastMCPNotice;
    private long mcpNoticeShownAt;
    private string mcpNoticeTitle="",mcpNoticeMessage="";
    public void RefreshMCPPresentation() {
        custom.Corner=preferences.Corner;
        if(mcpControlID is {} control) { custom.Hide(control);if(preferences.McpToastStyle!="hidden") custom.ShowMCP(control,"MCP 正在被使用中","AI 正在截图并控制本机",true,ExitMCPControl,HideMCPToast); }
        if(mcpNoticeID is {} notice) {
            custom.Hide(notice);
            if(preferences.McpToastStyle!="hidden"&&mcpControlID is null&&System.Diagnostics.Stopwatch.GetElapsedTime(mcpNoticeShownAt).TotalSeconds<5) custom.ShowMCP(notice,mcpNoticeTitle,mcpNoticeMessage,false,null,HideMCPToast);
            else mcpNoticeID=null;
        }
    }
    private void ShowMCPNotice(string title,string message) {
        if(mcpNoticeID is {} previous) custom.Hide(previous);mcpNoticeID=null;
        if(preferences.McpToastStyle=="hidden") return;
        mcpNoticeID=Guid.NewGuid().ToString("D");mcpNoticeTitle=title;mcpNoticeMessage=message;mcpNoticeShownAt=System.Diagnostics.Stopwatch.GetTimestamp();custom.Corner=preferences.Corner;
        custom.ShowMCP(mcpNoticeID,title,message,false,null,HideMCPToast);
    }
    public void MCPActivity() {
        var now=System.Diagnostics.Stopwatch.GetTimestamp();
        if(preferences.McpToastStyle=="hidden"||mcpControlID is not null||lastMCPNotice is {} previous&&System.Diagnostics.Stopwatch.GetElapsedTime(previous,now).TotalSeconds<30)return;
        lastMCPNotice=now;ShowMCPNotice("MCP 正在读取本机","AI 正在通过 ShareMouse 读取本机信息");
    }
    public void MCPControl(bool active,string reason) {
        if(mcpNoticeID is {} notice){custom.Hide(notice);mcpNoticeID=null;}
        if(active){mcpControlID??=Guid.NewGuid().ToString("D");RefreshMCPPresentation();return;}
        if(mcpControlID is {} old){custom.Hide(old);mcpControlID=null;}
        if(reason!="server_stopped"){
            var message=reason switch{"user_exit"=>"你已退出 MCP 接管，本机输入已恢复","lease_expired"=>"控制会话空闲到期，已恢复键鼠共享","peer_disconnected"=>"远端设备已断开","screen_changed"=>"屏幕配置已变化","computer_access_disabled"=>"电脑操控权限已关闭","input_permission_or_desktop_unavailable"=>"输入权限丢失或桌面已锁定","capture_failed"=>"截图未能完成","closed"=>"AI 已释放电脑控制",_=>"控制会话已结束"};
            ShowMCPNotice("MCP 操控已结束",message);
        }
    }
    private sealed record Sample(long Bytes,long Time,string State,double Rate=0);
    private readonly Dictionary<string,Sample> samples=new();
    private readonly Dictionary<string,long> shownAt=new();
    private readonly Dictionary<string,string> restoredStates=new();
    public void RestoreTransfers(TransferTask[] tasks) {latest=tasks;restoredStates.Clear();foreach(var task in tasks) restoredStates[task.Id]=task.State;}
    private TransferTask[] latest=[];
    private readonly DispatcherTimer ticker=new() {Interval=TimeSpan.FromSeconds(1)};
    public void Transfers(TransferTask[] tasks) { latest=tasks;RefreshTransfers();if(tasks.Any(t=>t.State=="running")) ticker.Start();else ticker.Stop(); }
    private void RefreshTransfers() {
        custom.Corner=preferences.Corner;
        foreach(var task in latest) {
            if(restoredStates.TryGetValue(task.Id,out var restored)) {if(task.State==restored) continue;restoredStates.Remove(task.Id);}
            var active=task.State is "running" or "queued" or "paused";
            if(!signatures.ContainsKey(task.Id)&&!active) continue;
            var now=System.Diagnostics.Stopwatch.GetTimestamp();var sample=samples.GetValueOrDefault(task.Id)??new(task.Received,now,task.State);
            if(task.State!="running" || sample.State!="running" || task.Received<sample.Bytes) sample=new(task.Received,now,task.State);
            else { var elapsed=System.Diagnostics.Stopwatch.GetElapsedTime(sample.Time,now).TotalSeconds;if(elapsed>=1) sample=new(task.Received,now,task.State,Math.Max(0,task.Received-sample.Bytes)/elapsed); }
            samples[task.Id]=sample;
            var state=task.State switch {"running"=>"正在传输","queued"=>"排队中","paused"=>"已暂停","completed"=>"已完成","failed"=>"传输失败","cancelled"=>"已取消",_=>task.State};
            var title=(task.Direction=="send"?"发送文件":"接收文件")+" · "+state;
            var current=task.Files.FirstOrDefault(f=>!f.Item.Directory&&!f.Completed&&!f.Skipped)??task.Files.FirstOrDefault(f=>f.Item.Id==f.Item.RootID);
            var name=current is null?"正在获取文件清单…":System.IO.Path.GetFileName(current.Item.RelativePath.Replace('/',System.IO.Path.DirectorySeparatorChar));
            var percent=Math.Clamp((int)((double)task.Received/Math.Max(1,task.Total)*100),0,100);
            var transport=task.Transport switch {"tcp"=>"网络 TCP","quic"=>"网络 QUIC","ble"=>"蓝牙 BLE",_=>"等待链路"};
            var message=name+"\n"+Bytes(task.Received)+" / "+Bytes(task.Total)+$" · {percent}%\n"+Bytes(sample.Rate)+"/s · "+transport+(task.Error is null?"":"\n"+task.Error);
            var signature=task.State+":"+message;if(signatures.GetValueOrDefault(task.Id)==signature) continue;
            if(signatures.GetValueOrDefault(task.Id)?.StartsWith(task.State+":",StringComparison.Ordinal)==true && shownAt.TryGetValue(task.Id,out var shown) && System.Diagnostics.Stopwatch.GetElapsedTime(shown,now).TotalSeconds<1) continue;
            signatures[task.Id]=signature;shownAt[task.Id]=now;
            try {Renderer.Show(task.Id,title,message,active?percent/100.0:null,active);}catch {custom.Show(task.Id,title,message,active?percent/100.0:null,active);}
        }
    }
    private static string Bytes(double value)=>value>=1_000_000_000?$"{value/1_000_000_000:F1} GB":value>=1_000_000?$"{value/1_000_000:F1} MB":value>=1_000?$"{value/1_000:F1} KB":$"{value:F0} B";
    public void Dispose() { foreach(var timer in linkTimers.Values)timer.Stop();linkTimers.Clear();pendingLinks.Clear(); ticker.Stop();native.Stop(); custom.Stop(); }
}
