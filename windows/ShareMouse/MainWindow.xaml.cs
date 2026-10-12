using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Linq;
using ShareMouse.Core;

namespace ShareMouse;

public partial class MainWindow : Window
{
    private readonly Action openLogs;
    private readonly Action<LogLevel, string> record;
    private PairingController? pairing;
    private LayoutEditor? layoutEditor;
    private bool initializingSettings;
    private bool syncingSecret;
    private string appliedCode="", appliedSecret="";
    private System.Windows.Threading.DispatcherTimer? credentialsTimer;

    public MainWindow(Peer? peer, string? startupError, Action openLogs, Action<LogLevel, string> record)
    {
        InitializeComponent();
        AppearanceChoice.SelectedIndex=Theme.Mode=="dark"?2:Theme.Mode=="light"?1:0;
        this.openLogs = openLogs;
        this.record = record;
        PeerName.Text = peer?.Name ?? "身份不可用";
        LocalIdentityDetails.Text = "设备 ID：" + peer?.Id.Value.ToString("D");
        if (startupError is not null)
        {
            StartupError.Text = startupError;
            StartupError.Visibility = Visibility.Visible;
            BackgroundStatus.Text = "本机初始化失败";
        }
    }

    private void AppearanceChanged(object sender, SelectionChangedEventArgs e) {
        if(AppearanceChoice.SelectedIndex>=0)Theme.SetMode(AppearanceChoice.SelectedIndex==2?"dark":AppearanceChoice.SelectedIndex==1?"light":"system");
    }
    private void NavigationChanged(object sender, SelectionChangedEventArgs e) {
        if(!ReferenceEquals(e.OriginalSource,MainNavigation))return;
        Dispatcher.BeginInvoke(new Action(()=> {
            if(MainNavigation.Template.FindName("PART_SelectedContentHost",MainNavigation) is FrameworkElement content)Theme.Reveal(content);
        }));
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
        record(LogLevel.Info, "WindowHidden background=running");
        base.OnClosing(e);
    }

    private void AvailabilityChanged(object sender, RoutedEventArgs e) {
        if(pairing is null) return;
        if(ReferenceEquals(sender, NetworkAvailable)) pairing.SetNetworkAvailable(NetworkAvailable.IsChecked==true);
        else pairing.SetBluetoothAvailable(BluetoothAvailable.IsChecked==true);
    }
    private void OpenLogsClick(object sender, RoutedEventArgs e) => openLogs();

    public void InitializePairing(PairingController controller, string code, string secret, string key)
    {
        NetworkAvailable.IsChecked = controller.Preferences.NetworkAvailable; BluetoothAvailable.IsChecked = controller.Preferences.BluetoothAvailable;
        LocalCode.Text = code; LocalPassword.Password = secret; appliedCode=code; appliedSecret=secret; pairing = controller;
        LocalIdentityDetails.Text += "\n\n公钥：\n" + key;
    }
    public void ShowPairingStatus(string status) => PairingStatus.Text = status;
    public void ShowNetworkCount(int count) => NetworkCount.Text = "后台自动发现附近设备；验证通过后加入已知设备列表。";
    public void ShowBluetoothCandidates(string[] locators) {
        BluetoothCandidates.Children.Clear();
        foreach(var locator in locators.Order()) {
            var row=new DockPanel {Margin=new Thickness(0,4,0,4)};
            var connected=pairing?.BluetoothConnected(locator)==true; var connect=new Button {Content=connected?"蓝牙已连接":"连接此设备",IsEnabled=!connected && pairing?.Connecting!=true,Padding=new Thickness(8,3,8,3)};
            connect.Click+=async (_,_)=> {if(pairing is not null) await pairing.ConnectBluetoothCandidate(locator, RemoteCode.Text, RemotePassword.Password);};
            DockPanel.SetDock(connect,Dock.Right); row.Children.Add(connect); row.Children.Add(new TextBlock {Text=(pairing?.BluetoothName(locator)??"ShareMouse 设备")+"\n"+locator,VerticalAlignment=VerticalAlignment.Center}); BluetoothCandidates.Children.Add(row);
        }
    }
    public void ShowBluetooth(string status, int count) { BluetoothStatus.Text = status; BluetoothCount.Text = $"发现 {count} 个蓝牙端点。"; }
    public void SetConnecting(bool connecting) { ConnectButton.IsEnabled = !connecting; ShowBluetoothCandidates(pairing?.BluetoothCandidates ?? []); ConnectButton.Content = connecting ? "连接中…" : "连接"; }
    public void ClearRemotePassword() { RemotePassword.Clear(); }
    public void ShowPeers(KnownPeer[] peers, SessionInfo[] sessions)
    {
        KnownPeers.Children.Clear();
        if (peers.Length == 0) KnownPeers.Children.Add(new TextBlock { Text = "完成首次配对后，设备会显示在这里。", Foreground = Theme.Brush("Muted") });
        foreach (var peer in peers) {
            var block = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
            var heading = new DockPanel();
            if (sessions.Any(s => s.PeerID == peer.PeerID)) {
                var disconnect = new Button { Content = "断开", Padding = new Thickness(10, 4, 10, 4) };
                disconnect.Click += (_, _) => pairing?.Disconnect(peer.PeerID);
                DockPanel.SetDock(disconnect, Dock.Right); heading.Children.Add(disconnect);

            }
            if(!sessions.Any(s=>s.PeerID==peer.PeerID)) {
                var reconnect=new Button {Content="快速连接",Padding=new Thickness(10,4,10,4)}; reconnect.Click+=async (_,_)=> {if(pairing is not null) await pairing.QuickConnect(peer.PeerID);};
                DockPanel.SetDock(reconnect,Dock.Right); heading.Children.Add(reconnect);
            }
            heading.Children.Add(new TextBlock { Text=peer.Name, FontWeight=FontWeights.SemiBold, VerticalAlignment=VerticalAlignment.Center });
            block.Children.Add(heading);
            var transports=sessions.FirstOrDefault(s=>s.PeerID==peer.PeerID)?.Capabilities??[];
            block.Children.Add(new TextBlock {Text="网络："+(transports.Contains("tcp")||transports.Contains("quic")?"已连接":"未连接")+" · 蓝牙："+(transports.Contains("ble")?"已连接":"未连接")+" · MCP："+(transports.Contains("mcp-server")?"已启用":"未启用")});
            block.Children.Add(new TextBlock {Text=pairing?.LatencySummary(peer.PeerID),Foreground=Theme.Brush("Muted"),TextWrapping=TextWrapping.Wrap,FontSize=12});
            var latency=new Button {Content="延迟抖动测试",HorizontalAlignment=HorizontalAlignment.Left,IsEnabled=sessions.Any(s=>s.PeerID==peer.PeerID)};
            latency.Click+=async (_,_)=> {latency.IsEnabled=false; latency.Content="正在测试（10 秒）…"; try {if(pairing is not null) await pairing.TestLatency(peer.PeerID);} finally {latency.Content="延迟抖动测试"; latency.IsEnabled=true;}};
            block.Children.Add(latency);
            block.Children.Add(new TextBlock {Text=pairing?.ThroughputSummary(peer.PeerID),Foreground=Theme.Brush("Muted"),TextWrapping=TextWrapping.Wrap,FontSize=12});
            var speed=new Button {Content=pairing?.SpeedTesting==true?"正在测速…":"传输速度测试",HorizontalAlignment=HorizontalAlignment.Left,IsEnabled=sessions.Any(s=>s.PeerID==peer.PeerID)&&pairing?.SpeedTesting!=true};
            speed.Click+=async(_,_)=>{if(pairing is not null)await pairing.TestThroughput(peer.PeerID);};block.Children.Add(speed);
            block.Children.Add(new TextBlock {Text="同时测量已连接的网络与蓝牙，本机发送、对方确认；测试会短暂暂停本机键鼠共享。",TextWrapping=TextWrapping.Wrap,Foreground=Theme.Brush("Muted"),FontSize=12});
            var preferences = new StackPanel { Orientation = Orientation.Horizontal };
            var trusted = new CheckBox { Content = "Trusted", IsChecked = peer.Trust == "trusted", Margin = new Thickness(0, 0, 20, 0) };
            var auto = new CheckBox { Content = "自动连接", IsChecked = peer.AutoConnect, IsEnabled = peer.Trust == "trusted" };
            trusted.Checked += (_, _) => pairing?.SetPreferences(peer.PeerID, true, peer.AutoConnect);
            trusted.Unchecked += (_, _) => pairing?.SetPreferences(peer.PeerID, false, false);
            auto.Checked += (_, _) => pairing?.SetPreferences(peer.PeerID, peer.Trust == "trusted", true);
            auto.Unchecked += (_, _) => pairing?.SetPreferences(peer.PeerID, peer.Trust == "trusted", false);
            var delete=new Button {Content="删除设备",Margin=new Thickness(12,0,0,0)}; delete.Click+=async(_,_)=> {if(pairing is not null) await pairing.DeletePeer(peer.PeerID);};
            preferences.Children.Add(delete); preferences.Children.Add(trusted); preferences.Children.Add(auto); block.Children.Add(preferences);
            KnownPeers.Children.Add(block);
        }
    }
    public void ShowGroupStatus(string status) { layoutEditor?.ShowStatus(status); }
    public void ShowNativeLayoutStatus(string status) { layoutEditor?.ShowNativeStatus(status); }
    public void InitializeLayout(LayoutEditor editor) { layoutEditor=editor; ScreenLayoutHost.Content=editor; }
    private async void EditConfigClick(object sender,RoutedEventArgs e) { if(pairing is not null) await pairing.EditConfig(); }
    public void ShowClipboardStatus(string text)=>ClipboardStatus.Text=text;
    private void StopBluetoothClick(object sender,RoutedEventArgs e) { pairing?.StopBluetooth(); }
    private async void LoadClipboardClick(object sender,RoutedEventArgs e) { if(pairing is not null) await pairing.LoadClipboard(); }
    public void InitializeSettings(LocalPreferences preferences) {
        initializingSettings=true;
        InputLinkChoice.SelectedIndex=preferences.BluetoothInputOnly?0:1;
        GameMouseChoice.SelectedIndex=preferences.GameMouseMode=="on"?1:preferences.GameMouseMode=="off"?2:0;
        PairMcpEnabled.IsChecked=preferences.McpEnabled;McpEnabledChoice.IsChecked=preferences.McpEnabled;ComputerUseChoice.IsChecked=preferences.AllowComputerUse;McpFilesChoice.IsChecked=preferences.AllowMcpFiles;CursorHintsChoice.IsChecked=preferences.ComputerCursorHints;
        ShowMCPToastStyle(preferences.McpToastStyle);
        foreach(ComboBoxItem item in NotificationRendererChoice.Items) if((string)item.Tag==preferences.Renderer) NotificationRendererChoice.SelectedItem=item;
        foreach(ComboBoxItem item in ToastCornerChoice.Items) if((string)item.Tag==preferences.Corner) ToastCornerChoice.SelectedItem=item;
        foreach(ComboBoxItem item in LogLevelChoice.Items) if((string)item.Content==preferences.LogLevel) LogLevelChoice.SelectedItem=item;
        LogEnabledChoice.IsChecked=preferences.LogEnabled;LogLevelChoice.IsEnabled=preferences.LogEnabled;
        StartupChoice.IsChecked=preferences.Startup; if(!preferences.OnboardingComplete) MainNavigation.SelectedIndex=4; SettingsStatus.Text=preferences.Status; initializingSettings=false;
    }
    public void ShowSettingsStatus(string text)=>SettingsStatus.Text=text;
    private void LogEnabledChanged(object sender,RoutedEventArgs e) {
        if(initializingSettings || pairing is null)return;
        pairing.Preferences.LogEnabled=LogEnabledChoice.IsChecked==true;
        LogLevelChoice.IsEnabled=pairing.Preferences.LogEnabled;
        pairing.Preferences.Save();ShowSettingsStatus(pairing.Preferences.Status);
    }
    private void GameMouseSelectionChanged(object sender,SelectionChangedEventArgs e) {
        if(initializingSettings || pairing is null || GameMouseChoice.SelectedIndex<0)return;
        pairing.Preferences.GameMouseMode=GameMouseChoice.SelectedIndex==1?"on":GameMouseChoice.SelectedIndex==2?"off":"auto";pairing.Preferences.Save();
    }
    private void InputLinkSelectionChanged(object sender,SelectionChangedEventArgs e) {
        if(!initializingSettings && InputLinkChoice.SelectedIndex>=0)pairing?.SetInputLinkPreference(InputLinkChoice.SelectedIndex==0);
    }
    public void ShowMCPStatus(string text)=>MCPStatus.Text=text;
    private void MCPSettingsChanged(object sender,RoutedEventArgs e) { if(initializingSettings)return;initializingSettings=true;PairMcpEnabled.IsChecked=McpEnabledChoice.IsChecked;initializingSettings=false; pairing?.SaveMCPSettings(McpEnabledChoice.IsChecked==true,ComputerUseChoice.IsChecked==true,McpFilesChoice.IsChecked==true,CursorHintsChoice.IsChecked==true); }
    public void ShowMCPToastStyle(string style) { foreach(ComboBoxItem item in MCPToastStyleChoice.Items) if((string)item.Tag==style) { MCPToastStyleChoice.SelectedItem=item;break; } }
    private void MCPToastStyleChanged(object sender,SelectionChangedEventArgs e) { if(!initializingSettings&&MCPToastStyleChoice.SelectedItem is ComboBoxItem item) pairing?.SaveMCPToastStyle((string)item.Tag); }
    public void ShowMCPControl(bool active) { ExitMCPControlButton.IsEnabled=active;MCPControlStatus.Text=active?"MCP 正在接管本机":"MCP 未接管本机"; }
    private void ExitMCPControlClick(object sender,RoutedEventArgs e)=>pairing?.ExitMCPControl();
    private void RestartElevatedClick(object sender,RoutedEventArgs e) {
        if(WindowsInputStatus.IsElevated) { SettingsStatus.Text="ShareMouse 已以管理员权限运行。";return; }
        try {
            var start=new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!) {UseShellExecute=true,Verb="runas",WorkingDirectory=AppContext.BaseDirectory};
            start.ArgumentList.Add("--restart-after="+Environment.ProcessId);
            foreach(var argument in Environment.GetCommandLineArgs().Skip(1).Where(a=>!a.StartsWith("--restart-after=",StringComparison.Ordinal)))start.ArgumentList.Add(argument);
            if(System.Diagnostics.Process.Start(start) is null)throw new InvalidOperationException("Restart failed");
            System.Windows.Application.Current.Shutdown();
        } catch(System.ComponentModel.Win32Exception ex) { SettingsStatus.Text=ex.NativeErrorCode==1223?"已取消管理员授权，ShareMouse 继续运行。":"无法启动管理员实例："+ex.Message; }
        catch(Exception ex) { SettingsStatus.Text="无法重启："+ex.Message; }
    }
    private void CopyMCPConfigurationClick(object sender,RoutedEventArgs e)=>pairing?.CopyMCPConfiguration();
    private void SaveSettingsClick(object sender,RoutedEventArgs e) { if(NotificationRendererChoice.SelectedItem is ComboBoxItem renderer && ToastCornerChoice.SelectedItem is ComboBoxItem corner && LogLevelChoice.SelectedItem is ComboBoxItem level) pairing?.SaveSettings((string)renderer.Tag,(string)corner.Tag,(string)level.Content,StartupChoice.IsChecked==true); }
    private void TestNotificationClick(object sender,RoutedEventArgs e)=>pairing?.TestNotification();
    private async void RefreshPermissionsClick(object sender,RoutedEventArgs e) {
        var bluetooth="未知"; try { var adapter=await Windows.Devices.Bluetooth.BluetoothAdapter.GetDefaultAsync(); bluetooth=adapter is null?"未找到适配器":$"适配器可用，Central={adapter.IsCentralRoleSupported}，Peripheral={adapter.IsPeripheralRoleSupported}"; } catch { bluetooth="不可用或未授权"; }
        SettingsStatus.Text="输入："+(WindowsInputStatus.IsElevated?"管理员权限，可操控同等级窗口":"普通权限，启动授权未完成；请重新启动并允许管理员请求")+"\n蓝牙："+bluetooth+"\n本地网络：配对服务端口 TCP 49160 / QUIC UDP 49164；连接受网络和防火墙影响";
    }
    private void FinishPermissionsClick(object sender,RoutedEventArgs e)=>pairing?.FinishPermissionSetup();
    private void HistoryClick(object sender,RoutedEventArgs e)=>pairing?.OpenHistory();
    private void PasteFilesClick(object sender,RoutedEventArgs e)=>pairing?.PasteFiles();
    public void ShowTransfers(TransferTask[] tasks) {
        Transfers.Children.Clear();
        foreach(var task in tasks) {
            var block=new StackPanel { Margin=new Thickness(0,0,0,16) }; block.Children.Add(new TextBlock { Text=task.Destination,TextTrimming=TextTrimming.CharacterEllipsis });
            block.Children.Add(new TextBlock { Text=$"{(task.Direction=="send"?"发送":"接收")} · {task.State} · {task.Received} / {task.Total} 字节",FontSize=12 });
            block.Children.Add(new ProgressBar { Minimum=0,Maximum=Math.Max(1,task.Total),Value=task.Received,Height=5,Margin=new Thickness(0,6,0,6) });
            if(task.Error is not null) block.Children.Add(new TextBlock { Text=task.Error,TextWrapping=TextWrapping.Wrap,Foreground=Theme.Brush("Danger") });
            var controls=new WrapPanel(); foreach(var action in new[] { ("pause","暂停"),("resume",task.State=="failed"?"重试":"继续"),("cancel","取消"),("open",task.Direction=="send"?"打开来源目录":"打开目标目录") }) {
                var button=new Button { Content=action.Item2,Padding=new Thickness(10,4,10,4),Margin=new Thickness(0,4,6,0),IsEnabled=action.Item1 switch { "pause"=>task.State=="running","resume"=>task.State is "paused" or "failed" or "cancelled","cancel"=>task.State is not ("completed" or "cancelled"),_=>true } };
                button.Click+=(_,_)=>pairing?.TransferAction(task,action.Item1); controls.Children.Add(button);
            } block.Children.Add(controls); Transfers.Children.Add(block);
        }
    }
    public void ShowInputStatus(string status) { MouseSharingStatus.Text=status; }
    private async void ReconnectInputClick(object sender,RoutedEventArgs e) { if(pairing is not null) {await pairing.ReconnectInput();} }
    private async void EnableInputClick(object sender, RoutedEventArgs e) { if (pairing is not null) await pairing.EnableInput(); }
    private void PauseInputClick(object sender, RoutedEventArgs e) => pairing?.PauseInput();
    public void ShowLocalCode(string code) {appliedCode=code;LocalCode.Text=code;}
    public void ShowGroup(SharedGroup? state, GroupEditLock[] locks, string[] online, SharedGroup[] saved) => layoutEditor?.Update(state,locks,online);
    private void PairMcpChanged(object sender,RoutedEventArgs e) {if(initializingSettings || pairing is null || PairMcpEnabled is null)return;var enabled=PairMcpEnabled.IsChecked==true;initializingSettings=true;McpEnabledChoice.IsChecked=enabled;initializingSettings=false;pairing.SaveMCPSettings(enabled,pairing.Preferences.AllowComputerUse,pairing.Preferences.AllowMcpFiles,pairing.Preferences.ComputerCursorHints);}
    private void ApplyCredentialsClick(object sender, RoutedEventArgs e) { if(pairing?.ApplyCredentials(LocalCode.Text, LocalPassword.Password)==true) {appliedCode=LocalCode.Text; appliedSecret=LocalPassword.Password;} }
    private async void ConnectClick(object sender, RoutedEventArgs e)
    {
        if (pairing is not null) await pairing.Connect(RemoteHost.Text, RemoteCode.Text, RemotePassword.Password);
    }
    private void RevealPasswordChanged(object sender, RoutedEventArgs e)
    {
        var reveal = ((CheckBox)sender).IsChecked == true;
        syncingSecret=true; RevealedPassword.Text = LocalPassword.Password; syncingSecret=false;
        LocalPassword.Visibility=reveal?Visibility.Collapsed:Visibility.Visible;
        RevealedPassword.Visibility = reveal ? Visibility.Visible : Visibility.Collapsed;
    }
    private void VisiblePasswordChanged(object sender,TextChangedEventArgs e) { if(syncingSecret || LocalPassword is null) return; syncingSecret=true; LocalPassword.Password=RevealedPassword.Text; syncingSecret=false; QueueCredentialsReminder(); }
    private void CredentialsPasswordChanged(object sender,RoutedEventArgs e) { if(syncingSecret) return; if(RevealedPassword is not null) {syncingSecret=true;RevealedPassword.Text=LocalPassword.Password;syncingSecret=false;} QueueCredentialsReminder(); }
    private void CredentialsTextChanged(object sender,TextChangedEventArgs e)=>QueueCredentialsReminder();
    private void QueueCredentialsReminder() {
        if(pairing is null) return;
        if(credentialsTimer is null) { credentialsTimer=new() {Interval=TimeSpan.FromMilliseconds(350)}; credentialsTimer.Tick+=(_,_)=> {
            credentialsTimer.Stop(); if(LocalCode.Text==appliedCode && LocalPassword.Password==appliedSecret) return;
            ApplyCredentialsClick(this,new RoutedEventArgs());
        }; }
        credentialsTimer.Stop();credentialsTimer.Start();
    }
    private void StartBluetoothClick(object sender, RoutedEventArgs e) => pairing?.TryBluetoothDiscovery();
}
