using System;
using System.IO;
using System.Text.Json;
using Microsoft.Win32;
using ShareMouse.Core;
namespace ShareMouse;
public sealed class LocalPreferences {
    private sealed record Saved(string Renderer,string Corner,string LogLevel,bool OnboardingComplete, bool? NetworkAvailable = null, bool? BluetoothAvailable = null, bool? McpEnabled=null,bool? AllowComputerUse=null,bool? AllowMcpFiles=null,bool? ComputerCursorHints=null,bool? BluetoothInputOnly=null,string? McpToastStyle=null,string? GameMouseMode=null,bool? LogEnabled=null);
    private readonly string file;
    public string Renderer { get; set; }="custom";
    public string Corner { get; set; }="bottomRight";
    public string LogLevel { get; set; }="INFO";
    public bool LogEnabled { get; set; }=true;
    public bool NetworkAvailable { get; set; } = true;
    public bool BluetoothInputOnly { get; set; }
    public string GameMouseMode {get;set;}="auto";
    public bool BluetoothAvailable { get; set; } = true;
    public bool McpEnabled {get;set;}
    public bool AllowComputerUse {get;set;}
    public bool AllowMcpFiles {get;set;}
    public bool ComputerCursorHints {get;set;}=true;
    public string McpToastStyle {get;set;}="text";
    public bool OnboardingComplete { get; set; }
    public string Status { get; private set; }="";
    public LocalPreferences(string directory) { file=Path.Combine(directory,"local-settings.json"); if(File.Exists(file)) try { var saved=JsonSerializer.Deserialize<Saved>(File.ReadAllText(file)); if(saved is not null) { Renderer=saved.Renderer; Corner=saved.Corner; LogLevel=saved.LogLevel; LogEnabled=saved.LogEnabled??true; OnboardingComplete=saved.OnboardingComplete; NetworkAvailable=saved.NetworkAvailable??true; BluetoothAvailable=saved.BluetoothAvailable??true; McpEnabled=saved.McpEnabled??false;AllowComputerUse=saved.AllowComputerUse??false;AllowMcpFiles=saved.AllowMcpFiles??false;ComputerCursorHints=saved.ComputerCursorHints??true;BluetoothInputOnly=saved.BluetoothInputOnly??false;McpToastStyle=saved.McpToastStyle=="hidden"?"hidden":"text";GameMouseMode=saved.GameMouseMode is "on" or "off"?saved.GameMouseMode:"auto";} } catch { Status="设置无法读取，原文件已保留"; }
        // Preserve the selected input transport across ordinary and login launches.
        if(Array.IndexOf(Environment.GetCommandLineArgs(),"--bluetooth-input")>=0) { BluetoothInputOnly=true; if(Status.Length==0) Save(); }
    }
    public void Save() { try { File.WriteAllText(file+".tmp",JsonSerializer.Serialize(new Saved(Renderer,Corner,LogLevel,OnboardingComplete,NetworkAvailable,BluetoothAvailable,McpEnabled,AllowComputerUse,AllowMcpFiles,ComputerCursorHints,BluetoothInputOnly,McpToastStyle,GameMouseMode,LogEnabled))); File.Move(file+".tmp",file,true); } catch { Status="无法保存本机设置"; } }
    private const string LoginTaskName="ShareMouse Login";
    private static dynamic LoginScheduler() {dynamic service=Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")!)!;service.Connect();return service;}
    public bool Startup {get {
        try {dynamic folder=LoginScheduler().GetFolder("\\");dynamic task=folder.GetTask(LoginTaskName);if((bool)task.Enabled)return true;}catch { }
        using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");return key?.GetValue("ShareMouse Development") is string;
    }}
    public void SetStartup(bool value) {try {
        dynamic service=LoginScheduler();dynamic folder=service.GetFolder("\\");
        if(value) {
            if(!WindowsInputStatus.IsElevated)throw new UnauthorizedAccessException("Administrator consent is required.");
            var account=System.Security.Principal.WindowsIdentity.GetCurrent().Name;dynamic task=service.NewTask(0);
            task.RegistrationInfo.Description="ShareMouse 登录启动；使用已授权的管理员权限，可在软件设置取消。";
            task.Principal.UserId=account;task.Principal.LogonType=3;task.Principal.RunLevel=1;
            task.Settings.Enabled=true;task.Settings.DisallowStartIfOnBatteries=false;task.Settings.StopIfGoingOnBatteries=false;task.Settings.ExecutionTimeLimit="PT0S";task.Settings.MultipleInstances=2;
            dynamic trigger=task.Triggers.Create(9);trigger.UserId=account;
            dynamic action=task.Actions.Create(0);action.Path=Path.Combine(AppContext.BaseDirectory,"ShareMouse.exe");action.WorkingDirectory=AppContext.BaseDirectory;
            folder.RegisterTaskDefinition(LoginTaskName,task,6,account,null,3);
        } else {try{folder.DeleteTask(LoginTaskName,0);}catch { }}
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");key.DeleteValue("ShareMouse Development",false);
        Status="登录启动设置已更新";
    } catch {Status="无法设置登录启动；请确认管理员授权。";}}
    public void MigrateElevatedStartup() {
        using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if(key?.GetValue("ShareMouse Development") is string)SetStartup(true);
    }
    public bool Accepts(LogLevel level) { if(!LogEnabled)return false; var minimum=Enum.TryParse<LogLevel>(LogLevel,true,out var result)?result:ShareMouse.Core.LogLevel.Info; return level>=minimum; }
}
