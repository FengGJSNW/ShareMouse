using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ShareMouse.Core;

namespace ShareMouse;

internal sealed record ClipboardReadSnapshot(uint Sequence, ClipboardContent? Content, string[]? Files, bool Cut);

// Clipboard delayed rendering can wait for a hung or closing owner. Keep that
// native call outside the thread that owns input hooks and input acknowledgements.
internal static class WindowsClipboardReader
{
    internal const string HelperArgument = "--clipboard-read";
    private const int MaxOutput = 40 * 1024 * 1024;
    internal static int RunHelper(Func<ClipboardReadSnapshot> read)
    {
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(read());
            if (bytes.Length > MaxOutput)
                throw new IOException("Clipboard result exceeded limit");
            using var output = Console.OpenStandardOutput();
            output.Write(bytes);
            return 0;
        }
        catch (Exception error)
        {
            // No clipboard text, paths or native provider messages in diagnostics.
            Console.Error.WriteLine("ClipboardReadFailed type=" + error.GetType().Name);
            return 1;
        }
    }
    internal static async Task<ClipboardReadSnapshot> ReadAsync(uint sequence, CancellationToken token,
        string? executable = null, string? arguments = null, int timeoutMs = 2000, Action<int>? started = null)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo(executable ?? Environment.ProcessPath ?? throw new IOException("Application path unavailable"), arguments ?? HelperArgument)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false, true),
                StandardErrorEncoding = new UTF8Encoding(false, true)
            }
        };
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token);
        if (!process.Start())
            throw new IOException("Clipboard helper could not start");
        var output = ReadBounded(process.StandardOutput, MaxOutput, lifetime.Token);
        var errors = ReadBounded(process.StandardError, 4096, lifetime.Token);
        var watch = Stopwatch.StartNew();
        try
        {
            started?.Invoke(process.Id);
            while (!process.HasExited)
            {
                token.ThrowIfCancellationRequested();
                process.Refresh();
                if (process.HasExited)
                    break;
                if (watch.ElapsedMilliseconds > timeoutMs)
                    throw new TimeoutException("Clipboard owner did not respond");
                if (process.PrivateMemorySize64 > 768L * 1024 * 1024)
                    throw new IOException("Clipboard helper memory limit");
                if (output.IsFaulted)
                    await output;
                if (errors.IsFaulted)
                    await errors;
                await Task.Delay(25, token).ConfigureAwait(false);
            }
            await process.WaitForExitAsync(token).ConfigureAwait(false);
            var json = await output.ConfigureAwait(false);
            await errors.ConfigureAwait(false);
            if (process.ExitCode != 0)
                throw new IOException("Clipboard source unavailable");
            var snapshot = JsonSerializer.Deserialize<ClipboardReadSnapshot>(json) ?? throw new IOException("Invalid clipboard result");
            snapshot.Content?.Validate();
            if (snapshot.Sequence != sequence)
                throw new IOException("Clipboard changed during read");
            return snapshot;
        }
        finally
        {
            lifetime.Cancel();
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            }
            // Observe cancelled pipe tasks after killing the created process.
            try
            {
                await Task.WhenAll(output, errors).ConfigureAwait(false);
            }
            catch { }
        }
    }
    private static async Task<string> ReadBounded(StreamReader reader, int limit, CancellationToken token)
    {
        var buffer = new char[8192];
        var result = new StringBuilder();
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) > 0)
        {
            if (result.Length + count > limit)
                throw new IOException("Clipboard helper output limit");
            result.Append(buffer, 0, count);
        }
        return result.ToString();
    }
}
