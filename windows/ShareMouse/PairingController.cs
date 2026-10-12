using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Threading;
using System.Windows.Interop;
using System.Threading;
using System.Threading.Tasks;
using ShareMouse.Core;
using ShareMouse.Network;

namespace ShareMouse;

public sealed class PairingController : IDisposable
{
    private readonly MainWindow view;
    private readonly string localId;
    public LocalPreferences Preferences { get; }
    private readonly NotificationService notifications;
    private readonly IdentityStore identity;
    private readonly PeerRegistry registry;
    private readonly SessionManager manager;
    private readonly GroupManager? group;
    private readonly HistoryService? history;
    private HistoryPopup? historyPopup;
    private HistoryManagementPopup? historyManagement;
    private readonly FileTransferService? files;
    private readonly ClipboardService clipboard;
    private readonly WindowsClipboardAdapter clipboardAdapter;
    private readonly SharingShortcut sharingShortcut=new();
    private readonly ClipboardShortcut clipboardShortcut=new("windows");
    private bool pasting;
    private (uint Version,string? PreviousEntryID)? preparingLocalFiles;
    private (string EntryID,ulong? Revision,uint Version)? appliedClipboard;
    private ConfigEditor? configWindow;
    private readonly InputService input;
    private readonly WindowsInputContext inputContext=new();
    private readonly WindowsInputAdapter inputAdapter;
    private readonly ComputerUseService computer;
    private readonly WindowsComputerAdapter computerAdapter=new();
    private MCPServer? mcp;
    private readonly string dataDirectory;
    private ScreenGeometry[]? lastNativeLayout;
    private bool applyingDisplayLayout;
    private bool peerResumePending, inputStarting, automaticInputPending, connectionPromptOpen;
    private int pendingConnectionDialogs, inputPauseRevision, computerInputPauseRevision;
    private readonly LanDiscovery discovery;
    private readonly PairDiscovery pairDiscovery;
    private LanCandidate[] bonjourCandidates=[], pairHints=[];
    private string localCode="", localSecret="";
    private bool generatedCode=true, sharingRequested=true;
    private readonly HashSet<string> trustAsked=new();
    private readonly DispatcherTimer autoTimer;
    private readonly DispatcherTimer bleAutoTimer=new() {Interval=TimeSpan.FromSeconds(2)};
    private bool bleAutoBusy;
    private readonly HashSet<string> suppressed = new();
    private readonly Dictionary<string, string> candidatePeers = new();
    private readonly Action<LogLevel, string> record;
    private LanCandidate[] candidates = Array.Empty<LanCandidate>();
    private SessionInfo[] sessions = Array.Empty<SessionInfo>();
    private BleDiscovery? ble;
    private readonly HashSet<string> bleCandidates = new();
    private readonly Dictionary<string,string> bleNames=new();
    private readonly Dictionary<string,LinkThroughput[]> throughputResults=new();
    private bool speedBusy;
    public bool SpeedTesting=>speedBusy;
    public string ThroughputSummary(string id) {
        if(!throughputResults.TryGetValue(id,out var values))return "传输速度：尚未测试";
        var rows=values.Select(v=>v.Summary).ToList();if(!values.Any(v=>v.Kind=="ble"))rows.Add("蓝牙：未连接，未测试");if(!values.Any(v=>v.Kind!="ble"))rows.Add("网络：未连接，未测试");return "本机 → 对方 · 应用有效吞吐\n"+string.Join("\n",rows);
    }
    public async System.Threading.Tasks.Task TestThroughput(string id) {
        if(speedBusy||latencyBusy||computer.Controlling)return;
        speedBusy=true;var resume=input.Enabled;var revision=inputPauseRevision;input.Pause();Refresh();view.ShowPairingStatus("传输速度测试运行中；暂时暂停本机键鼠共享…");
        try{var values=await manager.TestThroughputAsync(id);throughputResults[id]=values;foreach(var v in values)record(LogLevel.Info,$"LinkThroughputMeasured transport={v.Kind} bytes={v.Bytes} seconds={v.Seconds} error={v.Error??"none"}");view.ShowPairingStatus("传输速度测试完成");}
        catch{view.ShowPairingStatus("测速未完成：请连接两端新版并检查链路");}
        finally{speedBusy=false;Refresh();if(resume&&sharingRequested&&revision==inputPauseRevision&&!computer.Controlling)await EnableInput();StartAutomaticInput();}
    }
    private readonly Dictionary<string,LinkLatency[]> latencyResults=new();
    private bool latencyBusy;
    private bool disposed, busy, autoBusy;
    public bool Connecting => busy;
    public string[] BluetoothCandidates => bleCandidates.ToArray();

    public PairingController(MainWindow view, Peer peer, string directory, Action<LogLevel, string> record, LocalPreferences? localPreferences=null)
    {
        this.view = view; this.record = record; dataDirectory=directory; Preferences=localPreferences??new LocalPreferences(directory); Preferences.MigrateElevatedStartup(); notifications=new NotificationService(Preferences); if(Preferences.Renderer=="native") notifications.Configure();
        registry = new PeerRegistry(directory); trustAsked.UnionWith(registry.All().Select(p=>p.PeerID));
        identity = new IdentityStore(peer.Id.Value.ToString("D"));
        var code = RandomNumberGenerator.GetInt32(1_000_000).ToString("D6");
        var secret = ""; localCode=code;localSecret=secret;
        manager = new SessionManager(peer.Id.Value.ToString("D"), peer.Name, identity, registry, code, secret,
            certificate => view.Dispatcher.Invoke(() => ConfirmIdentity(certificate)),
            _ => false,
            eventMetadata => Dispatch(() => record(LogLevel.Info, eventMetadata)),
            confirmPeerConnection: (id,name,bluetooth)=>view.Dispatcher.InvokeAsync(()=>ConfirmPeerConnection(id,name,bluetooth)).Task.Unwrap(), bluetoothInputOnly: Preferences.BluetoothInputOnly);
        record(LogLevel.Info,$"InputTransportConfigured bluetoothOnly={manager.BluetoothInputOnly} source=localSettings");
        localId = peer.Id.Value.ToString("D");
        inputAdapter = new WindowsInputAdapter(localId, HwndSource.FromHwnd(new WindowInteropHelper(view).EnsureHandle()),text=>record(LogLevel.Info,text));
        input = new InputService(localId, "windows", manager, inputContext,
            inputAdapter.Inject, inputAdapter.CursorState, text => {view.ShowInputStatus(text);RefreshBluetoothScanning();}, text => record(LogLevel.Info,text));
        input.RelativePointerCaptured=()=>Preferences.GameMouseMode=="on" || Preferences.GameMouseMode=="auto"&&inputAdapter.RelativePointerCaptured;
        sharingShortcut.Toggle=()=>{if(input.Enabled)PauseInput();else _=ReconnectInput();};
        input.ResumeRequested=()=>{if(!disposed){sharingRequested=true;automaticInputPending=true;StartAutomaticInput();}};
        clipboard=new ClipboardService(localId,manager,new DispatcherSynchronizationContext(view.Dispatcher),metadata=>record(LogLevel.Info,metadata),directory);
        try { history=new HistoryService(localId,directory,manager,new DispatcherSynchronizationContext(view.Dispatcher)); clipboard.TextForEntry=history.Text;
        history.Opened=()=> { if(input.Enabled) input.Capture(new("command",Command:"history")); else OpenHistory(); };
        } catch { view.ShowClipboardStatus("历史记录无法读取；未覆盖原文件"); record(LogLevel.Error,"HistoryStartupFailed"); }
        try { files=new FileTransferService(localId,directory,manager,clipboard,new DispatcherSynchronizationContext(view.Dispatcher),metadata=>record(LogLevel.Info,metadata),
            async paths=>(await FileChoiceAsync("源文件已变化","源文件自复制后已发生变化，是否复制当前版本？\n\n"+string.Join("\n",paths),[("current","复制当前版本"),("cancel","取消")]))=="current",
            (path,_,allow)=>ShareMouseDialog.ChooseAsync("目标已存在",path,allow?[("overwrite","覆盖"),("keepBoth","保留两者"),("skip","跳过"),("cancel","取消")]:[("keepBoth","保留两者"),("skip","跳过"),("cancel","取消")],applyToRemaining:true),
            _=>FileChoiceAsync("部分 Cut 文件未完成","未确认的源内容仍保留。删除全部会删除此次 Cut 所选的全部源内容，包括未传输的文件。",[("abort","中断传输"),("retry","继续尝试"),("deleteAll","删除全部"),("cancel","返回")]),
            async paths=>(await FileChoiceAsync("确认删除全部源内容","即使没有成功传到目标，以下源内容也将被删除：\n\n"+string.Join("\n",paths),[("cancel","取消"),("deleteAll","删除全部")],true))=="deleteAll",
            paths=>FileChoiceAsync("目录中有新增文件","检测到剪切依据的索引文件夹存在新文件，是否要一并复制/剪切以下内容？\n\n"+string.Join("\n",paths.Take(20))+(paths.Length>20?$"\n…共 {paths.Length} 项":""),[("include","需要"),("exclude","不需要"),("cancel","取消")]));
        notifications.RestoreTransfers(files.Tasks);files.Changed+=tasks=> { view.ShowTransfers(tasks); notifications.Transfers(tasks); }; view.ShowTransfers(files.Tasks);
        } catch { view.ShowClipboardStatus("文件任务无法读取；未覆盖原文件"); record(LogLevel.Error,"FileStartupFailed"); }
        clipboard.Changed+=entry=>view.ShowClipboardStatus(entry is null?"等待复制":entry.Kind=="text"?$"当前剪贴板 · 文本 {entry.ByteCount} 字节":entry.Kind=="files"?entry.FileCount==0?"正在准备文件清单…":$"当前剪贴板 · {(entry.Cut==true?"剪切":"复制")} {entry.FileCount} 项":entry.Kind is "png" or "url" or "html" or "rtf"?$"当前剪贴板 · {entry.Kind.ToUpperInvariant()}":"此剪贴板类型尚不可用");
        clipboardAdapter=new WindowsClipboardAdapter { ContentCopied=async content=> { await clipboard.PublishContent(content); if(content?.PlainText is {} text) history?.Remember(text,clipboard.Current?.Id); }, Failed=()=>view.ShowClipboardStatus("剪贴板来源未响应，已跳过读取；键鼠继续共享，请重新复制"),Diagnostic=text=>record(LogLevel.Warn,text) };
        clipboardAdapter.FilesCopied=(paths,cut)=> { var version=clipboardAdapter.Sequence; preparingLocalFiles=(version,clipboard.Current?.Id); _=CopyFiles(paths,cut,version); return System.Threading.Tasks.Task.CompletedTask; };
        clipboardAdapter.Start(); input.ClipboardEntryID=()=>clipboard.Current?.Id; input.CommandHandler=async (command,source,entryID)=>await ClipboardCommand(command,entryID,source);
        input.LocalClipboardCommand=()=> { _=PollNativeClipboardCommand(); };
        clipboardShortcut.Paste=async ()=> {
            var screenID=input.Pointer?.ScreenID;
            try {
                if(input.RemoteScreenID is not null)return;
                if(!await ClipboardCommand("paste") && input.RemoteScreenID is null && input.Pointer?.ScreenID==screenID)inputAdapter.Inject(new("command",Command:"paste"),null,0,0);
            } catch {view.ShowClipboardStatus("系统拒绝粘贴，请检查输入桌面和权限等级");}
        };
        input.TargetKeyHandler=eventData=>CaptureHistory(eventData);
        computer=new ComputerUseService(localId,peer.Name,manager,files,clipboard,new DispatcherSynchronizationContext(view.Dispatcher),
            ()=>LocalScreens(localId),computerAdapter.Info,computerAdapter.Capture,(value,screen,x,y)=>{WindowsInputStatus.EnsureCanInject();if(value.Type=="relativeMove")computerAdapter.MoveRelative(value);else inputAdapter.Inject(value,screen,x,y);},
            ()=>{var resume=input.Enabled;computerInputPauseRevision=inputPauseRevision;sharingShortcut.Reset();clipboardShortcut.Reset();input.Pause();return resume;},resume=>{computerAdapter.Stop();if(!disposed&&computerInputPauseRevision==inputPauseRevision){automaticInputPending|=resume;StartAutomaticInput();}},()=>WindowsComputerAdapter.DesktopAvailable,computerAdapter.Mark,diagnostic:text=>record(LogLevel.Info,text),controlChanged:(active,reason)=>{if(active)computerAdapter.BeginControl();view.ShowMCPControl(active);notifications.MCPControl(active,reason);},activity:notifications.MCPActivity,inputState:WindowsInputStatus.Capture,captureWithOptions:computerAdapter.Capture,pointerPreview:computerAdapter.Preview,focusApplication:computerAdapter.FocusApplication);
        notifications.ExitMCPControl=ExitMCPControl;
        notifications.HideMCPToast=()=>SaveMCPToastStyle("hidden");
        computer.AllowComputer=Preferences.AllowComputerUse;computer.AllowFiles=Preferences.AllowMcpFiles;_=computer.Start();
        inputAdapter.Captured=eventData=> {
            if(computer.PhysicalInput(eventData))return false;
            if(!computer.Controlling && sharingShortcut.Capture(eventData))return true;
            if(CaptureHistory(eventData) || history?.Capture(eventData)==true)return true;
            var local=!input.Enabled || input.RemoteScreenID is null;
            var sharedPaste=local && eventData.Type=="keyDown" && eventData.Key=="KeyV" && NeedsSharedPaste();
            if(clipboardShortcut.Capture(eventData,sharedPaste))return true;
            return input.Enabled && input.Capture(eventData);
        };
        try { inputAdapter.Start(); } catch { view.ShowClipboardStatus("自动粘贴监听不可用；可手动加载当前剪贴板"); }
        inputAdapter.ScreensChanged = () => {if(applyingDisplayLayout || disposed)return;_=RefreshLocalScreens();};
        try {
            var id = peer.Id.Value.ToString("D");
            group = new GroupManager(id, peer.Name, identity.Identity.PublicKey, LocalScreens(id), directory, manager, registry,
                member => view.Dispatcher.InvokeAsync(() => FileChoice("确认设备组成员",$"允许 {member.Name} 加入桌面组？加入设备组不会自动加入 Trusted。\n\nPeer ID: {member.PeerID}\n\n公钥：\n{member.PublicKey}",[("cancel","拒绝"),("allow","允许加入")])=="allow").Task,
                metadata => record(LogLevel.Info, metadata), ConnectGroupMember, automaticSharing: true);
            group.Changed += (state, locks, online, saved) => Dispatch(() => {
                ApplyNativeLayout(state?.Layout??[]);clipboard.Update(state,online); history?.Update(state,online); files?.Update(state,online,manager.CurrentSessions()); input.Update(state, online, manager.CurrentSessions()); view.ShowGroup(state, locks, online, saved); Refresh(); if(sharingRequested&&!input.Enabled)automaticInputPending=true;StartAutomaticInput();
            });
            view.InitializeLayout(new LayoutEditor(localId,()=>group.BeginEdit("layout"),async (layout,lease)=>{lastNativeLayout=null;await group.CommitLayout(layout,lease);ApplyNativeLayout(group.Active?.Layout??[]);},lease=>group.Release(lease)));
            group.ConfirmConfig=(name,remote,local)=>view.Dispatcher.InvokeAsync(()=>FileChoice(local is null?"使用对方键盘配置？":"键盘配置内容冲突",
                $"来自 {name} 的配置：{remote.Name}\n修改时间：{(remote.Modified is {} m?DateTimeOffset.FromUnixTimeMilliseconds(m).LocalDateTime.ToString():"未记录")}"+(local is null?"":$"\n\n本机同 UUID 配置：{local.Name}\n修改时间：{(local.Modified is {} t?DateTimeOffset.FromUnixTimeMilliseconds(t).LocalDateTime.ToString():"未记录")}"),
                local is null?[("skip","保留当前"),("remote","添加并切换")]:[("local","保留本机"),("remote","使用对方"),("copy","另存对方副本")])).Task;
            group.Start();
        } catch { Dispatch(() => view.ShowGroupStatus("设备组数据无法读取，配对仍可使用")); record(LogLevel.Error, "GroupStartupFailed"); }
        manager.Changed += items => { Dispatch(() => SessionsChanged(items)); if (group is not null) _ = group.ConnectionsChanged(items); };
        _=clipboard.Start(); if(files is not null) _=files.Start(); if(history is not null) _=history.Start();
        manager.BluetoothAvailable = Preferences.BluetoothAvailable;
        manager.NetworkAvailable = Preferences.NetworkAvailable;
        manager.Start();
        _ = StartQuic();
        discovery = new LanDiscovery(49160);
        if (!Preferences.NetworkAvailable) discovery.SetAvailable(false);
        discovery.Changed += items => Dispatch(() => { bonjourCandidates = items; RefreshCandidates(); });
        pairDiscovery=new PairDiscovery(localId,code); pairDiscovery.Changed+=items=>Dispatch(()=>{pairHints=items.Select(v=>new LanCandidate("pair:"+v.Hint.PeerID,v.Host,v.Hint.Port,v.Hint.PeerID,v.Hint.PairCode)).ToArray();RefreshCandidates();ResolveCodeCollision();});pairDiscovery.Update(code,Preferences.NetworkAvailable);pairDiscovery.Start();
        autoTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        autoTimer.Tick += async (_, _) => {
            if (busy || autoBusy) return;
            autoBusy = true;
            try {
                await manager.RecoverNetworkLinks(suppressed);
                var desired = registry.All().Where(p => p.Trust=="trusted" && p.AutoConnect && !suppressed.Contains(p.PeerID)
                    && !sessions.Any(s => s.PeerID == p.PeerID)).Select(p => p.PeerID).Concat(sessions.Where(s=>!s.Capabilities.Contains("tcp")).Select(s=>s.PeerID)).Where(id=>!suppressed.Contains(id)).ToHashSet();
                foreach (var candidate in candidates.Where(_=>desired.Count>0)) {
                    if (candidatePeers.TryGetValue(candidate.Id, out var mapped) && (!desired.Contains(mapped)||manager.AutoConnectionDeclined(mapped))) continue;
                    try {
                        var id = await manager.ConnectAsync(candidate.Host, candidate.Port, null, null, autoOnly: true);
                        candidatePeers[candidate.Id] = id;
                    } catch { }
                }
                // Restore the primary link before attempting an optional upgrade. Only one peer upgrades.
                foreach (var session in sessions.Where(s => manager.NetworkAvailable && string.CompareOrdinal(localId, s.PeerID) < 0 && !s.Capabilities.Contains("quic") && s.LanHost is not null).ToArray()) {
                    try { await manager.ConnectAsync(session.LanHost!, 49164, null, null, autoOnly: true, kind: "quic"); }
                    catch (Exception error) { record(LogLevel.Info,"SessionLinkAttachFailed transport=quic error="+error.GetType().Name+" code="+error.HResult); }
                }
                await AutoConnectBluetooth(desired);
            } finally { autoBusy = false; }
        };
        view.InitializePairing(this, code, secret, identity.Identity.PublicKey); view.InitializeSettings(Preferences);
        ConfigureMCP();
        if(!Preferences.OnboardingComplete) view.ShowSettingsStatus("Windows 启动时申请管理员权限；登录自启默认关闭。");
        bleAutoTimer.Tick += async (_,_) => {
            var desired=registry.All().Where(p=>p.Trust=="trusted" && p.AutoConnect && !suppressed.Contains(p.PeerID)).Select(p=>p.PeerID).ToHashSet();
            await AutoConnectBluetooth(desired);
        };
        bleAutoTimer.Start();
        autoTimer.Start();
        StartBluetooth();
        Refresh();
    }
    private long nextBleFallback=Environment.TickCount64+10000;
    private async System.Threading.Tasks.Task AutoConnectBluetooth(HashSet<string> desired) {
        if(bleAutoBusy || disposed || busy || !Preferences.BluetoothAvailable || pendingConnectionDialogs>0) return; bleAutoBusy=true;
        try {
                var allowFallback=Environment.TickCount64>=nextBleFallback;
                var eligible=desired.Where(id=>string.CompareOrdinal(localId,id)<0 || allowFallback && !sessions.Any(s=>s.PeerID==id)).Concat(sessions.Where(s=>string.CompareOrdinal(localId,s.PeerID)<0 && !s.Capabilities.Contains("ble")).Select(s=>s.PeerID)).ToHashSet();
                if(eligible.Count>0) nextBleFallback=Environment.TickCount64+10000;
                if (ble is not null && eligible.Count>0) foreach (var locator in bleCandidates.ToArray()) {
                    if (candidatePeers.TryGetValue(locator,out var declined) && manager.AutoConnectionDeclined(declined))continue;
                    if (candidatePeers.TryGetValue(locator, out var id) && sessions.Any(s => s.PeerID == id && (s.Capabilities.Contains("ble") || string.CompareOrdinal(localId,id)>0))) continue;
                    if(!candidatePeers.ContainsKey(locator) && desired.Count==0 && !sessions.Any(s=>string.CompareOrdinal(localId,s.PeerID)<0 && !s.Capabilities.Contains("ble"))) continue;
                    try { var port = await ble.ConnectAsync(locator); candidatePeers[locator] = await manager.ConnectAsync("127.0.0.1", port, null, null, autoOnly: true, kind: "ble"); Refresh(); } catch { }
                }
        } finally {bleAutoBusy=false;}
    }
    private async System.Threading.Tasks.Task RefreshLocalScreens() {
        lastNativeLayout=null;if(group is null)return;
        await group.UpdateScreens(LocalScreens(localId));if(!disposed)ApplyNativeLayout(group.Active?.Layout??[]);
    }
    private void ApplyNativeLayout(ScreenGeometry[] layout) {
        var local=layout.Where(s=>s.PeerID==localId).ToArray();if(applyingDisplayLayout || lastNativeLayout?.SequenceEqual(local)==true)return;
        lastNativeLayout=local;applyingDisplayLayout=true;
        try {WindowsDisplayLayout.Apply(layout,localId,System.IO.Path.Combine(dataDirectory,"display-layout-backup.json"));view.ShowNativeLayoutStatus("");}
        catch(Exception error) {view.ShowNativeLayoutStatus("系统屏幕排布同步未完成："+error.Message);record(LogLevel.Warn,"NativeDisplayLayoutRejected");}
        finally {applyingDisplayLayout=false;}
    }
    private static ScreenGeometry[] LocalScreens(string id) {
        return System.Windows.Forms.Screen.AllScreens.Select((screen, index) => {
            var result = new ScreenGeometry(id + ":" + screen.DeviceName, id, screen.DeviceName, index + 1,
                screen.Bounds.Width, screen.Bounds.Height, screen.Primary, screen.Bounds.X, screen.Bounds.Y);
            return result;
        }).ToArray();
    }
    private async System.Threading.Tasks.Task PollNativeClipboardCommand() {
        try {await System.Threading.Tasks.Task.Delay(80);if(!disposed)await clipboardAdapter.Poll();}
        catch {if(!disposed)view.ShowClipboardStatus("剪贴板暂时不可读，请重新复制");}
    }
    private bool NeedsSharedPaste() {
        var version=clipboardAdapter.Sequence;
        if(clipboardAdapter.HasUnobservedChange || preparingLocalFiles?.Version==version && preparingLocalFiles?.PreviousEntryID==clipboard.Current?.Id)return false;
        if(group?.Active is null || clipboard.Current is not {} entry)return false;
        if(appliedClipboard is {} applied && applied.EntryID==entry.Id && applied.Revision==entry.FileRevision && applied.Version==version)return false;
        return entry.SourcePeerID!=localId;
    }
    private void MarkAppliedClipboard() {if(clipboard.Current is {} entry)appliedClipboard=(entry.Id,entry.FileRevision,clipboardAdapter.Sequence);}
    private async System.Threading.Tasks.Task<bool> ClipboardCommand(string command,string? expectedEntryID=null,string? source=null) {
        if(command=="history") { OpenHistory(); return true; }
        if(command=="paste") {
            if((source is null || source==localId) && !NeedsSharedPaste())return false;
            if(pasting) return true; pasting=true;
            try {
                var screenID=input.Pointer?.ScreenID; await clipboardAdapter.Poll();
                if(expectedEntryID is not null && source is not null) await clipboard.WaitForEntry(expectedEntryID,source);
                if(input.Pointer?.ScreenID!=screenID) throw new InvalidOperationException("Paste target changed.");
                if(clipboardAdapter.HasUnobservedChange)throw new InvalidOperationException("Clipboard changed while waiting for entry.");
                if(!NeedsSharedPaste())return false;
                if(clipboard.Current?.SourcePeerID==localId)return false;
                var clipboardVersion=clipboardAdapter.Sequence;
                var entryID=clipboard.Current?.Id;
                if(clipboard.Current?.Kind=="files") { var destination=WindowsClipboardAdapter.ExplorerDestination()??ChooseDestination(); if(clipboard.Current?.Id!=entryID || clipboardAdapter.Sequence!=clipboardVersion || input.Pointer?.ScreenID!=screenID)throw new InvalidOperationException("Paste target changed.");if(destination is not null) _=PasteFiles(destination); return true; }
                var content=await clipboard.Content();
                if(clipboard.Current?.Id!=entryID || input.Pointer?.ScreenID!=screenID || clipboardAdapter.Sequence!=clipboardVersion) throw new InvalidOperationException("Paste target changed.");
                if(content.PlainText is {} text) history?.Remember(text,clipboard.Current?.Id,clipboard.Current?.Timestamp); clipboardAdapter.WriteContent(content);MarkAppliedClipboard(); inputAdapter.Inject(new("command",Command:"paste"),null,0,0);
            } catch(System.ComponentModel.Win32Exception) { view.ShowClipboardStatus("系统拒绝输入注入，请检查输入桌面和权限等级"); throw; }
            catch { view.ShowClipboardStatus("粘贴未完成：来源离线、当前项变化或类型不可用"); notifications.Toast("粘贴未完成","来源离线、当前项变化或系统剪贴板暂不可读；键鼠共享继续运行"); return true; }
            finally { pasting=false; } return true;
        }
        if(command is "copy" or "cut") {
            inputAdapter.Inject(new("command",Command:command),null,0,0);
            await System.Threading.Tasks.Task.Delay(80); await clipboardAdapter.Poll(); return true;
        }
        return false;
    }
    private async System.Threading.Tasks.Task CopyFiles(string[] paths,bool cut,uint version) { try { if(files is null) { await clipboard.PublishContent(null); view.ShowClipboardStatus("文件模块不可用；其它剪贴板格式继续工作"); return; }; await files.Copy(paths,cut,()=>clipboardAdapter.Sequence==version); } catch { if(clipboardAdapter.Sequence==version) view.ShowClipboardStatus("文件清单无法准备；请重新复制"); } finally {if(preparingLocalFiles?.Version==version)preparingLocalFiles=null;} }
    private string FileChoice(string title,string message,(string value,string label)[] choices,bool destructive=false) { var resume=input.Enabled; input.Pause(); try { return ShareMouseDialog.Choose(view,title,message,choices,destructive); } finally { if(resume) _=EnableInput(); } }
    private System.Threading.Tasks.Task<string> FileChoiceAsync(string title,string message,(string value,string label)[] choices,bool destructive=false)=>ShareMouseDialog.ChooseAsync(title,message,choices,destructive);
    private string? ChooseDestination() { var dialog=new Microsoft.Win32.OpenFolderDialog { Title="选择文件粘贴目标" }; return dialog.ShowDialog()==true?dialog.FolderName:null; }
    public void SaveSettings(string renderer,string corner,string logLevel,bool startup) { Preferences.Renderer=renderer; Preferences.Corner=corner; Preferences.LogLevel=logLevel; if(Preferences.Startup!=startup) Preferences.SetStartup(startup); Preferences.Save(); view.ShowSettingsStatus(notifications.Configure()?Preferences.Status:"原生通知不可用或被系统禁用；已采用自定义提示"); notifications.Transfers(files?.Tasks??[]); }
    public void TestNotification()=>notifications.Toast("ShareMouse","后台服务正在运行；此提示可手动隐藏。");
    private bool CaptureHistory(CapturedInput value)=>value.Type is "keyDown" or "keyUp" && (System.Windows.Application.Current.Windows.OfType<HistoryDetailsPopup>().LastOrDefault(w=>w.IsActive)?.Capture(value)==true || historyPopup?.Capture(value)==true);
    public void OpenHistory() { if(history is null) { view.ShowClipboardStatus("历史模块无法读取；配对与其它功能继续运行"); return; } if(historyPopup?.IsVisible==true) { historyPopup.Activate(); return; } historyPopup=new HistoryPopup(history,(entry,target)=> { _=SelectHistory(entry,true,target); },ManageHistory); historyPopup.Show(); }
    public void ManageHistory() { if(history is null) return; if(historyManagement?.IsVisible==true) { historyManagement.Activate(); return; } historyManagement=new HistoryManagementPopup(history); historyManagement.Show(); }
    public void FinishPermissionSetup() { Preferences.OnboardingComplete=true; Preferences.Save(); view.ShowSettingsStatus("权限向导已完成；未授权模块可稍后申请。"); }
    private async System.Threading.Tasks.Task SelectHistory(HistoryEntry entry,bool paste=false,IntPtr target=default) { var screenID=input.Pointer?.ScreenID;var version=clipboardAdapter.Sequence; try { await clipboard.PublishText(entry.Text);if(clipboardAdapter.Sequence!=version)throw new InvalidOperationException("Clipboard changed while selecting history"); clipboardAdapter.WriteText(entry.Text);var appliedVersion=clipboardAdapter.Sequence; history?.Remember(entry.Text,clipboard.Current?.Id,favorite:entry.Favorite); if(paste) { await System.Threading.Tasks.Task.Delay(40); if(input.Pointer?.ScreenID!=screenID || clipboardAdapter.Sequence!=appliedVersion || !HistoryPopup.IsTargetForeground(target)) { view.ShowClipboardStatus("目标已改变；历史内容已加载，请手动粘贴"); return; } inputAdapter.Inject(new("command",Command:"paste"),null,0,0); } } catch { view.ShowClipboardStatus("无法选择历史项"); } }
    public void PasteFiles() { var destination=ChooseDestination(); if(destination is not null) _=PasteFiles(destination); }
    private async System.Threading.Tasks.Task PasteFiles(string destination) { var version=clipboardAdapter.Sequence; try { if(files is null) throw new InvalidOperationException(); var taskID=await files.Paste(destination); var task=files.Tasks.First(t=>t.Id==taskID); if(task.State=="failed" && task.Files.Count==0) notifications.Toast("文件传输失败","来源离线或文件清单不可用；可在传输记录重试，键鼠共享继续运行"); if(task.State=="completed" && task.Files.Any(f=>f.Completed) && clipboard.Current?.Id==task.Entry.Id && clipboardAdapter.Sequence==version) {clipboardAdapter.WriteFiles(task.Files.Where(f=>f.Completed && f.Item.Id==f.Item.RootID).Select(f=>f.Target).ToArray());MarkAppliedClipboard();} } catch { view.ShowClipboardStatus("文件粘贴未完成；请在传输记录中重试"); } }
    public void TransferAction(TransferTask task,string action) { if(files is null) return; if(action=="pause") files.Pause(task.Id); if(action=="cancel") files.Cancel(task.Id); if(action=="resume") _=files.Resume(task.Id); if(action=="open") System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(task.Destination) { UseShellExecute=true }); }
    public async System.Threading.Tasks.Task LoadClipboard() {
        var version=clipboardAdapter.Sequence;
        try { var content=await clipboard.Content(); if(clipboardAdapter.Sequence!=version)throw new InvalidOperationException("Clipboard changed while loading"); clipboardAdapter.WriteContent(content);MarkAppliedClipboard(); if(content.PlainText is {} text) history?.Remember(text,clipboard.Current?.Id,clipboard.Current?.Timestamp); view.ShowClipboardStatus("已加载到本机剪贴板"); }
        catch { view.ShowClipboardStatus("无法加载：剪贴板来源不可达或当前类型不可用"); }
    }
    public void SetNetworkAvailable(bool enabled) { Preferences.NetworkAvailable=enabled; Preferences.Save(); manager.NetworkAvailable=enabled; discovery.SetAvailable(enabled);pairDiscovery.Update(localCode,enabled); }
    public void SetBluetoothAvailable(bool enabled) { Preferences.BluetoothAvailable=enabled; Preferences.Save(); manager.BluetoothAvailable=enabled; ble?.SetAvailable(enabled);if(enabled){StartBluetooth();if(ble is not null)_=ble.TryDiscoveryAsync();} }
    public void TryBluetoothDiscovery() { StartBluetooth(); if(ble is not null) _=ble.TryDiscoveryAsync(); }
    public void StopBluetooth() {
        ble?.Dispose(); ble=null; bleCandidates.Clear();
        foreach(var session in sessions) manager.DisconnectTransport(session.PeerID,"ble");
        view.ShowBluetooth("蓝牙发现和连接已停止",0);
    }
    public bool HasActiveGroup => group?.Active is not null;
    public async System.Threading.Tasks.Task EnableInput(bool requestPeers=false) {
        peerResumePending|=requestPeers;
        if (disposed || speedBusy || computer.Controlling || inputStarting || pendingConnectionDialogs>0) return; inputStarting=true;
        var revision=inputPauseRevision;
        try { inputAdapter.Start(); if(!input.Enabled)await input.Enable(); if(disposed||revision!=inputPauseRevision||computer.Controlling) input.Pause();else if(peerResumePending && input.Enabled){peerResumePending=false;input.RequestPeerResume();notifications.InputReconnected(sessions,manager.BluetoothInputOnly);} }
        catch { view.ShowInputStatus("无法启用：请先连接已配对电脑；系统权限或输入桌面可能受限"); }
        finally { inputStarting=false; StartAutomaticInput(); }
    }
    public async System.Threading.Tasks.Task ReconnectInput(){sharingRequested=true;automaticInputPending=true;await EnableInput(requestPeers:true);}
    public void SetInputLinkPreference(bool bluetooth) {
        Preferences.BluetoothInputOnly=bluetooth;Preferences.Save();manager.SetInputLinkPreference(bluetooth);
        input.RefreshInputRoute();input.Update(group?.Active,group?.Online??[],manager.CurrentSessions());
        if(bluetooth)bleAutoTimer.Start();else _=StartQuic();
    }
    public void ExitMCPControl()=>computer.EndControl("user_exit");
    public void PauseInput() {sharingRequested=false;inputPauseRevision++; automaticInputPending=false; input.Pause(); view.ShowInputStatus("键鼠共享已暂停，本机输入已恢复"); }
    public void SaveMCPSettings(bool enabled,bool computerUse,bool files,bool hints){Preferences.McpEnabled=enabled;Preferences.AllowComputerUse=computerUse;Preferences.AllowMcpFiles=files;Preferences.ComputerCursorHints=hints;Preferences.Save();ConfigureMCP();}
    public void SaveMCPToastStyle(string style){style=style=="hidden"?"hidden":"text";if(Preferences.McpToastStyle==style)return;Preferences.McpToastStyle=style;Preferences.Save();view.ShowMCPToastStyle(style);notifications.RefreshMCPPresentation();}
    private void ConfigureMCP(){computer.AllowComputer=Preferences.AllowComputerUse;computer.AllowFiles=Preferences.AllowMcpFiles;computerAdapter.ShowHints=Preferences.ComputerCursorHints;if(!Preferences.AllowComputerUse)computer.EndControl();_=computer.UpdateCapabilities();
        try{if(Preferences.McpEnabled){mcp??=new MCPServer(computer,dataDirectory);mcp.Start();_=manager.SetCapabilityAsync("mcp-server",true);view.ShowMCPStatus("MCP · 127.0.0.1:49170 · 已启用");}else{computer.EndControl();mcp?.Dispose();mcp=null;_=manager.SetCapabilityAsync("mcp-server",false);view.ShowMCPStatus("MCP 服务未启用");}}catch(Exception e){_=manager.SetCapabilityAsync("mcp-server",false);view.ShowMCPStatus("MCP 启动失败："+e.Message);}}
    public void CopyMCPConfiguration(){var bridge=System.IO.Path.Combine(AppContext.BaseDirectory,"bridge.py");var config=new {mcpServers=new {ShareMouse=new {command="python",args=new[]{bridge,"--token-file",System.IO.Path.Combine(dataDirectory,"mcp-token")}}}};System.Windows.Clipboard.SetText(System.Text.Json.JsonSerializer.Serialize(config,new System.Text.Json.JsonSerializerOptions {WriteIndented=true}));view.ShowMCPStatus("接入配置已复制");}
    public System.Threading.Tasks.Task EditConfig() {
        if(group is null)return System.Threading.Tasks.Task.CompletedTask;
        if(configWindow?.IsVisible==true){configWindow.Activate();return System.Threading.Tasks.Task.CompletedTask;}
        configWindow=new ConfigEditor(group.KeyboardLibrary,group.SelectedKeyboardConfig,identity.Identity.PeerID,(configs,id)=>group.SaveKeyboardLibrary(configs,id)){Owner=view};configWindow.Show();
        return System.Threading.Tasks.Task.CompletedTask;
    }
    public bool CanRecommend(string id) => group?.Active is { } state && !state.Members.Any(m => m.PeerID == id);
    public async System.Threading.Tasks.Task CreateGroup() { if (group is not null) await GroupOperation(() => group.Create()); }
    public async System.Threading.Tasks.Task LeaveGroup() { if (group is not null) await GroupOperation(() => group.Leave()); }
    public async System.Threading.Tasks.Task ActivateGroup(string id) { if (group is not null) await GroupOperation(() => group.Activate(id)); }
    public async System.Threading.Tasks.Task JoinGroup(string id) { if (group is not null) await GroupOperation(() => group.Join(id)); }
    public async System.Threading.Tasks.Task RecommendPeer(string id) { if (group is not null) await GroupOperation(() => group.Recommend(id)); }
    private async System.Threading.Tasks.Task ConnectGroupMember(GroupMember member, string groupId) {
        if(registry.Find(member.PeerID) is null || suppressed.Contains(member.PeerID)) return;
        if (member.Host is { } host) {
            try { await manager.ConnectAsync(host, member.Port, null, null, autoOnly: true, groupId: groupId, expectedPeerId: member.PeerID); return; } catch { }
        }
        if (ble is not null) foreach (var locator in bleCandidates.ToArray()) {
            if (candidatePeers.TryGetValue(locator, out var mapped) && mapped != member.PeerID && sessions.Any(s => s.PeerID == mapped)) continue;
            try {
                var port = await ble.ConnectAsync(locator);
                await manager.ConnectAsync("127.0.0.1", port, null, null, autoOnly: true, kind: "ble", groupId: groupId, expectedPeerId: member.PeerID);
                candidatePeers[locator] = member.PeerID; return;
            } catch { }
        }
        throw new System.IO.IOException("Member endpoint unavailable.");
    }
    private async System.Threading.Tasks.Task GroupOperation(Func<System.Threading.Tasks.Task> operation) {
        try { await operation(); } catch { view.ShowGroupStatus("操作未完成：检查当前设备组、在线状态或编辑锁"); }
    }
    private async System.Threading.Tasks.Task StartQuic() {
        if(manager.BluetoothInputOnly)return;
        try { await manager.StartQuicListener(); } catch { Dispatch(() => record(LogLevel.Warn, "QUICUnavailable")); }
    }
    private void Dispatch(Action action) { if (!disposed) view.Dispatcher.BeginInvoke(action); }
    private void Refresh() {view.ShowPeers(registry.All(), sessions); view.ShowBluetoothCandidates(bleCandidates.ToArray());}
    private void RefreshBluetoothScanning() => ble?.SetRealtimeInputEnabled(input?.Enabled==true && sessions.Any(s=>s.Capabilities.Contains("ble")));
    private void SessionsChanged(SessionInfo[] items)
    {
        var newlyKnown=items.Where(p=>!trustAsked.Contains(p.PeerID)).ToArray();trustAsked.UnionWith(newlyKnown.Select(p=>p.PeerID));foreach(var item in newlyKnown)_=OfferTrust(item);
        var freshConnection=items.Any(item=>!sessions.Any(old=>old.PeerID==item.PeerID && old.SessionID==item.SessionID));
        connectionPromptOpen=true;
        notifications.Connections(items);
        sessions = items; RefreshBluetoothScanning(); Refresh(); view.ShowPairingStatus(items.Length == 0 ? "等待配对" : "安全连接已建立");
        foreach(var item in items) ShareMouseDialog.CompleteConnection(item.PeerID);
        connectionPromptOpen=false; if(freshConnection && sharingRequested) automaticInputPending=true; StartAutomaticInput();
    }
    private void StartAutomaticInput() {
        if(!disposed && !speedBusy && sharingRequested && !computer.Controlling && automaticInputPending && !connectionPromptOpen && pendingConnectionDialogs==0 && !inputStarting && !input.Enabled && group?.Online.Length>1) {
            automaticInputPending=false; _=EnableInput();
        }
    }
    private bool ConfirmIdentity(CertificatePeer certificate) => FileChoice("核对对方设备身份",
        $"请在对方 ShareMouse 查看设备身份，确认设备 ID 与公钥一致。验证后才允许建立连接。\n\nPeer ID: {certificate.PeerID}\n\n{certificate.PublicKey}",[("cancel","拒绝"),("allow","一致，允许连接")])=="allow";
    private async System.Threading.Tasks.Task<bool> ConfirmPeerConnection(string peerID,string name,bool bluetooth) {
        if(manager.CurrentSessions().Any(item=>item.PeerID==peerID)) return true;
        pendingConnectionDialogs++;
        var resume=input.Enabled; var revision=inputPauseRevision;
        if(resume) input.Pause();
        try {
            return await ShareMouseDialog.ChooseConnectionAsync(view,peerID,bluetooth?"蓝牙连接请求":"确认连接",
                $"允许 {name} 连接？\n已识别已配对设备。允许后自动共享鼠标和键盘。",[("cancel","拒绝"),("allow","允许")])=="allow";
        } finally {
            pendingConnectionDialogs--;
            if(resume && revision==inputPauseRevision) automaticInputPending=true;
            StartAutomaticInput();
        }
    }

    public System.Threading.Tasks.Task DeletePeer(string id) { suppressed.Add(id); manager.Disconnect(id); try {registry.Remove(id);view.ShowPeers(registry.All(),sessions);} catch {view.ShowPairingStatus("删除设备未完成");} return System.Threading.Tasks.Task.CompletedTask; }
    private void RefreshCandidates() {
        candidates=pairHints.Concat(bonjourCandidates).ToArray();foreach(var item in pairHints)if(item.PeerID is {} id)candidatePeers[item.Id]=id;view.ShowNetworkCount(candidates.Length);
    }
    private void ResolveCodeCollision() {
        if(!generatedCode||!pairHints.Any(p=>p.PairCode==localCode&&string.CompareOrdinal(p.PeerID,localId)<0))return;
        var used=pairHints.Select(p=>p.PairCode).ToHashSet();var next=int.Parse(localCode);do{next=(next+1)%1000000;}while(used.Contains(next.ToString("D6")));
        localCode=next.ToString("D6");manager.UpdateCredentials(localCode,localSecret);pairDiscovery.Update(localCode,Preferences.NetworkAvailable);ble?.UpdatePairCode(localCode);view.ShowLocalCode(localCode);
    }
    public bool ApplyCredentials(string code,string secret) {
        if(code.Length!=6){view.ShowPairingStatus("配对码需要 6 位数字");return false;}
        if(pairHints.Any(p=>p.PairCode==code)) {
            _=ShareMouseDialog.ChooseAsync("配对码冲突","附近设备已使用此配对码，请输入其它 6 位数字。原配对信息继续生效。",[("ok","知道了")]);view.ShowLocalCode(localCode);return false;
        }
        try{manager.UpdateCredentials(code,secret);if(code!=localCode)generatedCode=false;localCode=code;localSecret=secret;pairDiscovery.Update(code,Preferences.NetworkAvailable);ble?.UpdatePairCode(code);view.ShowPairingStatus("配对信息已自动更新");return true;}
        catch{view.ShowPairingStatus("配对码需要 6 位数字；密钥可留空");return false;}
    }
    private async System.Threading.Tasks.Task OfferTrust(SessionInfo item) {
        pendingConnectionDialogs++;try {
        var trusted=await ShareMouseDialog.ChooseAsync("信任设备",$"是否将 {item.Name} 加入 Trusted？允许后对方可以使用快速连接免密请求连接本机。",[("no","暂不信任"),("yes","信任")])=="yes";
        registry.SetPreferences(item.PeerID,trusted,false);Refresh();
        if(trusted){var automatic=await ShareMouseDialog.ChooseAsync("自动连接",$"以后发现 {item.Name} 时，是否自动向对方发起连接请求？对方需要确认；拒绝后本次运行不再提示，可手动快速连接。",[("no","手动连接"),("yes","自动连接")])=="yes";SetPreferences(item.PeerID,true,automatic);}
        }finally{pendingConnectionDialogs--;StartAutomaticInput();}
    }
    public async System.Threading.Tasks.Task Connect(string host, string code, string secret)
    {
        if (busy) return;
        busy = true; view.ShowPairingStatus("正在验证对方设备"); view.SetConnecting(true);
        try {
            if (!string.IsNullOrWhiteSpace(host) && Preferences.NetworkAvailable) {
                var id = await manager.ConnectAsync(host.Trim(), 49160, code, secret); suppressed.Remove(id);
            } else {
                bool connected = false;
                foreach (var candidate in candidates.Where(p=>Preferences.NetworkAvailable&&(p.PairCode is null||p.PairCode==code)).OrderBy(p=>p.PairCode is null)) {
                    try {
                        var id = await manager.ConnectAsync(candidate.Host, candidate.Port, code, secret,expectedPeerId:candidate.PeerID,handshakeTimeoutSeconds:5);
                        candidatePeers[candidate.Id] = id; suppressed.Remove(id); connected = true; break;
                    } catch { }
                }
                if (!connected && Preferences.BluetoothAvailable && ble is not null) foreach(var locator in bleCandidates.Where(p=>!bleNames.GetValueOrDefault(p,"").StartsWith("SM",StringComparison.Ordinal)||bleNames[p]=="SM"+code).ToArray()) {
                    try {
                        var port=await ble.ConnectAsync(locator);
                        var id=await manager.ConnectAsync("127.0.0.1",port,code,secret,kind:"ble");
                        candidatePeers[locator]=id; suppressed.Remove(id); connected=true; break;
                    } catch { }
                }
                if (!connected) throw new InvalidOperationException();
            }
            view.ClearRemotePassword(); view.ShowPairingStatus("安全连接已建立");
        } catch { FileChoice("连接失败","请检查配对信息、设备身份和网络权限。",[("cancel","关闭")]); view.ShowPairingStatus("连接失败：请检查配对信息、设备身份和网络权限"); record(LogLevel.Warn, "PairingFailed"); }
        finally { busy = false; view.SetConnecting(false); }
    }
    public void SetPreferences(string id, bool trusted, bool autoConnect)
    {
        try { registry.SetPreferences(id, trusted, autoConnect); if (autoConnect) suppressed.Remove(id); Refresh(); }
        catch { view.ShowPairingStatus("无法保存设备偏好"); }
    }
    public async void Disconnect(string id) { suppressed.Add(id); manager.Disconnect(id); await System.Threading.Tasks.Task.Delay(10000); suppressed.Remove(id); }
    public string BluetoothName(string locator)=>candidatePeers.TryGetValue(locator,out var id)?registry.Find(id)?.Name??bleNames.GetValueOrDefault(locator,"ShareMouse 设备"):bleNames.GetValueOrDefault(locator,"ShareMouse 设备");
    public bool BluetoothConnected(string locator)=>candidatePeers.TryGetValue(locator,out var id) && sessions.Any(s=>s.PeerID==id && s.Capabilities.Contains("ble"));
    public string LatencySummary(string id)=>latencyResults.TryGetValue(id,out var values)?string.Join("\n",values.Select(l=>l.Summary)):"延迟／抖动：尚未测试";
    public async System.Threading.Tasks.Task TestLatency(string id) {
        if(latencyBusy || speedBusy) return; latencyBusy=true; view.ShowPairingStatus("延迟抖动测试运行中（10 秒）…");
        try {
            async System.Threading.Tasks.Task<(int capture,int send)> MeasureRates() {var capture=0;var send=0;for(var i=0;i<10;i++) {await System.Threading.Tasks.Task.Delay(1000);capture+=input.CaptureRate;send+=input.SendRate;}return(capture/10,send/10);}
            var measurement=MeasureRates(); var values=await manager.TestLatencyAsync(id); var rates=await measurement; latencyResults[id]=values; Refresh();
            foreach(var value in values) record(LogLevel.Info,$"LinkLatencyMeasured transport={value.Kind} samples={value.Samples.Length} lost={value.Lost} averageMs={value.Average} p95Ms={value.P95} p99Ms={value.P99} maximumMs={value.Maximum}");
            new LatencyWindow(values,$"10 秒平均：本机采样 {rates.capture} 次/秒 · 发出移动 {rates.send} 次/秒 · 发送合并目标 500 Hz") {Owner=view}.Show();
        }
        catch { view.ShowPairingStatus("无法测试：设备未连接"); } finally {latencyBusy=false;}
    }
    public async System.Threading.Tasks.Task QuickConnect(string id) {
        if(busy)return;busy=true;suppressed.Remove(id);view.SetConnecting(true);
        try {
            if(sessions.Any(p=>p.PeerID==id)){await ReconnectInput();return;}
            if(Preferences.NetworkAvailable) {
                foreach(var endpoint in registry.Find(id)?.NetworkEndpoints??[]) {try{await manager.ConnectAsync(endpoint.Host,endpoint.Port,null,null,expectedPeerId:id,handshakeTimeoutSeconds:5,quickOnly:true);return;}catch{}}
                foreach(var candidate in candidates.Where(p=>p.PeerID is null||p.PeerID==id)) {try{candidatePeers[candidate.Id]=await manager.ConnectAsync(candidate.Host,candidate.Port,null,null,expectedPeerId:id,handshakeTimeoutSeconds:5,quickOnly:true);return;}catch{}}
            }
            if(Preferences.BluetoothAvailable&&ble is not null) {
                _=ble.TryDiscoveryAsync();foreach(var locator in bleCandidates.Where(p=>!candidatePeers.ContainsKey(p)||candidatePeers[p]==id).ToArray()) {
                    try{var port=await ble.ConnectAsync(locator);candidatePeers[locator]=await manager.ConnectAsync("127.0.0.1",port,null,null,kind:"ble",expectedPeerId:id,quickOnly:true);return;}catch{}
                }
            }
            view.ShowPairingStatus("快速连接未完成：需要对端将本机设为 Trusted，并允许连接方式");
        } finally {busy=false;view.SetConnecting(false);}
    }
    public async System.Threading.Tasks.Task ConnectBluetoothCandidate(string locator, string code, string secret) {
        if(busy || ble is null) return; busy=true; view.SetConnecting(true);
        view.ShowBluetooth("正在连接设备；请在对方 ShareMouse 中允许连接",bleCandidates.Count);
        try { var port=await ble.ConnectAsync(locator); var id=await manager.ConnectAsync("127.0.0.1",port,code,secret,kind:"ble"); candidatePeers[locator]=id; suppressed.Remove(id); Refresh(); view.ShowBluetooth("蓝牙安全连接已建立",bleCandidates.Count); }
        catch {view.ShowBluetooth("连接未完成：对方未允许、设备离线或身份校验失败；请重新点击连接此设备",bleCandidates.Count);record(LogLevel.Warn,"BluetoothPairingFailed");}
        finally {busy=false; view.SetConnecting(false);}
    }
    public async void StartBluetooth()
    {
        if (ble is not null) return;
        manager.StartBluetoothListener();
        ble = new BleDiscovery();
        ble.UpdatePairCode(localCode);ble.SetAvailable(Preferences.BluetoothAvailable);
        ble.Status += metadata => Dispatch(() => {
            record(LogLevel.Info, metadata);
            view.ShowBluetooth(metadata.Contains("Unavailable") || metadata.Contains("Stopped")
                ? "蓝牙不可用，请检查系统权限、蓝牙开关或适配器能力" : metadata=="BLEActiveDiscovery" ? "正在尝试发现（最多 1 分钟）" : "后台发现 ShareMouse 蓝牙设备", bleCandidates.Count);
        });
        ble.Found += (id,name) => Dispatch(() => { var changed=bleCandidates.Add(id) || bleNames.GetValueOrDefault(id)!=name; bleNames[id]=name; if(changed) {view.ShowBluetoothCandidates(bleCandidates.ToArray()); view.ShowBluetooth("后台发现 ShareMouse 蓝牙设备", bleCandidates.Count);_=AutoConnectBluetooth(registry.All().Where(p=>p.Trust=="trusted"&&p.AutoConnect&&!suppressed.Contains(p.PeerID)).Select(p=>p.PeerID).ToHashSet());} });
        await ble.StartAsync();
        RefreshBluetoothScanning();
    }
    public void Dispose()
    {
        disposed=true; mcp?.Dispose();computer.Dispose();computerAdapter.Stop();
         notifications.Dispose(); history?.Dispose(); historyPopup?.Close(); historyManagement?.Close(); files?.Dispose(); clipboard.Dispose(); clipboardAdapter.Dispose(); clipboardShortcut.Reset();sharingShortcut.Reset(); input.Dispose(); inputContext.Dispose(); inputAdapter.Dispose();
        disposed = true; bleAutoTimer.Stop(); autoTimer.Stop(); discovery.Dispose();pairDiscovery.Dispose(); ble?.Dispose();
        manager.DisposeAsync().AsTask().GetAwaiter().GetResult(); identity.Dispose();
    }
}
