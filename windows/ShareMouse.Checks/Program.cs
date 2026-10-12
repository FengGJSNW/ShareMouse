using ShareMouse.Core;

if(args.Contains("--ble")) {await BleRegression.Run();return;}

if (args.Contains("--mapping")) {
    if (KeyboardMapping.Map("ControlLeft","windows","macos",null)!="MetaLeft" || KeyboardMapping.Map("MetaRight","macos","windows",null)!="ControlRight") throw new Exception("Default modifier mapping failed.");
    var owner=Guid.NewGuid().ToString("D"); var config=new KeyboardConfig(Guid.NewGuid().ToString("D"),owner,"Custom",new(){{"ControlLeft","AltLeft"}},new());
    if (KeyboardMapping.Map("ControlLeft","windows","macos",config)!="AltLeft" || KeyboardMapping.Map("ControlLeft","windows","windows",config)!="ControlLeft") throw new Exception("Custom or same-system mapping failed.");
    if (KeyboardMapping.Command("KeyC",["ControlLeft","KeyC"],"windows","macos",null)!="copy" || KeyboardMapping.Command("KeyC",["ControlLeft","KeyC"],"windows","macos",config) is not null) throw new Exception("Command ignored user mapping.");
    if(KeyboardMapping.Command("KeyZ",["ControlLeft","ShiftRight","KeyZ"],"windows","macos",null)!="redo" || KeyboardMapping.Command("KeyZ",["MetaLeft","KeyZ"],"macos","windows",null)!="undo" || KeyboardMapping.Command("KeyZ",["ControlLeft","KeyZ"],"windows","macos",config) is not null) throw new Exception("Undo/Redo ignored mapping or shift.");
    var html="<p>中文😀 <b>formatted</b></p>"; if(HtmlClipboard.Decode(HtmlClipboard.Encode(html))!=html) throw new Exception("CF_HTML Unicode offsets corrupted the fragment.");
    Console.WriteLine("PASS: directional modifiers, user precedence, same-system keys, and semantic commands."); return;
}
if (args.Contains("--pointer")) {
    var a=new ScreenGeometry("a","one","A",1,1000,720,true,0,0);
    var b=new ScreenGeometry("b","two","B",2,2000,1440,true,1000,360);
    var outside=new PointerState("a",999,100,"one",1);
    if (PointerRouter.Move(outside,[a,b],20,0).ScreenID!="a") throw new Exception("Crossed a non-contact edge.");
    if (Math.Abs(PointerRouter.Move(outside,[a,b],20,200).Y-300)>.01) throw new Exception("Pointer stuck when sliding along a wall.");
    var inside=PointerRouter.Move(outside with { Y=500 },[a,b],20,0);
    if (inside.ScreenID!="b" || Math.Abs(inside.X-1019)>.01) throw new Exception("Contact crossing failed.");
    var scaled=a with { Scale=2 }; var aligned=b with { X=2000,Y=0 };
    var result=PointerRouter.Move(new("a",1999,1080,"one",1),[scaled,aligned],10,0);
    if (result.ScreenID!="b" || Math.Abs((result.Y-aligned.Y)/aligned.Height-.75)>.001) throw new Exception("Scale correspondence failed.");
    Console.WriteLine("PASS: only contact segments cross; logical Scale controls correspondence."); return;
}

var directory = Path.Combine(Path.GetTempPath(), "ShareMouse.Checks-" + Guid.NewGuid().ToString("N"));
try
{
    var store = new PeerIdentityStore(directory);
    var original = store.LoadOrCreate();
    if (original != new PeerIdentityStore(directory).LoadOrCreate())
        throw new Exception("PeerId changed after restart.");

    var file = Path.Combine(directory, "peer-id");
    File.WriteAllText(file, "invalid");
    try { store.LoadOrCreate(); throw new Exception("Invalid identity was accepted."); }
    catch (InvalidDataException) { }
    if (File.ReadAllText(file) != "invalid")
        throw new Exception("Invalid identity was overwritten.");
    Console.WriteLine("PASS: restart preserves PeerId; corrupt storage is preserved and rejected.");
}
finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
