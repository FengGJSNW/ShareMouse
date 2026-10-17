namespace ShareMouse.Core;

public readonly record struct PeerId(Guid Value)
{
    public static PeerId Create() => new(Guid.NewGuid());
}

public readonly record struct GroupId(Guid Value)
{
    public static GroupId Create() => new(Guid.NewGuid());
}

public readonly record struct SessionId(Guid Value)
{
    public static SessionId Create() => new(Guid.NewGuid());
}

public enum PeerPlatform
{
    Windows, MacOS
}

public enum Capability
{
    Keyboard, Pointer, Scroll, TextClipboard, FileTransfer,
    Tcp, Udp, Ble, BluetoothClassic
}

public sealed record Peer(PeerId Id, string Name, PeerPlatform Platform, IReadOnlySet<Capability> Capabilities);
