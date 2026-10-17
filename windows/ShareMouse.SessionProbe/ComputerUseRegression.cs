using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;
using ShareMouse.Core;
using ShareMouse.Network;

static class ComputerUseRegression
{
    public static async Task Run()
    {
        var id = Guid.NewGuid().ToString("D");
        var directory = Path.Combine(Path.GetTempPath(), "ShareMouse-ComputerUse-" + id);
        Directory.CreateDirectory(directory);
        try
        {
            using var identity = new IdentityStore(id);
            await using var manager = new SessionManager(id, "LeaseTest", identity, new PeerRegistry(directory), "123456", "", _ => true, _ => true, _ => { });
            var context = new SynchronizationContext();
            using var clipboard = new ClipboardService(id, manager, context, _ => { });
            var screen = new ScreenGeometry(id + ":test", id, "Fixture", 1, 1000, 720, true, 0, 0);
            var clock = DateTime.UtcNow;
            var injected = 0;
            var lastKey = "";
            var restored = false;
            var changes = new List<string>();
            using var service = new ComputerUseService(id, "LeaseTest", manager, null, clipboard, context, () => [screen], () => new JsonObject(), _ => Task.FromResult(ComputerUseService.Obj(("width", 1000), ("height", 720))), (value, _, _, _) => { injected++; if (value.Key is not null) lastKey = value.Key; }, () => true, value => restored = value, () => true, utcNow: () => clock, diagnostic: Console.WriteLine, controlChanged: (active, reason) => changes.Add(active ? "opened" : reason), inputState: () => ComputerUseService.Obj(("foreground_integrity", "high"), ("input_injection_blocked", false)));
            service.AllowComputer = true;
            var opened = await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local")));
            Require(opened["control_session_idle_timeout_ms"]!.GetValue<int>() == 600000, "Wrong lease duration");
            var args = ComputerUseService.Obj(("peer_id", "local"), ("control_session_id", opened["control_session_id"]), ("observation_id", opened["observation_id"]));
            args["actions"] = new JsonArray(ComputerUseService.Obj(("type", "move"), ("x", 10), ("y", 10)), ComputerUseService.Obj(("type", "wait"), ("milliseconds", 30000)), ComputerUseService.Obj(("type", "wait"), ("milliseconds", 30000)));
            await Reject("batch_wait_exceeds_30000_ms", () => service.Tool("computer_action", args));
            Require(injected == 0, "Rejected batch injected input");
            foreach (var e in new CapturedInput[] { new("move", DeltaX: 50, DeltaY: 50), new("buttonDown", Button: 0), new("buttonUp", Button: 0), new("scroll", DeltaY: 40), new("keyDown", "Escape"), new("keyUp", "Escape") })
            {
                Require(service.PhysicalInput(e), "Local input must bypass sharing handlers");
                Require(service.Controlling, "Accidental local input ended MCP");
            }
            clock = clock.AddSeconds(134);
            args["actions"] = new JsonArray(ComputerUseService.Obj(("type", "move"), ("x", 10), ("y", 10)));
            var done = await service.Tool("computer_action", args);
            Require(done["execution_status"]!.GetValue<string>() == "injected" && injected == 1, "Slow reasoning expired lease");
            Require(!done["observation"]!["input_state"]!["input_injection_blocked"]!.GetValue<bool>(), "Input diagnostics missing from observation");
            args["observation_id"] = done["observation"]!["observation_id"]!.DeepClone();
            args["actions"] = new JsonArray(ComputerUseService.Obj(("type", "keypress"), ("keys", new JsonArray("ENTER"))));
            var entered = await service.Tool("computer_action", args);
            Require(lastKey == "Enter" && entered["execution_status"]!.GetValue<string>() == "injected", "ENTER alias was rejected");
            clock = clock.AddSeconds(601);
            await Reject("control_session_unavailable:lease_expired", () => service.Tool("observe_computer", args));
            Require(restored && !service.Controlling, "Expired lease did not release control");
            opened = await service.Tool("open_computer", ComputerUseService.Obj(("peer_id", "local")));
            args["control_session_id"] = opened["control_session_id"]!.DeepClone();
            service.EndControl("user_exit");
            await Reject("control_session_unavailable:user_exit", () => service.Tool("observe_computer", args));
            Require(changes.SequenceEqual(new[] { "opened", "lease_expired", "opened", "user_exit" }), "Wrong control notification lifecycle");
            Console.WriteLine("ComputerUse regression passed: 134s idle, whole-batch wait validation, 10min expiry, local input tolerance, explicit exit and notification lifecycle.");
        }
        finally
        {
            using (var store = new X509Store(StoreName.My, StoreLocation.CurrentUser))
            {
                store.Open(OpenFlags.ReadWrite);
                foreach (var certificate in store.Certificates.Where(c => c.Subject == "CN=ShareMouse-" + id))
                    store.Remove(certificate);
            }
            if (CngKey.Exists("ShareMouse-" + id))
            {
                using var key = CngKey.Open("ShareMouse-" + id);
                key.Delete();
            }
            Directory.Delete(directory, true);
        }
    }
    private static void Require(bool value, string message)
    {
        if (!value)
            throw new Exception(message);
    }
    private static async Task Reject(string reason, Func<Task<JsonNode>> action)
    {
        try
        {
            await action();
        }
        catch (IOException e) when (e.Message == reason) { return; }
        throw new Exception("Expected rejection: " + reason);
    }
}
