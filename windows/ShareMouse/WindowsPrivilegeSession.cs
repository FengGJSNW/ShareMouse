using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using ShareMouse.Network;

namespace ShareMouse;

// TrustedInstaller is an explicit, session-only restart. Normal and login launches stay elevated user processes.
internal static class WindowsPrivilegeSession
{
    private static readonly SecurityIdentifier TrustedInstallerSid = new("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");
    private static SafeAccessTokenHandle? originalUser;
    private static RegistryKey? userHive;
    private static IdentityStore? preparedIdentity;
    private static string? originalName, dataDirectory, readyFile;
    public static string DataDirectory => dataDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShareMouse");
    public static string UserName
    {
        get { if (originalName is not null) return originalName; using var identity = WindowsIdentity.GetCurrent(); return identity.Name; }
    }
    public static bool IsTrustedInstaller
    {
        get { using var identity = WindowsIdentity.GetCurrent(); return new WindowsPrincipal(identity).IsInRole(TrustedInstallerSid); }
    }

    public static void Initialize(string[] arguments)
    {
        var source = arguments.FirstOrDefault(a => a.StartsWith("--ti-source=", StringComparison.Ordinal));
        if (source is null)
        {
            if (IsTrustedInstaller)
                throw new InvalidOperationException("请从设置中的 TrustedInstaller 重启入口进入，以保留原用户身份。");
            return;
        }
        if (!IsTrustedInstaller || !int.TryParse(source[12..], out var sourcePid))
            throw new InvalidOperationException("新实例没有获得 TrustedInstaller 令牌。");
        using var parent = Process.GetProcessById(sourcePid);
        using var sourceProcess = OpenProcess(0x1000, false, sourcePid);
        if (sourceProcess.IsInvalid || !SameExecutable(sourceProcess) ||
            !OpenProcessToken(sourceProcess, 0x000A, out var token))
            throw new InvalidOperationException("无法读取重启来源的用户令牌。");
        using (token)
        {
            if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 2, out var duplicate))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            originalUser = duplicate;
        }
        var sid = WindowsIdentity.RunImpersonated(originalUser, () =>
        {
            using var user = WindowsIdentity.GetCurrent();
            originalName = user.Name;
            var localData = new Guid("F1B32785-6FBA-4FCF-9D55-7B8E7F157091");
            var status = SHGetKnownFolderPath(ref localData, 0, originalUser.DangerousGetHandle(), out var path);
            if (status != 0) Marshal.ThrowExceptionForHR(status);
            try { dataDirectory = Path.Combine(Marshal.PtrToStringUni(path)!, "ShareMouse"); }
            finally { Marshal.FreeCoTaskMem(path); }
            return user.User?.Value ?? throw new InvalidOperationException("来源用户没有 SID。");
        });
        var requestedReady = arguments.FirstOrDefault(a => a.StartsWith("--ti-ready=", StringComparison.Ordinal))?[11..];
        if (requestedReady is null || !Path.GetFullPath(requestedReady).StartsWith(Path.GetFullPath(DataDirectory) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            || !Path.GetFileName(requestedReady).StartsWith("trustedinstaller-", StringComparison.Ordinal) || !requestedReady.EndsWith(".json.ready", StringComparison.Ordinal))
            throw new InvalidOperationException("无效的重启交接路径。");
        readyFile = requestedReady;
        if (parent.SessionId != Process.GetCurrentProcess().SessionId)
            throw new InvalidOperationException("提权实例没有进入当前交互桌面。");
        userHive = Registry.Users.OpenSubKey(sid, writable: true) ?? throw new InvalidOperationException("无法打开原用户的配置注册表。");
        var result = RegOverridePredefKey(new IntPtr(unchecked((int)0x80000001)), userHive.Handle.DangerousGetHandle());
        if (result != 0)
            throw new System.ComponentModel.Win32Exception(result);
        var peerId = File.ReadAllText(Path.Combine(DataDirectory, "peer-id")).Trim();
        preparedIdentity = WindowsIdentity.RunImpersonated(originalUser, () =>
        {
            using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadOnly);
            var certificate = store.Certificates.Cast<X509Certificate2>().FirstOrDefault(c => c.Subject == "CN=ShareMouse-" + peerId)
                ?? throw new CryptographicException("原用户的配对证书不存在；不会生成替代身份。");
            using var key = certificate.GetRSAPrivateKey() ?? throw new CryptographicException("原配对私钥不可用。");
            using var publicKey = certificate.GetRSAPublicKey()!;
            var challenge = RandomNumberGenerator.GetBytes(32);
            var signature = key.SignData(challenge, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            if (!publicKey.VerifyData(challenge, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
                throw new CryptographicException("原配对私钥校验失败。");
            // CNG user keys must also be opened as that user during TLS authentication.
            return new IdentityStore(peerId, certificate, originalUser);
        });
        WriteReady(JsonSerializer.Serialize(new { pid = Environment.ProcessId }));
    }

    public static bool ReportInitializationFailure(Exception error)
    {
        if (readyFile is null) return false;
        File.WriteAllText(Path.Combine(DataDirectory, "trustedinstaller-last-error.txt"), error.ToString());
        WriteReady(JsonSerializer.Serialize(new { error = "新实例初始化失败：" + error.Message }));
        return true;
    }

    private static void WriteReady(string content)
    {
        File.WriteAllText(readyFile + ".tmp", content);
        File.Move(readyFile + ".tmp", readyFile!, true);
    }
    public static T AsProfileUser<T>(Func<T> action) => originalUser is null ? action() : WindowsIdentity.RunImpersonated(originalUser, action);
    public static IdentityStore LoadIdentity(string peerId)
    {
        if (preparedIdentity is null) return new IdentityStore(peerId);
        var value = preparedIdentity;
        preparedIdentity = null;
        if (value.Identity.PeerID != peerId) { value.Dispose(); throw new CryptographicException("重启后的设备身份不一致。"); }
        return value;
    }

    public static async Task RestartAsync()
    {
        if (IsTrustedInstaller) return;
        var request = Path.Combine(DataDirectory, "trustedinstaller-" + Guid.NewGuid().ToString("N") + ".json");
        var ready = request + ".ready";
        var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "PowerShell", "profile.ps1");
        var script = Path.Combine(AppContext.BaseDirectory, "Restart-TrustedInstaller.ps1");
        if (!File.Exists(profile) || !File.Exists(script))
            throw new FileNotFoundException("找不到 TrustInstaller-Start 配置或随程序安装的重启脚本。");
        var arguments = Environment.GetCommandLineArgs().Skip(1).Where(a => !a.StartsWith("--ti-", StringComparison.Ordinal) && !a.StartsWith("--restart-after=", StringComparison.Ordinal))
            .Concat(new[] { "--ti-source=" + Environment.ProcessId, "--ti-ready=" + ready, "--restart-after=" + Environment.ProcessId });
        var commandLine = string.Join(" ", new[] { Environment.ProcessPath! }.Concat(arguments).Select(Quote));
        File.WriteAllText(request, JsonSerializer.Serialize(new { Profile = profile, CommandLine = commandLine, WorkingDirectory = AppContext.BaseDirectory }));
        try
        {
            var start = new ProcessStartInfo("pwsh.exe") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = AppContext.BaseDirectory };
            foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-File", script, "-Request", request }) start.ArgumentList.Add(argument);
            using var launcher = Process.Start(start) ?? throw new IOException("无法启动 PowerShell 7。");
            var deadline = Environment.TickCount64 + 45000;
            while (Environment.TickCount64 < deadline)
            {
                if (File.Exists(ready))
                {
                    using var reply = JsonDocument.Parse(File.ReadAllText(ready));
                    if (reply.RootElement.TryGetProperty("error", out var error)) throw new InvalidOperationException(error.GetString());
                    var pid = reply.RootElement.GetProperty("pid").GetInt32();
                    using var process = OpenProcess(0x1000, false, pid);
                    if (process.IsInvalid || !SameExecutable(process) || !OpenProcessToken(process, 0x000A, out var token))
                        throw new InvalidOperationException("无法确认新实例的进程令牌。");
                    using (token)
                    using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
                        if (!new WindowsPrincipal(identity).IsInRole(TrustedInstallerSid))
                            throw new InvalidOperationException("新实例没有 TrustedInstaller 权限；当前实例保留。");
                    return;
                }
                if (launcher.HasExited && launcher.ExitCode != 0) throw new IOException("TrustInstaller-Start 启动失败。");
                await Task.Delay(100);
            }
            throw new TimeoutException("等待提权实例超时；当前实例保留。");
        }
        catch (Exception error)
        {
            File.WriteAllText(Path.Combine(DataDirectory, "trustedinstaller-last-error.txt"), error.ToString());
            throw;
        }
        finally { File.Delete(request); File.Delete(ready); }
    }

    private static bool SameExecutable(SafeProcessHandle process)
    {
        var name = new StringBuilder(32768); var length = name.Capacity;
        return QueryFullProcessImageName(process, 0, name, ref length) && string.Equals(name.ToString(), Environment.ProcessPath, StringComparison.OrdinalIgnoreCase);
    }
    private static string Quote(string value)
    {
        var output = new StringBuilder("\""); var slashes = 0;
        foreach (var character in value)
        {
            if (character == '\\') { slashes++; continue; }
            output.Append('\\', character == '"' ? slashes * 2 + 1 : slashes); output.Append(character); slashes = 0;
        }
        return output.Append('\\', slashes * 2).Append('"').ToString();
    }
    public static void Dispose()
    {
        preparedIdentity?.Dispose();
        if (userHive is not null) RegOverridePredefKey(new IntPtr(unchecked((int)0x80000001)), IntPtr.Zero);
        userHive?.Dispose(); originalUser?.Dispose();
    }
    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr user, out IntPtr path);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(SafeProcessHandle process, int flags, StringBuilder name, ref int size);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(SafeAccessTokenHandle token, uint access, IntPtr attributes, int impersonation, int type, out SafeAccessTokenHandle duplicate);
    [DllImport("advapi32.dll")] private static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
}
