using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.IO;
using System.Text;
using System.Windows.Media.Imaging;
using ShareMouse.Core;
using System.Windows.Threading;
using System.Threading;
namespace ShareMouse;

public sealed class WindowsClipboardAdapter : IDisposable
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private bool polling;
    private bool disposed;
    private readonly CancellationTokenSource lifetime = new();
    private uint observed = GetClipboardSequenceNumber();
    public Func<string[], bool, Task>? FilesCopied
    {
        get; set;
    }
    public Func<ClipboardContent?, Task>? ContentCopied
    {
        get; set;
    }
    public Func<string?, Task>? Copied
    {
        get; set;
    }
    public Action? Failed
    {
        get; set;
    }
    public Action<string>? Diagnostic
    {
        get; set;
    }
    public WindowsClipboardAdapter()
    {
        timer.Tick += async (_, _) => await Poll();
    }
    public void Start() => timer.Start();
    public async Task Poll()
    {
        var count = GetClipboardSequenceNumber();
        if (disposed || count == observed || polling)
            return;
        polling = true;
        try
        {
            var snapshot = await WindowsClipboardReader.ReadAsync(count, lifetime.Token);
            if (disposed || count != GetClipboardSequenceNumber())
                return;
            observed = count;
            if (snapshot.Files is { } files)
            {
                if (FilesCopied is not null)
                    await FilesCopied(files, snapshot.Cut);
            }
            else if (ContentCopied is not null)
                await ContentCopied(snapshot.Content);
            else if (Copied is not null)
                await Copied(snapshot.Content?.PlainText);
        }
        catch (OperationCanceledException) when (disposed) { }
        catch (Exception error)
        {
            if (disposed || count != GetClipboardSequenceNumber())
                return;
            observed = count;
            Diagnostic?.Invoke("ClipboardReadFailed reason=" + (error is TimeoutException ? "owner_timeout" : "source_unavailable"));
            if (ContentCopied is not null)
                await ContentCopied(null);
            Failed?.Invoke();
        }
        finally { polling = false; }
    }
    internal static ClipboardReadSnapshot ReadSnapshot()
    {
        var before = GetClipboardSequenceNumber();
        ClipboardContent? content = null;
        string[]? files = null;
        var cut = false;
        if (Clipboard.ContainsFileDropList())
        {
            files = Clipboard.GetFileDropList().Cast<string>().ToArray();
            var effect = Clipboard.GetData("Preferred DropEffect") as MemoryStream;
            var bytes = effect?.ToArray();
            cut = bytes is { Length: >= 4 } && BitConverter.ToInt32(bytes, 0) == 2;
        }
        else
            content = ReadContent();
        if (before != GetClipboardSequenceNumber())
            throw new IOException("Clipboard changed during read");
        return new(before, content, files, cut);
    }
    private static byte[]? Bytes(string format) => Clipboard.GetData(format) switch { MemoryStream stream => stream.ToArray(), byte[] data => data, string text => Encoding.UTF8.GetBytes(text.TrimEnd('\0')), _ => null };
    private static ClipboardContent? ReadContent()
    {
        var text = Clipboard.ContainsText(TextDataFormat.UnicodeText) ? Clipboard.GetText(TextDataFormat.UnicodeText) : null;
        if (Bytes("PNG") is { } png)
            return new("png", png);
        if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
        {
            if (image.PixelWidth > 16384 || image.PixelHeight > 16384 || (long)image.PixelWidth * image.PixelHeight > 64_000_000)
                throw new IOException("Image too large.");
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return new("png", stream.ToArray());
        }
        var url = Clipboard.GetData("UniformResourceLocatorW") switch
        {
            string value => value.TrimEnd('\0'),
            MemoryStream stream => Encoding.Unicode.GetString(stream.ToArray()).TrimEnd('\0'),
            _ => null
        };
        if (url is not null)
            return new("url", Encoding.UTF8.GetBytes(url), text ?? url);
        if (Bytes(DataFormats.Html) is { } html)
            return new("html", Encoding.UTF8.GetBytes(HtmlClipboard.Decode(new UTF8Encoding(false, true).GetString(html))), text);
        if (Bytes(DataFormats.Rtf) is { } rtf)
            return new("rtf", rtf, text);
        return text is null ? null : ClipboardContent.Text(text);
    }
    public void WriteContent(ClipboardContent content)
    {
        content.Validate();
        if (content.Kind == "text")
        {
            WriteText(new UTF8Encoding(false, true).GetString(content.Data));
            return;
        }
        var data = new DataObject();
        if (content.PlainText is { } text)
            data.SetData(DataFormats.UnicodeText, text);
        if (content.Kind == "png")
        {
            data.SetData("PNG", new MemoryStream(content.Data));
            var decoder = new PngBitmapDecoder(new MemoryStream(content.Data), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            data.SetData(DataFormats.Bitmap, decoder.Frames[0]);
        }
        else if (content.Kind == "url")
            data.SetData("UniformResourceLocatorW", new MemoryStream(Encoding.Unicode.GetBytes(new UTF8Encoding(false, true).GetString(content.Data) + "\0")));
        else if (content.Kind == "html")
            data.SetData(DataFormats.Html, HtmlClipboard.Encode(new UTF8Encoding(false, true).GetString(content.Data)));
        else if (content.Kind == "rtf")
            data.SetData(DataFormats.Rtf, new MemoryStream(content.Data));
        Clipboard.SetDataObject(data, true);
        observed = GetClipboardSequenceNumber();
    }
    public uint Sequence => GetClipboardSequenceNumber();
    public bool HasUnobservedChange => observed != GetClipboardSequenceNumber();
    public void WriteText(string text)
    {
        Clipboard.SetText(text, TextDataFormat.UnicodeText);
        observed = GetClipboardSequenceNumber();
    }
    public void WriteFiles(string[] paths)
    {
        var data = new DataObject();
        data.SetData(DataFormats.FileDrop, paths);
        data.SetData("Preferred DropEffect", new System.IO.MemoryStream(BitConverter.GetBytes(1)));
        Clipboard.SetDataObject(data, true);
        observed = GetClipboardSequenceNumber();
    }
    public static string? ExplorerDestination()
    {
        try
        {
            var type = Type.GetTypeFromProgID("Shell.Application");
            if (type is null)
                return null;
            dynamic shell = Activator.CreateInstance(type)!;
            var foreground = GetForegroundWindow();
            var name = new StringBuilder(256);
            GetClassNameW(foreground, name, name.Capacity);
            if (foreground == GetShellWindow() || name.ToString() is "Progman" or "WorkerW")
                return Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            foreach (dynamic window in shell.Windows())
                if ((long)window.HWND == foreground.ToInt64())
                {
                    string path = window.Document.Folder.Self.Path;
                    return System.IO.Directory.Exists(path) ? path : null;
                }
        }
        catch { }
        return null;
    }
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, StringBuilder name, int maximum);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    public void Dispose()
    {
        disposed = true;
        timer.Stop();
        lifetime.Cancel();
        lifetime.Dispose();
    }
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
}
