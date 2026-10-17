using System.Net;
using System.Net.Sockets;
using System.Threading.Channels;
using ShareMouse.Core;

namespace ShareMouse.Network;

// This private loopback byte adapter exposes only TLS ciphertext to GATT.
internal sealed class BleByteBridge : IDisposable
{
    private readonly Func<byte[], Task> forward;
    private readonly Action ended;
    private readonly Action<string> status;
    private readonly CancellationTokenSource lifetime = new();
    private sealed record Received(byte[] Bytes, TaskCompletionSource Completion);
    private readonly Channel<Received> received = Channel.CreateBounded<Received>(new BoundedChannelOptions(512) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private int queuedBytes;
    private readonly BleStreamFraming fragments = new();
    private readonly object fragmentGate = new();
    private readonly TaskCompletionSource<TcpClient> connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TcpListener? listener;
    private TcpClient? connection;
    private int closed;
    private long receivedBytes, forwardedBytes, lastProgress;

    public BleByteBridge(Func<byte[], Task> forward, Action ended, Action<string>? status = null)
    {
        this.forward = forward;
        this.ended = ended;
        this.status = status ?? (_ => { });
        _ = Task.Run(ReceivePump);
    }
    public int Listen()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _ = Task.Run(Accept);
        return port;
    }
    private async Task Accept()
    {
        try
        {
            Start(await listener!.AcceptTcpClientAsync(lifetime.Token).ConfigureAwait(false));
            listener.Stop();
        }
        catch { Dispose(); }
    }
    public async Task ConnectAsync(int port)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(IPAddress.Loopback, port, lifetime.Token).ConfigureAwait(false);
            Start(client);
        }
        catch { client.Dispose(); Dispose(); throw; }
    }
    private void Start(TcpClient client)
    {
        connection = client;
        client.NoDelay = true;
        connected.TrySetResult(client);
        _ = Task.Run(Pump);
    }
    // Enqueue synchronously in callback order, before any await. TLS ciphertext
    // must never be reordered or partially discarded to relieve congestion.
    public Task ReceiveFragmentAsync(byte[] bytes)
    {
        lock (fragmentGate)
        {
            try
            {
                var tasks = fragments.Receive(bytes).Select(part => { Interlocked.Add(ref receivedBytes, part.Length); return ReceiveAsync(part); }).ToArray();
                Progress();
                return Task.WhenAll(tasks);
            }
            catch (Exception error) { status("BLEFragmentRejected " + error.Message); Dispose(); return Task.FromException(error); }
        }
    }
    public Task ReceiveAsync(byte[] bytes)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (Volatile.Read(ref closed) != 0)
            return Task.FromException(new IOException("BLE bridge closed."));
        var total = Interlocked.Add(ref queuedBytes, bytes.Length);
        if (total > 262144 || !received.Writer.TryWrite(new(bytes, completion)))
        {
            Interlocked.Add(ref queuedBytes, -bytes.Length);
            Dispose();
            return Task.FromException(new IOException("BLE receive queue full."));
        }
        return completion.Task;
    }
    private async Task ReceivePump()
    {
        try
        {
            var client = await connected.Task.WaitAsync(lifetime.Token).ConfigureAwait(false);
            await foreach (var item in received.Reader.ReadAllAsync(lifetime.Token).ConfigureAwait(false))
            {
                try
                {
                    await client.GetStream().WriteAsync(item.Bytes, lifetime.Token).ConfigureAwait(false);
                    item.Completion.TrySetResult();
                }
                catch (Exception error) { item.Completion.TrySetException(error); throw; }
                finally { Interlocked.Add(ref queuedBytes, -item.Bytes.Length); }
            }
        }
        catch (Exception error) { status("BLEBridgeReceiveFailed error=" + error.GetType().Name + " code=" + error.HResult); Dispose(); }
        finally
        {
            while (received.Reader.TryRead(out var item))
            {
                Interlocked.Add(ref queuedBytes, -item.Bytes.Length);
                item.Completion.TrySetException(new IOException("BLE bridge closed."));
            }
        }
    }
    private async Task Pump()
    {
        try
        {
            var bytes = new byte[1024];
            var stream = connection!.GetStream();
            while (!lifetime.IsCancellationRequested)
            {
                var count = await stream.ReadAsync(bytes, lifetime.Token).ConfigureAwait(false);
                if (count == 0)
                    break;
                Interlocked.Add(ref forwardedBytes, count);
                Progress();
                await forward(bytes.AsSpan(0, count).ToArray()).WaitAsync(TimeSpan.FromSeconds(3), lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (Exception error) { status("BLEBridgeForwardFailed error=" + error.GetType().Name + " code=" + error.HResult + " detail=" + error.Message); }
        finally { Dispose(); }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0)
            return;
        status($"BLEBridgeClosed reordered={fragments.Reordered} rxBytes={receivedBytes} txBytes={forwardedBytes} nextExpected={fragments.NextExpected} pending={fragments.PendingCount} duplicates={fragments.Duplicates}");
        received.Writer.TryComplete();
        lifetime.Cancel();
        listener?.Stop();
        connection?.Dispose();
        connected.TrySetCanceled();
        ended();
    }
    private void Progress()
    {
        var now = Environment.TickCount64;
        var previous = Interlocked.Read(ref lastProgress);
        if (now - previous < 5000 || Interlocked.CompareExchange(ref lastProgress, now, previous) != previous)
            return;
        status($"BLEBridgeProgress rxBytes={Interlocked.Read(ref receivedBytes)} txBytes={Interlocked.Read(ref forwardedBytes)} nextExpected={fragments.NextExpected} pending={fragments.PendingCount} duplicates={fragments.Duplicates}");
    }
}
