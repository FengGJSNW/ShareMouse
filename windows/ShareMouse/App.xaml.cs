using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using ShareMouse.Core;
using Forms = System.Windows.Forms;

namespace ShareMouse;

public partial class App : Application
{
    private Mutex? instance;
    private bool ownsInstance;
    private Forms.NotifyIcon? tray;
    private AppLogger? logger;
    private LocalPreferences? preferences;
    private PairingController? pairing;
    private readonly string dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShareMouse");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length == 1 && e.Args[0] == WindowsClipboardReader.HelperArgument)
        {
            Shutdown(WindowsClipboardReader.RunHelper(WindowsClipboardAdapter.ReadSnapshot));
            return;
        }
        // The executable manifest requests UAC before startup. Also guard DLL-hosted launches.
        if (!WindowsInputStatus.IsElevated)
        {
            try
            {
                var launch = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "ShareMouse.exe")) { UseShellExecute = true, Verb = "runas", WorkingDirectory = AppContext.BaseDirectory };
                foreach (var argument in e.Args)
                    launch.ArgumentList.Add(argument);
                Process.Start(launch);
            }
            catch (System.ComponentModel.Win32Exception) { } // Cancelled consent never silently starts a medium-integrity instance.
            Shutdown();
            return;
        }
        if (e.Args.Length == 2 && e.Args[0] == "--mcp-inspect")
        {
            _ = InspectAndExit(e.Args[1]);
            return;
        }
        var restart = e.Args.FirstOrDefault(a => a.StartsWith("--restart-after=", StringComparison.Ordinal));
        if (restart is not null && int.TryParse(restart.Substring("--restart-after=".Length), out var previousId) && previousId != Environment.ProcessId)
        {
            try
            {
                using var previous = Process.GetProcessById(previousId);
                if (!previous.WaitForExit(10000))
                {
                    Shutdown();
                    return;
                }
            }
            catch (ArgumentException) { } // The previous instance has already exited.
        }
        instance = new Mutex(true, "Local\\ShareMouse.Desktop", out ownsInstance);
        if (!ownsInstance)
        {
            Shutdown();
            return;
        }

        Peer? peer = null;
        string? error = null;
        try
        {
            Directory.CreateDirectory(dataDirectory);
            preferences = new LocalPreferences(dataDirectory);
            peer = new Peer(new PeerIdentityStore(dataDirectory).LoadOrCreate(),
                Environment.MachineName, PeerPlatform.Windows, new System.Collections.Generic.HashSet<Capability>());
            Record(LogLevel.Info, $"ApplicationStarted platform=windows peerId={peer.Id.Value:D} phase=10");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            error = "无法读取本机身份。请检查 ShareMouse 数据目录，原有身份已保留。";
            Record(LogLevel.Error, "StartupFailed");
        }

        Theme.Install();
        MainWindow = new MainWindow(peer, error, OpenLogs, Record);
        if (peer is not null && error is null)
        {
            try
            {
                pairing = new PairingController((MainWindow)MainWindow, peer, dataDirectory, Record, preferences);
                if (Array.IndexOf(e.Args, "--bluetooth-discovery") >= 0)
                    pairing.StartBluetooth();
            }
            catch { ((MainWindow)MainWindow).ShowPairingStatus("无法启动配对服务，请检查端口、身份密钥或网络权限"); Record(LogLevel.Error, "SessionStartupFailed"); }
        }
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("打开 ShareMouse", null, (_, _) => ShowMainWindow());
        menu.Items.Add("打开日志目录", null, (_, _) => OpenLogs());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出 ShareMouse", null, (_, _) => Shutdown());
        tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = "ShareMouse",
            Visible = true,
            ContextMenuStrip = menu
        };
        tray.DoubleClick += (_, _) => ShowMainWindow();
        ShowMainWindow();
    }

    private async System.Threading.Tasks.Task InspectAndExit(string request)
    {
        try
        {
            await WindowsMCPInspection.Run(request);
        }
        finally { Shutdown(); }
    }


    private void ShowMainWindow()
    {
        MainWindow.Show();
        MainWindow.WindowState = WindowState.Normal;
        MainWindow.Activate();
        Record(LogLevel.Info, $"WindowShown visible={MainWindow.IsVisible} desktopSession={Process.GetCurrentProcess().SessionId} nativeWindow={new WindowInteropHelper(MainWindow).Handle}");
    }

    private void OpenLogs()
    {
        try
        {
            var directory = Path.Combine(dataDirectory, "logs");
            Directory.CreateDirectory(directory);
            Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { MessageBox.Show("无法打开日志目录，请检查本机数据目录的权限。", "ShareMouse"); }
    }

    private void Record(LogLevel level, string eventMetadata)
    {
        if (preferences?.Accepts(level) != true)
            return;
        try
        {
            logger ??= new AppLogger(Path.Combine(dataDirectory, "logs"));
            logger.Write(level, eventMetadata);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Debug.WriteLine("ShareMouse: unable to write lifecycle log.");
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        pairing?.Dispose();
        Record(LogLevel.Info, "ApplicationStopped");
        tray?.Dispose();
        logger?.Dispose();
        if (ownsInstance)
            instance?.ReleaseMutex();
        instance?.Dispose();
        base.OnExit(e);
    }
}
