namespace ShareMouse.Core;

public sealed class PeerIdentityStore(string directory)
{
    public PeerId LoadOrCreate()
    {
        var file = Path.Combine(directory, "peer-id");
        if (File.Exists(file))
        {
            var text = File.ReadAllText(file).Trim();
            if (!Guid.TryParseExact(text, "D", out var value))
                throw new InvalidDataException("Stored PeerId is invalid; it has been preserved.");
            return new PeerId(value);
        }

        Directory.CreateDirectory(directory);
        var id = PeerId.Create();
        // Rename a completed write so an interrupted write never becomes a partial identity.
        var temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, id.Value.ToString("D"));
            File.Move(temporary, file, overwrite: false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return id;
    }
}
