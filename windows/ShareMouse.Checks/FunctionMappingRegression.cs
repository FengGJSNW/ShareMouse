using System.Text.Json;
using ShareMouse.Core;

internal static class FunctionMappingRegression
{
    public static void Run()
    {
        string[] targets = ["BrightnessDown", "BrightnessUp", "MissionControl", "Spotlight", "Dictation", "DoNotDisturb", "MediaRewind", "MediaPlayPause", "MediaFastForward", "VolumeMute", "VolumeDown", "VolumeUp"];
        for (var number = 1; number <= 12; number++)
        {
            var slot = "F" + number;
            var source = KeyboardMapping.WindowsFunction(slot)!;
            Equal(KeyboardMapping.Map(source, "windows", "macos", null, functionSlot: slot), targets[number - 1]);
            Equal(KeyboardMapping.Map(source, "windows", "macos", null, fnEnabled: false, functionSlot: slot), slot);
            Equal(KeyboardMapping.Map(source, "windows", "macos", null, functionKeysEnabled: false, functionSlot: slot), slot);
            Equal(KeyboardMapping.Map(slot, "windows", "macos", null), slot);
        }
        Equal(KeyboardMapping.Map("VolumeMute", "windows", "macos", null), "VolumeMute");
        Equal(KeyboardMapping.Map("VolumeMute", "windows", "macos", null, functionSlot: "invalid"), "VolumeMute");
        var custom = new KeyboardConfig(Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D"), "Fixture", new()
        {
            ["F3"] = "KeyA"
        }, new());
        Equal(KeyboardMapping.Map("KeyboardBrightnessUp", "windows", "macos", custom, functionSlot: "F3"), "KeyA");
        custom.WindowsToMac["KeyboardBrightnessUp"] = KeyboardMapping.NoAction;
        Equal(KeyboardMapping.Map("KeyboardBrightnessUp", "windows", "macos", custom, functionSlot: "F3"), KeyboardMapping.NoAction);
        var held = new InputPacket { Type = "held", GroupID = "fixture", SourcePeerID = "windows", TargetPeerID = "macos", Keys = ["Fn", "VolumeMute"], FunctionSlots = new() { ["VolumeMute"] = "F1" } };
        var decoded = JsonSerializer.Deserialize<InputPacket>(JsonSerializer.Serialize(held))!;
        Equal(decoded.FunctionSlots!["VolumeMute"], "F1");
        if (JsonSerializer.Deserialize<InputPacket>("{\"Type\":\"held\",\"GroupID\":\"fixture\",\"SourcePeerID\":\"windows\",\"TargetPeerID\":\"macos\"}")!.FunctionSlots is not null)
            throw new Exception("Legacy packets must retain absent slot metadata.");
        Console.WriteLine("PASS: all 12 Windows function slots, plain F keys, switches, custom precedence, dedicated media, and packet compatibility.");
    }

    private static void Equal(string actual, string expected)
    {
        if (actual != expected)
            throw new Exception($"Expected {expected}; got {actual}.");
    }
}
