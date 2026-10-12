using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using ShareMouse.Core;
using ShareMouse.Network;
namespace ShareMouse;
public sealed class SourceIME : IDisposable {
    private Window? window; private InputService? input; private string? target; private bool composing;
    private readonly HashSet<string> held=[],consumed=[];
    private readonly DispatcherTimer timer=new() { Interval=TimeSpan.FromMilliseconds(200) };
    public Action? ShortcutRequested { get; set; }
    public Func<bool>? CanOpen { get; set; }
    public Action<string[]>? Released { get; set; }
    public SourceIME() { timer.Tick+=(_,_)=> { if(input?.RemoteScreenID!=target) Close(); }; }
    public bool Open(Window owner,InputService input) {
        if(input.RemoteScreenID is not {} target || !input.BeginSourceIME()) return false;
        if(window is not null) { window.Activate(); return true; }
        this.input=input; this.target=target;
        window=new Window { Owner=owner,Title="来源输入法 · 关闭后恢复普通键盘",Width=520,Height=250,WindowStartupLocation=WindowStartupLocation.CenterOwner };
        var body=new StackPanel { Margin=new Thickness(20) }; window.Content=body;
        var status=new TextBlock { Text="候选条留在本机，提交文本进入远端。Ctrl+Alt+Shift+Esc 紧急释放。",TextWrapping=TextWrapping.Wrap }; body.Children.Add(status);
        var text=new TextBox { FontSize=20,Height=130,Margin=new Thickness(0,12,0,0) }; body.Children.Add(text);
        TextCompositionManager.AddPreviewTextInputStartHandler(text,(_,_)=>composing=true);
        TextCompositionManager.AddPreviewTextInputUpdateHandler(text,(_,_)=>composing=true);
        text.PreviewTextInput+=(_,args)=> { composing=false; if(args.Text.Length>0 && !input.CommitText(args.Text,target)) { status.Text="目标已改变；本段未发送"; Close(); }; args.Handled=true; text.Dispatcher.BeginInvoke(()=>text.Clear()); };
        text.PreviewKeyDown+=(_,args)=> { if(composing || args.Key==Key.ImeProcessed) return; var key=args.Key switch { Key.Return=>"Enter",Key.Tab=>"Tab",Key.Back=>"Backspace",Key.Delete=>"Delete",Key.Left=>"ArrowLeft",Key.Right=>"ArrowRight",Key.Up=>"ArrowUp",Key.Down=>"ArrowDown",_=>null }; if(key is not null && input.RemoteScreenID==target) { input.Capture(new("keyDown",key)); input.Capture(new("keyUp",key)); args.Handled=true; } };
        window.Closed+=(_,_)=>Close(); window.Loaded+=(_,_)=>text.Focus(); window.Show(); timer.Start(); return true;
    }
    public bool? Capture(CapturedInput value) {
        if(value.Type is not ("keyDown" or "keyUp") || value.Key is not {} key) return null;
        if(value.Type=="keyDown") held.Add(key); else held.Remove(key);
        if(value.Type=="keyUp" && consumed.Remove(key)) return true;
        if(consumed.Contains(key)) return true;
        if(value.Type=="keyDown" && key=="KeyI" && Has("Control") && Has("Alt") && System.Linq.Enumerable.All(held,k=>k==key || k.StartsWith("Control",StringComparison.Ordinal) || k.StartsWith("Alt",StringComparison.Ordinal)) && CanOpen?.Invoke()==true) { if(window is not null) Close(); else ShortcutRequested?.Invoke(); consumed.Add(key); return true; }
        if(window is null) return null;
        if(!window.IsActive) { Close(); return null; }
        if(value.Type=="keyDown" && key=="Escape" && Has("Control") && Has("Alt") && Has("Shift")) { input?.Pause(); Close(); return true; }
        if(value.Type=="keyDown" && !composing && input?.SourceCommand(key,held)==true) { consumed.Add(key); return true; }
        return false;
    }
    private bool Has(string prefix) { foreach(var key in held) if(key.StartsWith(prefix,StringComparison.Ordinal)) return true; return false; }
    private void Close() { timer.Stop(); var previous=window; window=null; if(previous is not null) Released?.Invoke(System.Linq.Enumerable.ToArray(held)); previous?.Close(); held.Clear(); consumed.Clear(); target=null; composing=false; }
    public void Dispose()=>Close();
}
