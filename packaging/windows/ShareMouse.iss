#ifndef ReleaseVersion
  #define ReleaseVersion "v0.1.0-alpha.3"
#endif
#ifndef NumericVersion
  #define NumericVersion "0.1.0.37"
#endif
#ifndef PublishDir
  #error PublishDir must point to the self-contained win-x64 output
#endif
#ifndef OutputDirPath
  #error OutputDirPath is required
#endif

[Setup]
AppId={{6775445E-EC95-4C50-A1E3-E6354EB447A2}
AppName=ShareMouse
AppVersion={#ReleaseVersion}
AppVerName=ShareMouse {#ReleaseVersion}
AppPublisher=ShareMouse Project
SetupIconFile=..\..\resources\app-icon\ShareMouse.ico
DefaultDirName={autopf}\ShareMouse
DefaultGroupName=ShareMouse
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\ShareMouse.exe
OutputDir={#OutputDirPath}
OutputBaseFilename=ShareMouse-{#ReleaseVersion}-windows-x64-setup
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
PrivilegesRequired=admin
VersionInfoVersion={#NumericVersion}
VersionInfoProductVersion={#NumericVersion}
VersionInfoProductTextVersion={#ReleaseVersion}
Compression=lzma2/normal
SolidCompression=yes
LZMANumBlockThreads=2
WizardStyle=modern
CloseApplications=no
RestartApplications=no
InfoBeforeFile=..\安装说明.txt
UninstallDisplayName=ShareMouse {#ReleaseVersion} (x64)

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.DesktopIcon=创建桌面快捷方式
chinesesimplified.NetworkAccess=允许 ShareMouse 接收配对、发现与加密网络连接
chinesesimplified.LaunchApp=启动 ShareMouse（需要管理员授权）
english.DesktopIcon=Create a desktop shortcut
english.NetworkAccess=Allow ShareMouse pairing, discovery and encrypted network connections
english.LaunchApp=Launch ShareMouse (administrator approval required)

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; Flags: unchecked
Name: "networkaccess"; Description: "{cm:NetworkAccess}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"
Source: "..\安装说明.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\ShareMouse"; Filename: "{app}\ShareMouse.exe"; WorkingDir: "{app}"
Name: "{group}\卸载 ShareMouse"; Filename: "{uninstallexe}"
Name: "{userdesktop}\ShareMouse"; Filename: "{app}\ShareMouse.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\ShareMouse.exe"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent shellexec unchecked

[Code]
const
  RulePrefix = 'ShareMouse installed 6775445E-EC95-4C50-A1E3-E6354EB447A2';

procedure NetworkRule(Suffix, Protocol, Port: String; AddRule: Boolean);
var
  Args: String;
  ResultCode: Integer;
begin
  Args := 'advfirewall firewall delete rule name="' + RulePrefix + Suffix + '"';
  if not Exec(ExpandConstant('{sys}\netsh.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('Could not remove previous installer-owned firewall rule');
  if AddRule then begin
    Args := 'advfirewall firewall add rule name="' + RulePrefix + Suffix +
      '" dir=in action=allow program="' + ExpandConstant('{app}\ShareMouse.exe') +
      '" protocol=' + Protocol + ' localport=' + Port + ' profile=any';
    if not Exec(ExpandConstant('{sys}\netsh.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      MsgBox('ShareMouse: network permission could not be configured. Check Windows Firewall before pairing.', mbError, MB_OK);
  end;
end;

procedure ConfigureNetwork(AddRules: Boolean);
begin
  NetworkRule(' TCP', 'TCP', '49160', AddRules);
  NetworkRule(' QUIC', 'UDP', '49164', AddRules);
  NetworkRule(' discovery', 'UDP', '49161', AddRules);
  NetworkRule(' mDNS', 'UDP', '5353', AddRules);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then ConfigureNetwork(WizardIsTaskSelected('networkaccess'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then ConfigureNetwork(False);
end;
