using System.Collections.Concurrent;

// Serial execution for protocol fixtures. This is not a desktop input adapter.
sealed class FixtureInputContext : SynchronizationContext, IDisposable
{
    private readonly BlockingCollection<Action> actions = new();
    private readonly Thread thread;
    private volatile bool disposed;
    public FixtureInputContext()
    {
        thread = new(() => { SetSynchronizationContext(this); foreach (var action in actions.GetConsumingEnumerable()) action(); })
        {
            IsBackground = true,
            Name = "Input protocol fixture"
        };
        thread.Start();
    }
    public override void Post(SendOrPostCallback callback, object? state)
    {
        if (disposed)
            return;
        try
        {
            actions.Add(() => callback(state));
        }
        catch (InvalidOperationException) { }
    }
    public T Invoke<T>(Func<T> action)
    {
        if (Thread.CurrentThread == thread)
            return action();
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(_ => { try { result.SetResult(action()); } catch (Exception error) { result.SetException(error); } }, null);
        return result.Task.GetAwaiter().GetResult();
    }
    public void Dispose()
    {
        disposed = true;
        actions.CompleteAdding();
        thread.Join();
        actions.Dispose();
    }
}
