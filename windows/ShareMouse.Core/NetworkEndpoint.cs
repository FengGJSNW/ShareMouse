using System.Net;
using System.Net.Sockets;

namespace ShareMouse.Core;

public sealed record NetworkEndpoint(string Host, int Port)
{
    public bool Valid(bool allowLoopback = false)
    {
        if (Port is < 1 or > 65535 || !IPAddress.TryParse(Host, out var address) || address.AddressFamily != AddressFamily.InterNetwork)
            return false;
        var bytes = address.GetAddressBytes();
        return bytes[0] is > 0 and < 224 && (allowLoopback || bytes[0] != 127)
            && !(bytes[0] == 169 && bytes[1] == 254) && !(bytes[0] == 198 && bytes[1] is 18 or 19);
    }
}
