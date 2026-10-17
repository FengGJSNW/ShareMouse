namespace ShareMouse.Core;

public sealed record GroupMember(string PeerID, string Name, string PublicKey, ulong JoinOrder, string? Host, int Port);
public sealed record ScreenGeometry(string Id, string PeerID, string Name, int Number, int PixelWidth, int PixelHeight,
    bool Primary, double X, double Y, double Scale = 1, double? ScaleX = null, double? ScaleY = null, int? Rotation = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public double Width => BaseWidth * (ScaleX ?? Scale);
    [System.Text.Json.Serialization.JsonIgnore]
    public double Height => BaseHeight * (ScaleY ?? Scale);
    [System.Text.Json.Serialization.JsonIgnore] public int Angle => Rotation ?? 0;
    [System.Text.Json.Serialization.JsonIgnore] public double BaseWidth => Angle is 90 or 270 ? PixelHeight : PixelWidth;
    [System.Text.Json.Serialization.JsonIgnore] public double BaseHeight => Angle is 90 or 270 ? PixelWidth : PixelHeight;
    public ScreenGeometry SetSize(double width, double height) => this with { ScaleX = width / BaseWidth, ScaleY = height / BaseHeight };
    public (double X, double Y) Logical(double u, double v) => Angle switch { 90 => (1 - v, u), 180 => (1 - u, 1 - v), 270 => (v, 1 - u), _ => (u, v) };
    public (double X, double Y) Native(double u, double v) => Angle switch { 90 => (v, 1 - u), 180 => (1 - u, 1 - v), 270 => (1 - v, u), _ => (u, v) };
    public (double X, double Y) Delta(double dx, double dy)
    {
        var value = Angle switch
        {
            90 => (-dy, dx),
            180 => (-dx, -dy),
            270 => (dy, -dx),
            _ => (dx, dy)
        };
        return (value.Item1 * (ScaleX ?? Scale), value.Item2 * (ScaleY ?? Scale));
    }
    public static ScreenGeometry Resize(ScreenGeometry screen, double dx, double dy, string edge, bool proportional, ScreenGeometry[] others, double tolerance = 0)
    {
        var left = screen.X;
        var right = left + screen.Width;
        var top = screen.Y;
        var bottom = top + screen.Height;
        if (edge.Contains('w'))
            left = Math.Min(right - 1, left + dx);
        if (edge.Contains('e'))
            right = Math.Max(left + 1, right + dx);
        if (edge.Contains('n'))
            top = Math.Min(bottom - 1, top + dy);
        if (edge.Contains('s'))
            bottom = Math.Max(top + 1, bottom + dy);
        if (proportional)
        {
            var factor = edge is "n" or "s" ? (bottom - top) / screen.Height : (right - left) / screen.Width;
            if (tolerance > 0)
            {
                var candidates = new List<(double Distance, double Factor)>();
                foreach (var other in others.Where(s => s.Id != screen.Id))
                {
                    foreach (var target in new[] { other.X, other.X + other.Width })
                    {
                        if (edge.Contains('w'))
                            candidates.Add((Math.Abs(screen.X + screen.Width - screen.Width * factor - target), (screen.X + screen.Width - target) / screen.Width));
                        if (edge.Contains('e'))
                            candidates.Add((Math.Abs(screen.X + screen.Width * factor - target), (target - screen.X) / screen.Width));
                    }
                    foreach (var target in new[] { other.Y, other.Y + other.Height })
                    {
                        if (edge.Contains('n'))
                            candidates.Add((Math.Abs(screen.Y + screen.Height - screen.Height * factor - target), (screen.Y + screen.Height - target) / screen.Height));
                        if (edge.Contains('s'))
                            candidates.Add((Math.Abs(screen.Y + screen.Height * factor - target), (target - screen.Y) / screen.Height));
                    }
                }
                var snaps = candidates.Where(c => c.Distance < tolerance && c.Factor * Math.Min(screen.Width, screen.Height) >= 1).OrderBy(c => c.Distance).ToArray();
                if (snaps.Length > 0)
                    factor = snaps[0].Factor;
            }
            if (edge.Contains('w'))
                left = right - screen.Width * factor;
            else
                right = left + screen.Width * factor;
            if (edge.Contains('n'))
                top = bottom - screen.Height * factor;
            else
                bottom = top + screen.Height * factor;
        }
        else if (tolerance > 0)
        {
            double Nearest(double value, double[] targets) => targets.Where(t => Math.Abs(t - value) < tolerance).OrderBy(t => Math.Abs(t - value)).Select(t => (double?)t).FirstOrDefault() ?? value;
            var rest = others.Where(s => s.Id != screen.Id).ToArray();
            var xs = rest.SelectMany(s => new[] { s.X, s.X + s.Width }).ToArray();
            var ys = rest.SelectMany(s => new[] { s.Y, s.Y + s.Height }).ToArray();
            if (edge.Contains('w'))
                left = Nearest(left, xs);
            if (edge.Contains('e'))
                right = Nearest(right, xs);
            if (edge.Contains('n'))
                top = Nearest(top, ys);
            if (edge.Contains('s'))
                bottom = Nearest(bottom, ys);
        }
        return (screen with
        {
            X = left,
            Y = top
        }).SetSize(Math.Max(1, right - left), Math.Max(1, bottom - top));
    }
    public static ScreenGeometry[]? NativeLayout(ScreenGeometry[] logical, Dictionary<string, (double Width, double Height)> sizes)
    {
        if (!ValidLayout(logical) || logical.Select(s => s.PeerID).Distinct().Count() != 1 || logical.Any(s => !sizes.TryGetValue(s.Id, out var size) || !double.IsFinite(size.Width) || !double.IsFinite(size.Height) || size.Width is < 1 or > 32768 || size.Height is < 1 or > 32768))
            return null;
        var root = logical.FirstOrDefault(s => s.Primary) ?? logical[0];
        ScreenGeometry Native(ScreenGeometry screen, double x, double y) => new(screen.Id, screen.PeerID, screen.Name, screen.Number, (int)Math.Round(sizes[screen.Id].Width, MidpointRounding.AwayFromZero), (int)Math.Round(sizes[screen.Id].Height, MidpointRounding.AwayFromZero), screen.Primary, Math.Round(x, MidpointRounding.AwayFromZero), Math.Round(y, MidpointRounding.AwayFromZero));
        var result = new Dictionary<string, ScreenGeometry> { [root.Id] = Native(root, 0, 0) };
        var pending = new Queue<ScreenGeometry>();
        pending.Enqueue(root);
        while (pending.TryDequeue(out var current))
        {
            var placed = result[current.Id];
            foreach (var next in logical.Where(s => !result.ContainsKey(s.Id) && Touches(current, s)))
            {
                var x = placed.X + (next.X - current.X) / current.Width * placed.Width;
                var y = placed.Y + (next.Y - current.Y) / current.Height * placed.Height;
                if (Math.Abs(current.X + current.Width - next.X) < .01)
                    x = placed.X + placed.Width;
                else if (Math.Abs(next.X + next.Width - current.X) < .01)
                    x = placed.X - sizes[next.Id].Width;
                else if (Math.Abs(current.Y + current.Height - next.Y) < .01)
                    y = placed.Y + placed.Height;
                else
                    y = placed.Y - sizes[next.Id].Height;
                result[next.Id] = Native(next, x, y);
                pending.Enqueue(next);
            }
        }
        var values = logical.Where(s => result.ContainsKey(s.Id)).Select(s => result[s.Id]).ToArray();
        return values.Length == logical.Length && ValidLayout(values) ? values : null;
    }
    public static bool Touches(ScreenGeometry a, ScreenGeometry b)
    {
        var horizontal = Math.Abs(a.X + a.Width - b.X) < .01 || Math.Abs(b.X + b.Width - a.X) < .01;
        var vertical = Math.Abs(a.Y + a.Height - b.Y) < .01 || Math.Abs(b.Y + b.Height - a.Y) < .01;
        return horizontal && Math.Min(a.Y + a.Height, b.Y + b.Height) > Math.Max(a.Y, b.Y)
            || vertical && Math.Min(a.X + a.Width, b.X + b.Width) > Math.Max(a.X, b.X);
    }
    public static ScreenGeometry Snap(ScreenGeometry screen, ScreenGeometry[] others, double tolerance)
    {
        var x = screen.X;
        var y = screen.Y;
        var bestX = tolerance;
        var bestY = tolerance;
        foreach (var other in others.Where(s => s.Id != screen.Id))
        {
            foreach (var candidate in new[] { other.X + other.Width, other.X - screen.Width, other.X, other.X + other.Width - screen.Width })
                if (Math.Abs(candidate - screen.X) < bestX)
                {
                    bestX = Math.Abs(candidate - screen.X);
                    x = candidate;
                }
            foreach (var candidate in new[] { other.Y + other.Height, other.Y - screen.Height, other.Y, other.Y + other.Height - screen.Height })
                if (Math.Abs(candidate - screen.Y) < bestY)
                {
                    bestY = Math.Abs(candidate - screen.Y);
                    y = candidate;
                }
        }
        return screen with
        {
            X = x,
            Y = y
        };
    }
    public static bool ValidLayout(ScreenGeometry[] screens)
    {
        if (screens.Length == 0 || screens.Select(s => s.Id).Distinct().Count() != screens.Length
            || screens.Any(s => !double.IsFinite(s.X) || !double.IsFinite(s.Y) || !double.IsFinite(s.Scale)
                || s.Scale <= 0 || !double.IsFinite(s.ScaleX ?? s.Scale) || (s.ScaleX ?? s.Scale) <= 0 || !double.IsFinite(s.ScaleY ?? s.Scale) || (s.ScaleY ?? s.Scale) <= 0 || s.Angle is not (0 or 90 or 180 or 270) || s.PixelWidth <= 0 || s.PixelHeight <= 0 || !double.IsFinite(s.Width) || !double.IsFinite(s.Height) || s.Width < 1 || s.Height < 1))
            return false;
        var connected = new HashSet<int> { 0 };
        var pending = new Stack<int>();
        pending.Push(0);
        while (pending.TryPop(out var index))
            for (var other = 0; other < screens.Length; other++)
                if (!connected.Contains(other) && Touches(screens[index], screens[other]))
                {
                    connected.Add(other);
                    pending.Push(other);
                }
        for (var a = 0; a < screens.Length; a++)
            for (var b = a + 1; b < screens.Length; b++)
                if (Math.Min(screens[a].X + screens[a].Width, screens[b].X + screens[b].Width) - Math.Max(screens[a].X, screens[b].X) > .01
                    && Math.Min(screens[a].Y + screens[a].Height, screens[b].Y + screens[b].Height) - Math.Max(screens[a].Y, screens[b].Y) > .01)
                    return false;
        if (connected.Count != screens.Length)
            return false;
        return screens.Select(s => s.PeerID).Distinct().Count() == 1 || screens.GroupBy(s => s.PeerID).All(group => ValidLayout(group.ToArray()));
    }
}
public sealed record KeyboardConfig(string Id, string OwnerPeerID, string Name,
    Dictionary<string, string> WindowsToMac, Dictionary<string, string> MacToWindows, ulong? Revision = null, long? Modified = null);
public sealed record SharedGroup(string Id, string Name, string LeaderID, ulong Revision, GroupMember[] Members,
    ScreenGeometry[] Layout, KeyboardConfig[] Configs, string CurrentConfigID);
public sealed record GroupEditLock(string Resource, string OwnerPeerID, string Token, ulong BaseRevision);
public sealed record GroupStore(SharedGroup[] Groups, string? ActiveGroupID);
public sealed class GroupPacket
{
    public required string Type
    {
        get; set;
    }
    public string? GroupID
    {
        get; set;
    }
    public string? RequestID
    {
        get; set;
    }
    public SharedGroup? State
    {
        get; set;
    }
    public GroupMember? Member
    {
        get; set;
    }
    public ScreenGeometry[]? Screens
    {
        get; set;
    }
    public GroupEditLock[]? Locks
    {
        get; set;
    }
    public GroupEditLock? EditLock
    {
        get; set;
    }
    public string? Resource
    {
        get; set;
    }
    public bool? Approved
    {
        get; set;
    }
    public string? Error
    {
        get; set;
    }
    public string? LeaderID
    {
        get; set;
    }
    public string? TargetPeerID
    {
        get; set;
    }
    public KeyboardConfig[]? Configs
    {
        get; set;
    }
    public string? CurrentConfigID
    {
        get; set;
    }
}
