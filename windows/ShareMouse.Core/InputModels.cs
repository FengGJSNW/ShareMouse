namespace ShareMouse.Core;

public sealed record PointerState(string ScreenID, double X, double Y, string OwnerPeerID, ulong Epoch);
public sealed class InputPacket {
    public required string Type { get; set; }
    public required string GroupID { get; set; }
    public required string SourcePeerID { get; set; }
    public required string TargetPeerID { get; set; }
    public string? TargetScreenID { get; set; }
    public ulong Sequence { get; set; }
    public ulong? AcknowledgedSequence { get; set; }
    public PointerState? Pointer { get; set; }
    public string? Key { get; set; }
    public string? Command { get; set; }
    public string? ClipboardEntryID { get; set; }
    public string? Text { get; set; }
    public int? ScrollPhase { get; set; }
    public int? MomentumPhase { get; set; }
    public bool? PreciseScroll { get; set; }
    public string? SourcePlatform { get; set; }
    public int Button { get; set; }
    public double DeltaX { get; set; }
    public double DeltaY { get; set; }
    public string[]? Keys { get; set; }
    public int[]? Buttons { get; set; }
    public string[]? Priority { get; set; }
}
public sealed record CapturedInput(string Type, string? Key = null, int Button = 0, double DeltaX = 0, double DeltaY = 0,
    string? ScreenID = null, double X = 0, double Y = 0, string? Command = null, string? Text = null, int? ScrollPhase = null, int? MomentumPhase = null, bool? PreciseScroll = null, bool? HardwareMotion = null);

public static class PointerRouter {
    public static PointerState Center(ScreenGeometry screen, string owner, ulong epoch) =>
        new(screen.Id, screen.X + screen.Width / 2, screen.Y + screen.Height / 2, owner, epoch);
    public static PointerState Move(PointerState pointer, ScreenGeometry[] screens, double dx, double dy) {
        if (!double.IsFinite(dx) || !double.IsFinite(dy)) return pointer;
        var x = pointer.X; var y = pointer.Y;
        var screen = screens.FirstOrDefault(s => s.Id == pointer.ScreenID);
        if (screen is null) return pointer;
        for (var step = 0; step < screens.Length + 1; step++) {
            var tx = dx > 0 ? (screen.X + screen.Width - x) / dx : dx < 0 ? (screen.X - x) / dx : double.PositiveInfinity;
            var ty = dy > 0 ? (screen.Y + screen.Height - y) / dy : dy < 0 ? (screen.Y - y) / dy : double.PositiveInfinity;
            var t = Math.Clamp(Math.Min(tx, ty), 0, 1); x += dx * t; y += dy * t;
            if (t >= 1) break;
            var probeX = x + Math.Sign(dx) * .001; var probeY = y + Math.Sign(dy) * .001;
            var next = screens.FirstOrDefault(s => s.Id != screen.Id && ScreenGeometry.Touches(screen, s)
                && probeX >= s.X && probeX < s.X + s.Width && probeY >= s.Y && probeY < s.Y + s.Height);
            if (next is null) {
                if (tx <= ty) { x = Math.Clamp(x, screen.X, screen.X + screen.Width - .001); dx = 0; } else dx *= 1 - t;
                if (ty <= tx) { y = Math.Clamp(y, screen.Y, screen.Y + screen.Height - .001); dy = 0; } else dy *= 1 - t;
                if (dx == 0 && dy == 0) break; else continue;
            }
            screen = next; dx *= 1 - t; dy *= 1 - t;
        }
        return pointer with { ScreenID = screen.Id, X = x, Y = y };
    }
}
