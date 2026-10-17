using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using ShareMouse.Core;
namespace ShareMouse.Network;

public static class FileStorage
{
    public static bool IsTransferMetadata(string name) => name == ".DS_Store" || name.StartsWith(".ShareMouse-", StringComparison.Ordinal) && Guid.TryParse(name[".ShareMouse-".Length..], out _) || name.StartsWith(".ShareMouse.", StringComparison.Ordinal) && name.Length > ".ShareMouse.".Length;
    public static LocalFile Inspect(string path, FileItem template)
    {
        var attributes = File.GetAttributes(path);
        var reparse = (attributes & FileAttributes.ReparsePoint) != 0;
        FileSystemInfo node = (attributes & FileAttributes.Directory) != 0 ? new DirectoryInfo(path) : new FileInfo(path);
        var link = reparse ? node.LinkTarget?.Replace('\\', '/') : null;
        if (reparse && (link is null || !ValidLink(template.RelativePath, link)))
            throw new IOException("Only relative links inside the selected folder can be transferred.");
        using var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000 | (reparse ? 0x00200000u : 0), IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        var linkDirectory = (attributes & FileAttributes.Directory) != 0;
        var directory = linkDirectory && !reparse;
        var modified = new DateTimeOffset(DateTime.FromFileTimeUtc(((long)info.WriteHigh << 32) | info.WriteLow)).ToUnixTimeMilliseconds();
        return new(template with
        {
            Directory = directory,
            LinkTarget = link,
            LinkDirectory = reparse ? linkDirectory : null,
            Size = directory || reparse ? 0 : ((long)info.SizeHigh << 32) | info.SizeLow,
            Modified = modified
        }, path, $"{info.Volume}:{info.IndexHigh}:{info.IndexLow}" + (directory ? "" : $":{info.WriteHigh}:{info.WriteLow}"));
    }
    public static bool Same(LocalFile a, LocalFile b) => a.Identity == b.Identity && a.Item.Size == b.Item.Size && a.Item.Modified == b.Item.Modified && a.Item.Directory == b.Item.Directory && a.Item.LinkTarget == b.Item.LinkTarget && a.Item.LinkDirectory == b.Item.LinkDirectory;
    public static bool Unchanged(LocalFile file)
    {
        try
        {
            return Same(file, Inspect(file.Path, file.Item));
        }
        catch { return false; }
    }
    public static Task<(LocalRoot[], LocalFile[])> Scan(string[] paths, FileTransaction? previous = null) => Task.Run(() =>
    {
        var roots = new List<LocalRoot>();
        var files = new List<LocalFile>();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var previousFiles = (previous?.Files ?? []).ToDictionary(f => f.Item.RootID + ":" + f.Item.RelativePath);
        foreach (var selected in paths.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var path = Path.GetFullPath(selected);
            var name = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (string.IsNullOrEmpty(name))
                throw new IOException("Select files or folders, rather than a volume root.");
            var root = previous?.Roots.FirstOrDefault(old => string.Equals(old.Path, path, StringComparison.OrdinalIgnoreCase)) ?? new LocalRoot(Guid.NewGuid().ToString("D"), path);
            name = previous?.Files.FirstOrDefault(f => f.Item.Id == root.Id)?.Item.RelativePath ?? name;
            var original = name;
            var suffix = 2;
            while (!names.Add(name))
                name = original + $" ({suffix++})";
            roots.Add(root);
            Walk(path, name, root.Id, true);
        }
        return (roots.ToArray(), files.ToArray());
        void Walk(string path, string relative, string rootID, bool top)
        {
            if (System.Text.Encoding.UTF8.GetByteCount(relative) > 1024)
                throw new IOException("A relative filename exceeds the transfer limit.");
            if (files.Count >= 100000)
                throw new IOException("This transaction exceeds 100,000 filesystem entries.");
            var old = previousFiles.GetValueOrDefault(rootID + ":" + relative);
            var item = new FileItem(old?.Item.Id ?? (top ? rootID : Guid.NewGuid().ToString("D")), rootID, relative, false, 0, 0);
            var current = Inspect(path, item);
            if (current.Item.LinkTarget is { } link)
            {
                var root = roots.First(r => r.Id == rootID).Path;
                var resolved = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, link.Replace('/', Path.DirectorySeparatorChar)));
                var canonical = ((File.GetAttributes(path) & FileAttributes.Directory) != 0 ? new DirectoryInfo(path) as FileSystemInfo : new FileInfo(path)).ResolveLinkTarget(true)?.FullName ?? resolved;
                if (top || !ValidLink(relative, link) || !Inside(root, resolved) || !Inside(root, canonical))
                    throw new IOException("Link target escaped the selected folder.");
            }
            if (old is not null && Same(old, current))
                current = current with
                {
                    Item = current.Item with
                    {
                        Hash = old.Item.Hash
                    }
                };
            files.Add(current);
            if (current.Item.Directory)
                foreach (var child in Directory.EnumerateFileSystemEntries(path).Where(p => !IsTransferMetadata(Path.GetFileName(p))).Order(StringComparer.Ordinal))
                    Walk(child, relative + "/" + Path.GetFileName(child), rootID, false);
        }
    });
    private static bool Inside(string root, string path) => string.Equals(Path.GetFullPath(root), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase) || Path.GetFullPath(path).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    public static bool ValidLink(string relative, string target)
    {
        if (string.IsNullOrEmpty(target) || System.Text.Encoding.UTF8.GetByteCount(target) > 1024 || target.StartsWith('/') || target.Contains('\\') || target.Contains(':') || target.Contains('\0'))
            return false;
        var parts = relative.Split('/').SkipLast(1).ToList();
        if (parts.Count == 0)
            return false;
        foreach (var part in target.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == "..")
            {
                if (parts.Count <= 1)
                    return false;
                parts.RemoveAt(parts.Count - 1);
            }
            else if (part != ".")
            {
                if (part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                    return false;
                parts.Add(part);
            }
        }
        return true;
    }
    public static void FinishLink(TransferFile file, string destination, string root)
    {
        var link = file.Item.LinkTarget;
        if (link is null || !ValidLink(file.Item.RelativePath, link))
            throw new IOException("Invalid symbolic link.");
        EnsureParent(destination, file.Target);
        var resolved = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file.Target)!, link.Replace('/', Path.DirectorySeparatorChar)));
        if (!Inside(root, resolved))
            throw new IOException("Link target escaped its folder.");
        // Check existing target ancestors without following a junction outside the received root.
        var current = root;
        foreach (var part in Path.GetRelativePath(root, resolved).Split(Path.DirectorySeparatorChar))
        {
            if (part == ".")
                continue;
            current = Path.Combine(current, part);
            if (File.Exists(current) || Directory.Exists(current))
            {
                var a = File.GetAttributes(current);
                if ((a & FileAttributes.ReparsePoint) != 0)
                {
                    FileSystemInfo node = (a & FileAttributes.Directory) != 0 ? new DirectoryInfo(current) : new FileInfo(current);
                    var final = node.ResolveLinkTarget(true)?.FullName;
                    if (final is null || !Inside(root, final))
                        throw new IOException("Link target escaped its folder.");
                }
            }
        }
        if (File.Exists(file.Target) || Directory.Exists(file.Target))
        {
            var a = File.GetAttributes(file.Target);
            if ((a & FileAttributes.Directory) != 0)
            {
                if ((a & FileAttributes.ReparsePoint) == 0)
                    throw new IOException("Cannot replace a folder with a symbolic link.");
                Directory.Delete(file.Target);
            }
            else
                File.Delete(file.Target);
        }
        var native = link.Replace('/', Path.DirectorySeparatorChar);
        if (file.Item.LinkDirectory == true)
            Directory.CreateSymbolicLink(file.Target, native);
        else
            File.CreateSymbolicLink(file.Target, native);
        file.CompletedIdentity = Inspect(file.Target, file.Item).Identity;
    }
    public static LocalFile[] Additions(LocalFile[] indexed, LocalFile[] scanned)
    {
        var known = indexed.Select(f => f.Item.RootID + ":" + f.Item.RelativePath).ToHashSet(StringComparer.Ordinal);
        return scanned.Where(f => !known.Contains(f.Item.RootID + ":" + f.Item.RelativePath)).ToArray();
    }
    public static async Task<string> Hash(string path)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream)).ToLowerInvariant();
    }
    public static string Target(string destination, string relative)
    {
        var parts = relative.Split('/');
        if (parts.Length == 0 || parts.Any(p => p.Length == 0 || p is "." or ".." || p.Contains('\\') || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || p.EndsWith('.') || p.EndsWith(' ') || System.Text.RegularExpressions.Regex.IsMatch(p.Split('.')[0], @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)))
            throw new IOException("Invalid destination filename.");
        var root = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(Path.Combine(root, Path.Combine(parts)));
        if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Destination path escaped its folder.");
        return target;
    }
    public static void EnsureParent(string destination, string target)
    {
        var root = Path.GetFullPath(destination);
        var relative = Path.GetRelativePath(root, Path.GetDirectoryName(target)!);
        if (relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar))
            throw new IOException("Invalid parent path.");
        var current = root;
        foreach (var part in relative.Split(Path.DirectorySeparatorChar).Where(p => p != "."))
        {
            current = Path.Combine(current, part);
            if (File.Exists(current) || Directory.Exists(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0 || !Directory.Exists(current))
                    throw new IOException("Destination contains a link or a file in place of a folder.");
            }
            else
                Directory.CreateDirectory(current);
        }
    }
    public static string Partial(string destination, string taskID, string itemID)
    {
        if (!Guid.TryParse(taskID, out _) || !Guid.TryParse(itemID, out _))
            throw new IOException("Invalid transfer identity.");
        var directory = Target(destination, ".ShareMouse-" + taskID);
        EnsureParent(destination, Path.Combine(directory, itemID));
        File.SetAttributes(directory, File.GetAttributes(directory) | FileAttributes.Hidden);
        return Path.Combine(directory, itemID + ".partial");
    }
    public static async Task Append(TransferFile file, byte[] data)
    {
        await using var output = new FileStream(file.Partial, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None, 20000, FileOptions.Asynchronous);
        if (output.Length < file.Received)
            throw new IOException("The partial file was removed or shortened.");
        output.SetLength(file.Received);
        output.Position = file.Received;
        await output.WriteAsync(data);
        output.Flush(true);
    }
    public static void Finish(TransferFile file, string destination)
    {
        EnsureParent(destination, file.Target);
        File.Move(file.Partial, file.Target, true);
        var staging = Path.GetDirectoryName(file.Partial)!;
        if (IsTransferMetadata(Path.GetFileName(staging)))
            try
            {
                Directory.Delete(staging, false);
            }
            catch (IOException) { }
        File.SetLastWriteTimeUtc(file.Target, DateTimeOffset.FromUnixTimeMilliseconds(file.Item.Modified).UtcDateTime);
        file.CompletedIdentity = Inspect(file.Target, file.Item).Identity;
    }
    public static bool CompletedUnchanged(TransferFile file)
    {
        try
        {
            var actual = Inspect(file.Target, file.Item);
            return actual.Identity == file.CompletedIdentity && actual.Item.Size == file.Item.Size && actual.Item.Directory == file.Item.Directory && actual.Item.LinkTarget == file.Item.LinkTarget;
        }
        catch { return false; }
    }
    public static async Task<byte[]> Read(LocalFile file, long offset, int maximum = 20000)
    {
        if (offset < 0 || offset > file.Item.Size || !Unchanged(file))
            throw new IOException("Source changed.");
        await using var input = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 20000, FileOptions.Asynchronous);
        input.Position = offset;
        var data = new byte[(int)Math.Min(Math.Clamp(maximum, 1, 32000), file.Item.Size - offset)];
        await input.ReadExactlyAsync(data);
        return data;
    }
    public static async Task DeleteVerifiedRoot(FileTransaction snapshot, string rootID, CancellationToken cancellation = default)
    {
        var expected = snapshot.Files.Where(f => f.Item.RootID == rootID).ToArray();
        var root = snapshot.Roots.Single(r => r.Id == rootID);
        var scanned = await Scan([root.Path], snapshot);
        if (scanned.Item2.Length > expected.Length || scanned.Item2.Any(actual => !expected.Any(f => actual.Item.RelativePath == f.Item.RelativePath && (f.Item.Directory ? actual.Item.Directory && f.Identity == actual.Identity : Same(f, actual)))))
            throw new IOException("Cut source changed; kept the source.");
        foreach (var file in expected.Where(f => File.Exists(f.Path) || Directory.Exists(f.Path)).OrderByDescending(f => f.Item.RelativePath.Count(c => c == '/')))
        {
            cancellation.ThrowIfCancellationRequested();
            if (file.Item.Directory)
            {
                var actual = Inspect(file.Path, file.Item);
                if (actual.Identity != file.Identity || !actual.Item.Directory)
                    throw new IOException("Cut folder identity changed.");
                var metadata = Path.Combine(file.Path, ".DS_Store");
                if (File.Exists(metadata))
                {
                    var attributes = File.GetAttributes(metadata);
                    if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                        throw new IOException("Metadata source changed.");
                    File.Delete(metadata);
                }
                Directory.Delete(file.Path, false);
            }
            else
            {
                if (!Unchanged(file))
                    throw new IOException("Cut source changed; kept the remaining source.");
                File.Delete(file.Path);
            }
        }
    }
    public static void DeleteAll(FileTransaction transaction)
    {
        static void Remove(string path)
        {
            if (!File.Exists(path) && !Directory.Exists(path))
                return;
            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                if ((attributes & FileAttributes.Directory) != 0)
                    Directory.Delete(path);
                else
                    File.Delete(path);
                return;
            }
            if ((attributes & FileAttributes.Directory) != 0)
            {
                foreach (var child in Directory.EnumerateFileSystemEntries(path))
                    Remove(child);
                Directory.Delete(path, false);
            }
            else
                File.Delete(path);
        }
        foreach (var root in transaction.Roots.Where(r => File.Exists(r.Path) || Directory.Exists(r.Path)))
        {
            var expected = transaction.Files.First(f => f.Item.Id == root.Id);
            var actual = Inspect(root.Path, expected.Item);
            var expectedNode = expected.Item.Directory ? expected.Identity : expected.Identity[..expected.Identity.LastIndexOf(':')];
            var actualNode = actual.Item.Directory ? actual.Identity : actual.Identity[..actual.Identity.LastIndexOf(':')];
            if (expected.Item.Directory != actual.Item.Directory || expectedNode != actualNode)
                throw new IOException("Selected Cut root was replaced; source kept.");
        }
        foreach (var root in transaction.Roots)
            Remove(root.Path);
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInfoNative
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")] private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfoNative information);
}
