namespace ShareMouse.Core;

public enum LogLevel { Trace, Debug, Info, Warn, Error }

// Lifecycle metadata only. Never pass passwords, keys or clipboard/file content.
public sealed class AppLogger : IDisposable
{
    private readonly StreamWriter writer;

    public AppLogger(string directory)
    {
        Directory.CreateDirectory(directory);
        writer = new StreamWriter(new FileStream(Path.Combine(directory, "app.log"),
            FileMode.Append, FileAccess.Write, FileShare.Read)) { AutoFlush = true };
    }

    public void Write(LogLevel level, string eventMetadata) =>
        writer.WriteLine($"{DateTimeOffset.UtcNow:O} {level.ToString().ToUpperInvariant()} {eventMetadata}");

    public void Dispose() => writer.Dispose();
}
