using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using ShareMouse.Core;
using ShareMouse.Network;

static class SharingRegression {
    public static async Task CheckInputStall() {
        await using var a=new Fixture("SlowInputA");await using var b=new Fixture("SlowInputB");
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Active is not null&&a.Group.Active.Id==b.Group.Active?.Id);
        await b.Manager.SetCapabilitiesAsync(new Dictionary<string,bool>{{"input",true},{"compact-input",true}});
        using var context=new FixtureInputContext();var group=a.Group.Active!;
        var packets=new ConcurrentQueue<InputPacket>();var events=new ConcurrentQueue<string>();
        b.Manager.Receive("input",(peer,bytes)=>{var packet=MotionCodec.Decode(bytes,group,peer,b.Id)??JsonSerializer.Deserialize<InputPacket>(bytes,json);if(packet is not null)packets.Enqueue(packet);return Task.CompletedTask;});
        var input=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{},events.Enqueue));
        try {
            context.Invoke(()=>{input.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());return 0;});await context.Invoke(()=>input.Enable());
            await Wait(()=>context.Invoke(()=>{var sessions=a.Manager.CurrentSessions();input.Update(group,[a.Id,b.Id],sessions);return sessions.Any(s=>s.Capabilities.Contains("compact-input"));}));
            var local=group.Layout.Single(s=>s.PeerID==a.Id);var remote=group.Layout.Single(s=>s.PeerID==b.Id);var dx=remote.X>local.X?8:-8;
            context.Invoke(()=>input.Capture(new("move",DeltaX:dx,ScreenID:local.Id,X:dx>0?1:0,Y:.5)));
            for(var n=0;n<60;n++){context.Invoke(()=>input.Capture(new("move",DeltaX:Math.Sign(dx))));await Task.Delay(2);}
            await Wait(()=>packets.Count(p=>p.Type=="move")==8);
            var remoteScreen=context.Invoke(()=>input.Pointer?.ScreenID);
            var ack=new InputPacket{Type="motionAck",GroupID=group.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,AcknowledgedSequence=0};
            await b.Manager.SendAsync(a.Id,"input",MotionCodec.Encode(ack,group.Layout)!);
            await Task.Delay(3500);
            Require(context.Invoke(()=>input.Enabled&&input.Pointer?.ScreenID==remoteScreen&&remoteScreen==remote.Id),"Native input delay caused a false recovery");
            Require(packets.Count(p=>p.Type=="move")==8,"Stalled input bypassed the credit limit");
            Require(events.Any(e=>e.Contains("InputDeliveryWaiting"))&&!events.Any(e=>e.Contains("InputRecovered")),"Missing wait diagnostic or unexpected recovery");
            ack.AcknowledgedSequence=packets.Last(p=>p.Type=="move").Sequence;
            await b.Manager.SendAsync(a.Id,"input",MotionCodec.Encode(ack,group.Layout)!);
            await Wait(()=>events.Any(e=>e.Contains("InputDeliveryResumed")));
            context.Invoke(()=>input.Capture(new("move",DeltaX:Math.Sign(dx))));
            await Wait(()=>packets.Count(p=>p.Type=="move")>8);
            b.Manager.Disconnect(a.Id);await Wait(()=>!a.Manager.InputSessionAlive(b.Id));
            await Wait(()=>context.Invoke(()=>input.Pointer?.ScreenID==local.Id));
            Console.WriteLine("PASS: delayed ACK keeps the authenticated session, credit stays bounded, real ACK resumes, lost link recovers locally.");
        }finally{context.Invoke(()=>{input.Dispose();return 0;});}
        var unpumped=new UnpumpedContext();
        using var waiting=new InputService(a.Id,"windows",a.Manager,unpumped,(_,_,_,_)=>{},(_,_)=>{},_=>{});
        await Task.Delay(450);
        Require(Volatile.Read(ref unpumped.Posted)==1,"Blocked UI accumulated watchdog callbacks");
    }

    public static async Task CheckCompactOwnership() {
        foreach(var platform in new[]{"macos","windows"}) {
            await using var a=new Fixture("OldController");await using var b=new Fixture("NewController");
            a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Active is not null&&a.Group.Active.Id==b.Group.Active?.Id);
            using var context=new FixtureInputContext();var group=a.Group.Active!;var screen=group.Layout.Single(s=>s.PeerID==b.Id);var events=new List<CapturedInput>();var acks=new List<ulong>();
            a.Manager.Receive("input",(peer,bytes)=>{var packet=MotionCodec.Decode(bytes,group,peer,a.Id)??JsonSerializer.Deserialize<InputPacket>(bytes,json);if(packet?.AcknowledgedSequence is {} ack)context.Invoke(()=>{acks.Add(ack);return 0;});return Task.CompletedTask;});
            await a.Manager.SetCapabilitiesAsync(new Dictionary<string,bool>{{"input",true},{"compact-input",true},{"compact-input-v3",true},{"compact-scroll-v1",true},{"scroll-flow-v1",true}});
            var target=context.Invoke(()=>new InputService(b.Id,platform,b.Manager,context,(e,_,_,_)=>events.Add(e),(_,_)=>{},_=>{}));
            try {
                context.Invoke(()=>{target.Update(group,[a.Id,b.Id],b.Manager.CurrentSessions());return 0;});await context.Invoke(()=>target.Enable());await Wait(()=>context.Invoke(()=>{var sessions=b.Manager.CurrentSessions();target.Update(group,[a.Id,b.Id],sessions);return sessions[0].Capabilities.Contains("input");}));
                var control=new InputPacket{Type="control",GroupID=group.Id,SourcePeerID=a.Id,TargetPeerID=b.Id,TargetScreenID=screen.Id,Sequence=10,Pointer=PointerRouter.Center(screen,a.Id,100)};
                await a.Manager.SendAsync(b.Id,"input",JsonSerializer.SerializeToUtf8Bytes(control,json));await Wait(()=>context.Invoke(()=>target.Pointer?.OwnerPeerID==a.Id));
                context.Invoke(()=>{target.Capture(new("move",DeltaX:10,ScreenID:screen.Id,X:.5,Y:.5));Require(target.Pointer?.OwnerPeerID==b.Id,"Local takeover did not occur");events.Clear();return 0;});
                var stale=new InputPacket{Type="scroll",GroupID=group.Id,SourcePeerID=a.Id,TargetPeerID=b.Id,TargetScreenID=screen.Id,Pointer=control.Pointer,Sequence=11,DeltaY=9,ScrollPhase=2};await a.Manager.SendAsync(b.Id,"input",MotionCodec.Encode(stale,group.Layout,compactContext:true)!);
                stale.Type="move";stale.Sequence=12;await a.Manager.SendAsync(b.Id,"input",MotionCodec.Encode(stale,group.Layout,compactContext:true)!);await Task.Delay(250);
                Require(context.Invoke(()=>acks.Any(s=>s>=12)&&!events.Any(e=>e.Type=="scroll")&&target.Pointer?.OwnerPeerID==b.Id),"Old ownership stranded credit or injected a stale gesture");
                control.Sequence=13;control.Pointer=PointerRouter.Center(screen,a.Id,102);await a.Manager.SendAsync(b.Id,"input",JsonSerializer.SerializeToUtf8Bytes(control,json));await Wait(()=>context.Invoke(()=>target.Pointer?.OwnerPeerID==a.Id));
                stale.Type="scroll";stale.Sequence=14;stale.Pointer=control.Pointer;stale.DeltaY=.25;await a.Manager.SendAsync(b.Id,"input",MotionCodec.Encode(stale,group.Layout,compactContext:true)!);await Wait(()=>context.Invoke(()=>events.Any(e=>e.Type=="scroll"&&e.DeltaY==.25)));
            }finally{context.Invoke(()=>{target.Dispose();return 0;});}
        }
        Console.WriteLine("PASS: both platform modes ACK old compact ownership without injecting stale scroll; fresh control resumes input.");
    }

    public static async Task CheckBLEScrollPressure() {
        await using var a=new Fixture("ScrollCreditsA",bluetoothInputOnly:true);await using var b=new Fixture("ScrollCreditsB",bluetoothInputOnly:true);
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Active is not null&&a.Group.Active.Id==b.Group.Active?.Id);
        var free=new TcpListener(IPAddress.Loopback,0);free.Start();var blePort=((IPEndPoint)free.LocalEndpoint).Port;free.Stop();b.Manager.StartBluetoothListener(blePort);await a.Manager.ConnectAsync("127.0.0.1",blePort,null,null,kind:"ble");
        var group=a.Group.Active!;using var context=new FixtureInputContext();PointerState? current=null;var events=new List<InputPacket>();var warnings=new List<string>();
        b.Manager.Receive("input",(peer,bytes)=> {
            var packet=context.Invoke(()=> {var p=MotionCodec.Decode(bytes,group,peer,b.Id,current)??JsonSerializer.Deserialize<InputPacket>(bytes,json);if(p is not null){if(p.Type is "control" or "pointer" or "move")current=p.Pointer;events.Add(p);}return p;});
            if(packet?.Type is "scroll" or "move")_=Task.Run(async()=>{await Task.Delay(100);var ack=new InputPacket{Type="motionAck",GroupID=group.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,AcknowledgedSequence=packet.Sequence};if(MotionCodec.Encode(ack,group.Layout,compactContext:true) is {} small)await b.Manager.SendAsync(a.Id,"input",small);});
            return Task.CompletedTask;
        });
        await b.Manager.SetCapabilitiesAsync(new Dictionary<string,bool>{{"input",true},{"compact-input",true},{"compact-input-v3",true},{"compact-scroll-v1",true},{"scroll-flow-v1",true},{"ble-input-v2",true}});
        var input=context.Invoke(()=>new InputService(a.Id,"macos",a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{},text=>warnings.Add(text)));
        try {
            context.Invoke(()=>{input.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());return 0;});await context.Invoke(()=>input.Enable());await Wait(()=>context.Invoke(()=>{var sessions=a.Manager.CurrentSessions();input.Update(group,[a.Id,b.Id],sessions);return sessions[0].Capabilities.Contains("scroll-flow-v1");}));
            var local=group.Layout.Single(s=>s.PeerID==a.Id);context.Invoke(()=>input.Capture(new("move",DeltaX:8,ScreenID:local.Id,X:1,Y:.5)));
            for(var i=0;i<300;i++){Require(context.Invoke(()=>input.Capture(new("scroll",DeltaX:.125,DeltaY:.25,ScrollPhase:2,MomentumPhase:0,PreciseScroll:true))),"Scroll capture fell through");context.Invoke(()=>input.Capture(new("move",DeltaX:.02)));await Task.Delay(1);}
            Require(context.Invoke(()=>!events.Any(e=>e.Type=="pointer")),"Interleaved input bypassed delivery credit with reliable pointer frames");
            context.Invoke(()=>{input.Capture(new("scroll",ScrollPhase:4,MomentumPhase:0,PreciseScroll:true));input.Capture(new("buttonDown"));input.Capture(new("buttonUp"));return 0;});
            await Wait(()=>context.Invoke(()=>events.Any(e=>e.Type=="buttonUp")));
            Require(context.Invoke(()=>Math.Abs(events.Where(e=>e.Type=="scroll").Sum(e=>e.DeltaY)-75)<.01&&Math.Abs(events.Where(e=>e.Type=="scroll").Sum(e=>e.DeltaX)-37.5)<.01),"Delayed ACK lost swipe displacement");
            Require(context.Invoke(()=>events.FindIndex(e=>e.Type=="scroll"&&e.ScrollPhase==4)<events.FindIndex(e=>e.Type=="buttonDown")&&input.Enabled&&!warnings.Any(w=>w.Contains("Congested")||w.Contains("AckStalled"))),"Scroll violated critical ordering or caused recovery");
            var result=await a.Manager.TestLatencyAsync(b.Id);Require(result.All(l=>l.Lost==0),"Compact diagnostic probe didn't round trip");
            Console.WriteLine("PASS: 100ms delayed BLE ACK retains swipe totals, boundary/click order and sharing; compact probes round trip on authenticated TLS.");
        }finally{context.Invoke(()=>{input.Dispose();return 0;});}
    }

    public static async Task CheckRelativeMotion() {
        foreach(var direction in new[]{("macos","windows"),("windows","macos")}) {
            await using var a=new Fixture("RelativeSource");await using var b=new Fixture("RelativeTarget");
            a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Active is not null&&a.Group.Active.Id==b.Group.Active?.Id);
            using var context=new FixtureInputContext();var delivered=new List<CapturedInput>();var captured=true;var started=false;var ended=false;var group=a.Group.Active!;
            var sa=context.Invoke(()=>new InputService(a.Id,direction.Item1,a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{},text=>{if(text.StartsWith("InputRelativeModeStarted"))started=true;if(text=="InputRelativeModeEnded")ended=true;}));
            var sb=context.Invoke(()=>new InputService(b.Id,direction.Item2,b.Manager,context,(e,_,_,_)=>delivered.Add(e),(_,_)=>{},_=>{}));
            try {
                context.Invoke(()=>{sb.RelativePointerCaptured=()=>captured;sa.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());sb.Update(group,[a.Id,b.Id],b.Manager.CurrentSessions());return 0;});
                await context.Invoke(async()=>{await sa.Enable();await sb.Enable();});
                await Wait(()=>context.Invoke(()=>{var x=a.Manager.CurrentSessions();var y=b.Manager.CurrentSessions();sa.Update(group,[a.Id,b.Id],x);sb.Update(group,[a.Id,b.Id],y);return x[0].Capabilities.Contains("relative-pointer-v1")&&y[0].Capabilities.Contains("relative-pointer-v1")&&x[0].Capabilities.Contains("input")&&y[0].Capabilities.Contains("input");}));
                var local=group.Layout.Single(s=>s.PeerID==a.Id);context.Invoke(()=>sa.Capture(new("move",DeltaX:8,ScreenID:local.Id,X:1,Y:.5)));
                await Wait(()=>context.Invoke(()=>started&&delivered.Any(e=>e.Type=="relativeReset")));var anchor=context.Invoke(()=>sa.Pointer);
                var targetOwner=context.Invoke(()=>sb.Pointer);Require(context.Invoke(()=>!sb.Capture(new("move",DeltaX:500,DeltaY:-500,HardwareMotion:false))&&sb.Pointer==targetOwner),"Software cursor warp stole relative ownership");
                context.Invoke(()=>{for(var i=0;i<200;i++)Require(sa.Capture(new("move",DeltaX:12.25,DeltaY:-.25)),"Relative capture fell through");return 0;});
                await Wait(()=>context.Invoke(()=>Math.Abs(delivered.Where(e=>e.Type=="relativeMove").Sum(e=>e.DeltaX)-2450)<.001));
                Require(context.Invoke(()=>Math.Abs(delivered.Where(e=>e.Type=="relativeMove").Sum(e=>e.DeltaY)+50)<.001&&sa.Pointer==anchor),"Coalescing lost relative delta or camera crossed an edge");
                context.Invoke(()=>captured=false);await Wait(()=>context.Invoke(()=>ended));context.Invoke(()=>sa.Capture(new("move",DeltaX:-4000)));Require(context.Invoke(()=>sa.Pointer?.ScreenID==local.Id),"Desktop crossing did not resume");
                var packet=new InputPacket {Type="relative-move",GroupID=group.Id,SourcePeerID=a.Id,TargetPeerID=b.Id,Pointer=new(group.Layout.Single(s=>s.PeerID==b.Id).Id,anchor!.X,anchor.Y,a.Id,anchor.Epoch),DeltaX=12345.125,DeltaY=-.25};
                var bytes=MotionCodec.Encode(packet,group.Layout)!;var decoded=MotionCodec.Decode(bytes,group,a.Id,b.Id);Require(decoded?.DeltaX==packet.DeltaX&&decoded?.DeltaY==packet.DeltaY,"Relative codec lost cumulative precision");
            } finally {context.Invoke(()=>{sa.Dispose();sb.Dispose();return 0;});}
        }
        Console.WriteLine("PASS: both direction relative camera deltas survive coalescing beyond screen width, pointer stays fixed, exit restores crossing, codec preserves fractions.");
    }

    public static async Task CheckNetworkRecovery() {
        await using var a=new Fixture("RecoveryA",id:"11111111-1111-4111-8111-111111111111");
        await using var b=new Fixture("RecoveryB",id:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
        await using var wrong=new Fixture("WrongRecoveryPeer");
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        wrong.Manager.Start(wrong.Port);
        var bleListener=new TcpListener(IPAddress.Loopback,0);bleListener.Start();var blePort=((IPEndPoint)bleListener.LocalEndpoint).Port;bleListener.Stop();
        b.Manager.StartBluetoothListener(blePort);
        await a.Manager.ConnectAsync("127.0.0.1",blePort,null,null,kind:"ble");
        await Wait(()=>a.Manager.CurrentSessions().FirstOrDefault()?.Capabilities.Contains("ble")==true);
        var original=a.Manager.CurrentSessions()[0].SessionID;var approvals=a.ConnectionPrompts+b.ConnectionPrompts;
        Require(new PeerRegistry(a.Directory).Find(b.Id)?.NetworkEndpoints?.Contains(new NetworkEndpoint("127.0.0.1",b.Port))==true,"Successful endpoint was not persisted");
        a.Manager.DisconnectTransport(b.Id,"tcp");await Wait(()=>!a.Manager.CurrentSessions()[0].Capabilities.Contains("tcp"));
        a.Manager.NetworkAvailable=false;await a.Manager.RecoverNetworkLinks();
        Require(!a.Manager.CurrentSessions()[0].Capabilities.Contains("tcp"),"Disabled network reconnected");a.Manager.NetworkAvailable=true;
        await a.Manager.RecoverNetworkLinks();
        await Wait(()=>a.Manager.CurrentSessions()[0].Capabilities.Contains("tcp")&&a.Manager.CurrentSessions()[0].Capabilities.Contains("ble"));
        Require(a.Manager.CurrentSessions()[0].SessionID==original&&a.ConnectionPrompts+b.ConnectionPrompts==approvals,"Recovery replaced the paired session or requested approval");
        await a.Manager.RecoverNetworkLinks();await a.Manager.RecoverNetworkLinks();
        Require(a.Manager.CurrentSessions().Length==1&&a.ConnectionPrompts+b.ConnectionPrompts==approvals,"Repeated recovery duplicated the peer");
        a.Manager.Disconnect(b.Id);await Wait(()=>a.Manager.CurrentSessions().Length==0&&b.Manager.CurrentSessions().Length==0);
        a.Registry.SetPreferences(b.Id,false,true);a.Registry.RememberNetworkEndpoint(b.Id,new("127.0.0.1",wrong.Port));
        Console.WriteLine("Cache before stale probe: "+string.Join(",",a.Registry.Find(b.Id)!.NetworkEndpoints!.Select(e=>e.Host+":"+e.Port)));
        await a.Manager.RecoverNetworkLinks();Require(a.Manager.CurrentSessions().Length==0&&wrong.ConnectionPrompts+wrong.CertificatePrompts==0,"Stale-address state: sessions="+a.Manager.CurrentSessions().Length+" wrongPrompts="+(wrong.ConnectionPrompts+wrong.CertificatePrompts));
        await a.Manager.RecoverNetworkLinks();Require(a.Manager.CurrentSessions().Length==0,"Failed endpoint ignored retry backoff");
        await Task.Delay(2100);await a.Manager.RecoverNetworkLinks();await Wait(()=>a.Manager.CurrentSessions().Length==1);
        Require(a.ConnectionPrompts+b.ConnectionPrompts==approvals+1,"Fresh recovery must retain receiver approval");
        Console.WriteLine("PASS: no-Bonjour cached recovery retains BLE/session, respects network switch, pins stale-address identity, backs off and preserves fresh-session approval.");
    }

    public static async Task CheckLayoutConsistency() {
        await using var a=new Fixture("LayoutLeader"); await using var b=new Fixture("LayoutFollower");
        a.Group.Start(); b.Group.Start(); a.Manager.Start(a.Port); b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2 && a.Group.Active?.Id==b.Group.Active?.Id);
        var first=a.Group.Active!;
        Require(first.LeaderID==a.Id,"Unexpected fixture coordinator");
        var newer=first with {Revision=first.Revision+7,Layout=first.Layout.Select((s,i)=>i==1?s with {Y=180}:s).ToArray()};
        File.WriteAllText(Path.Combine(b.Directory,"groups.json"),JsonSerializer.Serialize(new GroupStore([newer],newer.Id),json));
        b.Group=new(b.Id,"LayoutFollower",b.Identity.Identity.PublicKey,newer.Layout.Where(s=>s.PeerID==b.Id).ToArray(),b.Directory,b.Manager,b.Registry,_=>Task.FromResult(false),_=>{},automaticSharing:true);
        b.Group.Start(); await b.Group.ConnectionsChanged(b.Manager.CurrentSessions());
        await Wait(()=>a.Group.Active!.Layout.SequenceEqual(newer.Layout) && b.Group.Active!.Layout.SequenceEqual(newer.Layout)
            && a.Group.Active.Revision==b.Group.Active.Revision && a.Group.Active.LeaderID==a.Id && b.Group.Active.LeaderID==a.Id);
        first=a.Group.Active!;
        var lease=await b.Group.BeginEdit("layout");
        for(var i=0;i<3;i++) {await a.Group.UpdateScreens(first.Layout.Where(s=>s.PeerID==a.Id).ToArray());await b.Group.UpdateScreens(first.Layout.Where(s=>s.PeerID==b.Id).ToArray());}
        var arranged=first.Layout.Select((s,i)=>i==1?s with {Y=90}:s).ToArray();
        await b.Group.CommitLayout(arranged,lease);
        await Wait(()=>a.Group.Active!.Layout.SequenceEqual(arranged) && b.Group.Active!.Layout.SequenceEqual(arranged));
        Require(a.Group.Active!.Revision==first.Revision+1,"Unchanged display reports invalidated the version");
        var again=await b.Group.BeginEdit("layout");var reused=await b.Group.BeginEdit("layout");
        Require(again==reused,"The lease owner cannot recover its own lease");await b.Group.Release(again);
        Console.WriteLine("PASS: newer follower layout converges on unchanged TLS session, both sides save; no-op display reports preserve lease and revision; owned lease can be recovered.");
    }
    private static readonly JsonSerializerOptions json=new() { PropertyNamingPolicy=JsonNamingPolicy.CamelCase };
    public static async Task CheckRepeatedApproval() {
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(30));var cancel=deadline.Token;
        await using(var a=new Fixture("ApprovalA")) await using(var b=new Fixture("ApprovalB")) {
            a.Registry.Remember(b.Identity.Identity,"ApprovalB");b.Registry.Remember(a.Identity.Identity,"ApprovalA");
            b.Manager.Start(b.Port);
            var free=new TcpListener(IPAddress.Loopback,0);free.Start();var port=((IPEndPoint)free.LocalEndpoint).Port;free.Stop();b.Manager.StartBluetoothListener(port);
            await using var waiting=await SecureTcp.ConnectAsync("127.0.0.1",b.Port,a.Identity,_=>true,cancel);
            _=await waiting.ReceiveAsync(cancel);
            await waiting.SendAsync(new SessionMessage {Type="pair",SourcePeerID=a.Id,TargetPeerID=b.Id,Mode="known",Name="ApprovalA",Capabilities=["group"]},cancel);
            var accepted=await waiting.ReceiveAsync(cancel);Require(accepted.Type=="accepted","First approval failed");
            await a.Manager.ConnectAsync("127.0.0.1",port,null,null,kind:"ble");
            Require(b.ConnectionPrompts+b.BluetoothPrompts==1,"Approval was discarded before the first stream sent ready");
            Require(b.Manager.CurrentSessions().Single().SessionID==accepted.SessionID,"Concurrent approved transports split the session");
            await waiting.SendAsync(new SessionMessage {Type="ready",SourcePeerID=a.Id,TargetPeerID=b.Id,SessionID=accepted.SessionID},cancel);
            Require((await waiting.ReceiveAsync(cancel)).Type=="established","Delayed first ready did not commit");
        }
        await using(var a=new Fixture("AttachA")) await using(var b=new Fixture("AttachB")) {
            b.Registry.Remember(a.Identity.Identity,"AttachA");b.Manager.StartBluetoothListener(b.Port);
            async Task<SecureTcp> Prepare(string instance,string mode) {
                var stream=await SecureTcp.ConnectAsync("127.0.0.1",b.Port,a.Identity,_=>true,cancel,"ble");
                try {
                    var hello=await stream.ReceiveAsync(cancel);
                    await stream.SendAsync(new SessionMessage {Type="pair",SourcePeerID=a.Id,TargetPeerID=b.Id,Mode=mode,InstanceID=instance,SessionID=mode=="attach"?hello.SessionID:null,Name="AttachA"},cancel);
                    var accepted=await stream.ReceiveAsync(cancel);Require(accepted.Type=="accepted","Attach approval failed");
                    await stream.SendAsync(new SessionMessage {Type="ready",SourcePeerID=a.Id,TargetPeerID=b.Id,SessionID=accepted.SessionID},cancel);
                    return stream;
                } catch {await stream.DisposeAsync();throw;}
            }
            async Task<bool> Probe(SecureTcp stream) {
                for(var i=0;i<12;i++){var frame=await stream.ReceiveAsync(cancel);if(frame.Channel=="retained")return Encoding.UTF8.GetString(frame.Payload!)=="alive";}return false;
            }
            var instance=Guid.NewGuid().ToString("D");
            await using var first=await Prepare(instance,"known");Require((await first.ReceiveAsync(cancel)).Type=="established","Initial stream failed");
            await using var duplicate=await Prepare(instance,"attach");
            var refused=false;try{_=await duplicate.ReceiveAsync(cancel);}catch(IOException){refused=true;}catch(AuthenticationException){refused=true;}
            Require(refused,"Same-process attach replaced the live stream");
            await b.Manager.SendAsync(a.Id,"retained",Encoding.UTF8.GetBytes("alive"));Require(await Probe(first),"Live encrypted delivery was lost after duplicate attach");
            await using var restarted=await Prepare(Guid.NewGuid().ToString("D"),"attach");Require((await restarted.ReceiveAsync(cancel)).Type=="established","New process could not replace stale stream");
            await b.Manager.SendAsync(a.Id,"retained",Encoding.UTF8.GetBytes("alive"));Require(await Probe(restarted),"Restarted process did not receive data");
            Require(b.BluetoothPrompts==1,"Attach unnecessarily requested another approval");
        }
        await CheckInputGeneration();
        Console.WriteLine("Repeated approval regression passed: pending approval retained, duplicate attach preserves live delivery, genuine process restart reconnects");
    }
    private static async Task CheckInputGeneration() {
        await using var a=new Fixture("InputEpochA");await using var b=new Fixture("InputEpochB");
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);
        b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Active is not null&&a.Group.Active.Id==b.Group.Active?.Id);
        await b.Manager.SetCapabilityAsync("input",true);
        using var context=new FixtureInputContext();var input=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{}));
        try {
            var state=a.Group.Active!;var sessions=a.Manager.CurrentSessions();var screen=state.Layout.Single(s=>s.PeerID==a.Id);
            await context.Invoke(async()=>{input.Update(state,[a.Id,b.Id],sessions);await input.Enable();});
            await Wait(()=>a.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("input")));
            sessions=a.Manager.CurrentSessions();context.Invoke(()=>{input.Update(state,[a.Id,b.Id],sessions);return true;});
            var packet=new InputPacket {Type="control",GroupID=state.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,Sequence=100,Pointer=PointerRouter.Center(screen,b.Id,100)};
            await b.Manager.SendAsync(a.Id,"input",JsonSerializer.SerializeToUtf8Bytes(packet,json));
            await Wait(()=>context.Invoke(()=>input.Pointer?.OwnerPeerID==b.Id&&input.Pointer.Epoch==100));
            sessions[0]=sessions[0] with {RemoteInstanceID=Guid.NewGuid().ToString("D")};
            Require(context.Invoke(()=>{input.Update(state,[a.Id,b.Id],sessions);return input.Pointer?.OwnerPeerID==a.Id;}),"Restart retained stale remote control");
            packet.Sequence=1;packet.Pointer=PointerRouter.Center(screen,b.Id,context.Invoke(()=>input.Pointer!.Epoch)+1);
            await b.Manager.SendAsync(a.Id,"input",JsonSerializer.SerializeToUtf8Bytes(packet,json));
            await Wait(()=>context.Invoke(()=>input.Pointer?.OwnerPeerID==b.Id));
            Require(context.Invoke(()=>input.Enabled),"Restart disabled sharing");
            Console.WriteLine("Input generation regression passed: a retained TLS session accepts restarted input sequence 1 after sequence 100");
        } finally {context.Invoke(()=>{input.Dispose();return true;});}
    }
    public static async Task CheckBulkRoute() {
        await using(var a=new Fixture("BulkA",bluetoothInputOnly:true)) await using(var b=new Fixture("BulkB",bluetoothInputOnly:true)) {
            a.Group.Start();b.Group.Start();b.Manager.StartBluetoothListener(b.Port);
            await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret",kind:"ble");
            var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);var input=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            b.Manager.Receive("history",(_,_)=>{received.TrySetResult();return Task.CompletedTask;});
            b.Manager.Receive("input",(_,_)=>{input.TrySetResult();return Task.CompletedTask;});
            var bulk=a.Manager.SendTrackedAsync(b.Id,"history",new byte[3000]);await Task.Delay(150);
            Require(!received.Task.IsCompleted,"History filled BLE before TCP attach");
            Require(await a.Manager.SendTrackedAsync(b.Id,"input",[1])=="ble","Input blocked behind history");await input.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var free=new TcpListener(IPAddress.Loopback,0);free.Start();var port=((IPEndPoint)free.LocalEndpoint).Port;free.Stop();b.Manager.Start(port);
            await a.Manager.ConnectAsync("127.0.0.1",port,null,null);
            Require(await bulk=="tcp","History did not adopt newly attached TCP");await received.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var state=a.Manager.CurrentSessions().Single();Require(state.Capabilities.Contains("ble")&&state.Capabilities.Contains("tcp"),"Bulk routing dropped a link");
        }
        await using(var c=new Fixture("FallbackA",bluetoothInputOnly:true)) await using(var d=new Fixture("FallbackB",bluetoothInputOnly:true)) {
            c.Group.Start();d.Group.Start();d.Manager.StartBluetoothListener(d.Port);await c.Manager.ConnectAsync("127.0.0.1",d.Port,"123456","fixture-secret",kind:"ble");
            d.Manager.Receive("history",(_,_)=>Task.CompletedTask);var start=Environment.TickCount64;
            Require(await c.Manager.SendTrackedAsync(d.Id,"history",[1])=="ble","BLE-only bulk fallback disappeared");Require(Environment.TickCount64-start<6000,"Bulk fallback waited indefinitely");
            c.Manager.NetworkAvailable=false;start=Environment.TickCount64;await c.Manager.SendAsync(d.Id,"history",[2]);Require(Environment.TickCount64-start<500,"Disabled network still added a routing wait");
        }
        Console.WriteLine("PASS: BLE-first history waits for TCP while input remains immediate; bounded BLE-only fallback and explicit network-disabled behavior preserved.");
    }
    public static async Task CheckDualLinkReconnect() {
        await using var a=new Fixture("ReconnectA",bluetoothInputOnly:true);
        await using var b=new Fixture("ReconnectB",bluetoothInputOnly:true);
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Active is not null&&a.Group.Active.Id==b.Group.Active?.Id);
        var free=new TcpListener(IPAddress.Loopback,0);free.Start();var blePort=((IPEndPoint)free.LocalEndpoint).Port;free.Stop();
        b.Manager.StartBluetoothListener(blePort);await a.Manager.ConnectAsync("127.0.0.1",blePort,null,null,kind:"ble");
        var state=a.Group.Active!;
        await b.Manager.SetCapabilitiesAsync(new Dictionary<string,bool>{{"input",true},{"compact-input",true},{"ble-input-v2",true}});
        using var context=new FixtureInputContext();
        var input=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{}));
        using var ca=new ClipboardService(a.Id,a.Manager,context,_=>{});
        using var cb=new ClipboardService(b.Id,b.Manager,context,_=>{});
        var targetScreen=state.Layout.Single(s=>s.PeerID==b.Id);
        using var source=new ComputerUseService(a.Id,"ReconnectA",a.Manager,null,ca,context,()=>[],()=>ComputerUseService.Obj(("marker","A")),_=>Task.FromResult(new System.Text.Json.Nodes.JsonObject()),(_,_,_,_)=>{},()=>false,_=>{},()=>true);
        using var target=new ComputerUseService(b.Id,"ReconnectB",b.Manager,null,cb,context,()=>[targetScreen],()=>ComputerUseService.Obj(("marker","B")),_=>Task.FromResult(ComputerUseService.Obj(("width",1000),("height",720))),(_,_,_,_)=>{},()=>{_=b.Manager.SetCapabilityAsync("input",false);return true;},resume=>{_=b.Manager.SetCapabilityAsync("input",true);},()=>true);
        var packets=new System.Collections.Concurrent.ConcurrentQueue<InputPacket>();
        source.AllowComputer=target.AllowComputer=true;
        try {
            await source.Start();await target.Start();
            await context.Invoke(async()=>{input.Update(state,[a.Id,b.Id],a.Manager.CurrentSessions());await input.Enable();});
            await Wait(()=>a.Manager.CurrentSessions().Single().Capabilities.Contains("input"));
            b.Manager.Receive("input",async (peer,bytes)=>{
                var packet=MotionCodec.Decode(bytes,state,peer,b.Id)??JsonSerializer.Deserialize<InputPacket>(bytes,json)!;
                packets.Enqueue(packet);
                if(packet.Type=="move") {
                    var ack=new InputPacket{Type="motionAck",GroupID=state.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,AcknowledgedSequence=packet.Sequence};
                    await b.Manager.SendAsync(a.Id,"input",MotionCodec.Encode(ack,state.Layout)!);
                }
            });
            for(var i=0;i<20;i++)await context.Invoke(async()=>{input.Pause();input.Update(state,[a.Id,b.Id],a.Manager.CurrentSessions());await input.Enable();});
            context.Invoke(()=>{input.Update(state,[a.Id,b.Id],a.Manager.CurrentSessions());return true;});await Task.Delay(120);
            var before=packets.Count(p=>p.Type=="priority");
            context.Invoke(()=>{for(var i=0;i<36;i++)input.Update(state,[a.Id,b.Id],a.Manager.CurrentSessions());return true;});await Task.Delay(120);
            Require(packets.Count(p=>p.Type=="priority")==before,"Unchanged refresh filled BLE with priority packets");
            var opened=await context.Invoke(()=>source.Tool("open_computer",ComputerUseService.Obj(("peer_id",b.Id))));
            await Wait(()=>!a.Manager.CurrentSessions().Single().Capabilities.Contains("input"));
            for(var i=0;i<6;i++) {
                await context.Invoke(async()=>{input.Pause();input.Update(state,[a.Id,b.Id],a.Manager.CurrentSessions());await input.Enable();});
                var info=await context.Invoke(()=>source.Tool("get_computer_info",ComputerUseService.Obj(("peer_id",b.Id))));Require(info["marker"]!.GetValue<string>()=="B","Forward MCP response lost");
                info=await context.Invoke(()=>target.Tool("get_computer_info",ComputerUseService.Obj(("peer_id",a.Id))));Require(info["marker"]!.GetValue<string>()=="A","Reverse MCP response lost");
                Require(context.Invoke(()=>target.Controlling),"Reconnect ended active MCP control");
            }
            await context.Invoke(()=>source.Tool("close_computer",ComputerUseService.Obj(("peer_id",b.Id),("control_session_id",opened["control_session_id"]))));
            await Wait(()=>a.Manager.CurrentSessions().Single().Capabilities.Contains("input"));
            context.Invoke(()=>{input.Update(state,[a.Id,b.Id],a.Manager.CurrentSessions());return true;});
            var local=state.Layout.Single(s=>s.PeerID==a.Id);var dx=targetScreen.X>local.X?8d:-8d;
            context.Invoke(()=>input.Capture(new("move",DeltaX:dx,ScreenID:local.Id,X:dx>0?1:0,Y:.5)));
            for(var i=0;i<80;i++){context.Invoke(()=>input.Capture(new("move",DeltaX:dx>0?.5:-.5,ScreenID:local.Id,X:dx>0?1:0,Y:.5)));await Task.Delay(3);}
            await Wait(()=>packets.Count(p=>p.Type=="move")>40);
            var heldBefore=packets.Count(p=>p.Type=="held");await Task.Delay(1200);
            Require(packets.Count(p=>p.Type=="held")==heldBefore,"Empty repair repeatedly filled idle BLE");
            context.Invoke(()=>input.Capture(new("keyDown","ShiftLeft")));
            await Wait(()=>packets.Any(p=>p.Type=="held"&&p.Keys?.Contains("ShiftLeft")==true));
            context.Invoke(()=>input.Capture(new("keyUp","ShiftLeft")));
            await Wait(()=>packets.Count(p=>p.Type=="held")>heldBefore+1);
            Require(packets.Last(p=>p.Type=="held").Keys?.Length==0,"Changed empty state did not clear held input");
            Require(context.Invoke(()=>input.Enabled&&!target.Controlling),"Sharing failed after MCP close");
            var saved=a.Manager.CurrentSessions().Single();Require(saved.Capabilities.Contains("tcp")&&saved.Capabilities.Contains("ble"),"Lost attached transport");
            var enabled=saved.Capabilities.Except(["tcp","ble","quic"]).ToArray();
            var apply=typeof(SessionManager).GetMethod("ApplyRemoteCapabilities",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
            apply.Invoke(a.Manager,[b.Id,80000UL,JsonSerializer.SerializeToUtf8Bytes(enabled.Except(["input"]).ToArray()),null]);
            apply.Invoke(a.Manager,[b.Id,79999UL,JsonSerializer.SerializeToUtf8Bytes(enabled),null]);
            apply.Invoke(a.Manager,[b.Id,80000UL,JsonSerializer.SerializeToUtf8Bytes(enabled),null]);
            Require(!a.Manager.CurrentSessions().Single().Capabilities.Contains("input"),"Delayed/duplicate snapshot undid newer pause");
            apply.Invoke(a.Manager,[b.Id,80001UL,JsonSerializer.SerializeToUtf8Bytes(enabled),null]);
            Require(a.Manager.CurrentSessions().Single().Capabilities.Contains("input"),"New snapshot could not restore input");
            Require(a.Manager.CurrentSessions().Single().SessionID==saved.SessionID,"Capability ordering replaced session");
            Console.WriteLine("PASS: 26 input reconnects retain TCP+BLE, no refresh priority flood, MCP request/reply both directions during control, compact movement resumes; delayed/duplicate capability snapshots cannot undo pause.");
        } finally {context.Invoke(()=>{input.Dispose();source.EndControl();target.EndControl();return true;});}
    }
    public static async Task CheckInputTransport() {
        await using var a=new Fixture("SavedModeA",bluetoothInputOnly:true);
        await using var b=new Fixture("SavedModeB",bluetoothInputOnly:true);
        b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        Require(await a.Manager.SendTrackedAsync(b.Id,"input",Encoding.UTF8.GetBytes("network fallback"))=="tcp","Bluetooth preference must use a connected network when BLE is absent");
        var available=new TcpListener(IPAddress.Loopback,0); available.Start(); var blePort=((IPEndPoint)available.LocalEndpoint).Port; available.Stop();
        b.Manager.StartBluetoothListener(blePort);
        await a.Manager.ConnectAsync("127.0.0.1",blePort,null,null,kind:"ble");
        var receivedA=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var receivedB=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        a.Manager.Receive("input",(_,bytes)=> {if(Encoding.UTF8.GetString(bytes)=="cross to A")receivedA.TrySetResult();return Task.CompletedTask;});
        b.Manager.Receive("input",(_,bytes)=> {if(Encoding.UTF8.GetString(bytes)=="cross to B")receivedB.TrySetResult();return Task.CompletedTask;});
        Require(await a.Manager.SendTrackedAsync(b.Id,"input",Encoding.UTF8.GetBytes("cross to B"))=="ble","A selected a network stream for strict input");
        Require(await b.Manager.SendTrackedAsync(a.Id,"input",Encoding.UTF8.GetBytes("cross to A"))=="ble","B selected a network stream for strict input");
        await Task.WhenAll(receivedA.Task,receivedB.Task).WaitAsync(TimeSpan.FromSeconds(12));
        Require(a.Manager.CurrentSessions().Single().Capabilities.Contains("tcp")&&a.Manager.CurrentSessions().Single().Capabilities.Contains("ble"),"Test lost one of the attached transports");
        a.Manager.SetInputLinkPreference(false);Require(await a.Manager.SendTrackedAsync(b.Id,"input",Encoding.UTF8.GetBytes("network chosen"))=="tcp","Live network selection failed");
        a.Manager.SetInputLinkPreference(true);a.Manager.DisconnectTransport(b.Id,"ble");await Wait(()=>a.Manager.CurrentSessions().All(s=>!s.Capabilities.Contains("ble")));
        Require(await a.Manager.SendTrackedAsync(b.Id,"input",Encoding.UTF8.GetBytes("network restored"))=="tcp","Lost BLE did not fall back to network");
        Console.WriteLine("Input transport regression passed: Bluetooth preference, live Wi-Fi switch and network fallback with the same paired session");
    }
    public static async Task CheckBluetoothPairing() {
        foreach(var kind in new[]{"tcp","ble"}) {
            await using var a=new Fixture("OptionsA"); await using var b=new Fixture("OptionsB");
            var listener=new TcpListener(IPAddress.Loopback,0); listener.Start(); var port=((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
            if(kind=="ble") b.Manager.StartBluetoothListener(port); else b.Manager.Start(port);
            async Task Rejected(Func<Task> operation,string reason) {
                var failed=false; try {await operation();} catch(InvalidDataException) {failed=true;} catch(IOException) {failed=true;} catch(AuthenticationException) {failed=true;}
                Require(failed,reason);
            }
            b.Manager.UpdateCredentials("123456","");
            await Rejected(async()=> {await a.Manager.ConnectAsync("127.0.0.1",port,"000000","",kind:kind);},"Wrong code accepted with empty key");
            b.Manager.BluetoothAvailable=false; b.Manager.NetworkAvailable=false;
            await Rejected(async()=> {await a.Manager.ConnectAsync("127.0.0.1",port,"123456","",kind:kind);},"Disabled incoming transport accepted pairing");
            b.Manager.BluetoothAvailable=true; b.Manager.NetworkAvailable=true;
            b.Manager.UpdateCredentials("123456","fixture-secret");
            await Rejected(async()=> {await a.Manager.ConnectAsync("127.0.0.1",port,"123456","",kind:kind);},"Configured key bypassed");
            b.Manager.UpdateCredentials("123456","");
            await a.Manager.ConnectAsync("127.0.0.1",port,"123456","",kind:kind);
            Require(a.Manager.CurrentSessions().Length==1 && a.Registry.Find(b.Id)?.Trust=="known","Unified pairing failed or escalated trust");
            await using var changed=new Fixture("ChangedIdentity");
            changed.Registry.Remember(new(b.Id,changed.Identity.Identity.PublicKey),"Pinned test identity");
            await Rejected(async()=> {await changed.Manager.ConnectAsync("127.0.0.1",port,"123456","",kind:kind);},"Changed pinned identity accepted");
        }
        await using var first=new Fixture("ConcurrentA"); await using var second=new Fixture("ConcurrentB",800);
        first.Registry.Remember(second.Identity.Identity,"ConcurrentB"); second.Registry.Remember(first.Identity.Identity,"ConcurrentA");
        var available=new TcpListener(IPAddress.Loopback,0); available.Start(); var blePort=((IPEndPoint)available.LocalEndpoint).Port; available.Stop();
        second.Manager.Start(second.Port); second.Manager.StartBluetoothListener(blePort);
        await Task.WhenAll(first.Manager.ConnectAsync("127.0.0.1",second.Port,null,null),first.Manager.ConnectAsync("127.0.0.1",blePort,null,null,kind:"ble"));
        Require(second.ConnectionPrompts+second.BluetoothPrompts==1,"Concurrent links displayed duplicate approvals");
        Require(first.Manager.CurrentSessions().Single().Capabilities.Contains("tcp") && first.Manager.CurrentSessions().Single().Capabilities.Contains("ble"),"Concurrent links replaced each other");
        Console.WriteLine("PASS: concurrent TCP/BLE share one approval and retain both links in one session.");
        Console.WriteLine("PASS: TCP/BLE unified code, optional key, wrong code/key rejection, disabled incoming transport and pinned identity (local TLS).");
        await CheckCapabilitiesDuringHandshake();
        await CheckLateReverseApproval();
    }
    private static async Task CheckCapabilitiesDuringHandshake() {
        await using var a=new Fixture("CapsA"); await using var b=new Fixture("CapsB",800);
        a.Registry.Remember(b.Identity.Identity,"CapsB"); b.Registry.Remember(a.Identity.Identity,"CapsA");
        b.Manager.StartBluetoothListener(b.Port);
        var connecting=a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,kind:"ble");
        await Wait(()=>Volatile.Read(ref b.BluetoothPrompts)==1);
        // Hello/pair have already captured the old capabilities while approval waits.
        await a.Manager.SetCapabilityAsync("input",true); await b.Manager.SetCapabilityAsync("input",true);
        await connecting;
        await Wait(()=>a.Manager.CurrentSessions().Single().Capabilities.Contains("input") && b.Manager.CurrentSessions().Single().Capabilities.Contains("input"));
        Console.WriteLine("PASS: capabilities enabled during BLE handshake are replayed on the committed link (local TLS).");
    }
    private static async Task CheckLateReverseApproval() {
        var ids=new[]{Guid.NewGuid().ToString("D"),Guid.NewGuid().ToString("D")}.OrderBy(id=>id,StringComparer.Ordinal).ToArray();
        await using var low=new Fixture("Low",800,ids[0]); await using var high=new Fixture("High",0,ids[1]);
        low.Registry.Remember(high.Identity.Identity,"High"); high.Registry.Remember(low.Identity.Identity,"Low");
        low.Manager.StartBluetoothListener(low.Port); high.Manager.StartBluetoothListener(high.Port);
        var reverse=high.Manager.ConnectAsync("127.0.0.1",low.Port,null,null,kind:"ble");
        await Wait(()=>Volatile.Read(ref low.BluetoothPrompts)==1);
        await low.Manager.ConnectAsync("127.0.0.1",high.Port,null,null,kind:"ble");
        var before=low.Manager.CurrentSessions().Single().SessionID;
        var ignored=false; try {await reverse;} catch(IOException) {ignored=true;} catch(InvalidDataException) {ignored=true;} catch(AuthenticationException) {ignored=true;}
        Require(ignored,"Late reverse approval replaced the live BLE link");
        Require(low.Manager.CurrentSessions().Single().SessionID==before,"Duplicate approval changed session identity");
        var received=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        high.Manager.Receive("still-live",(_,bytes)=>{received.TrySetResult(Encoding.UTF8.GetString(bytes)=="link retained");return Task.CompletedTask;});
        await low.Manager.SendAsync(high.Id,"still-live",Encoding.UTF8.GetBytes("link retained"));
        Require(await received.Task.WaitAsync(TimeSpan.FromSeconds(5)),"Retained BLE stream stopped delivering");
        Console.WriteLine("PASS: late reverse approval cannot replace the winning BLE link; encrypted delivery continues (local TLS).");
    }
    public static async Task Run() {
        await Check(false); await Check(true); await CheckCompactDelivery(); await CheckContinuousMotion(); await CheckSlowLinkIsolation(); await CheckMetadata(); await CheckDirectoryStagingAndConflictFinish(); CheckWireVector();
        Console.WriteLine("PASS: automatic desktop, existing desktop reconciliation, saved layout reconnect, connection confirmation, local input passthrough, coalesced motion, ordered critical input 512 concurrent encrypted frames, bounded compact input, drag release, temporary recovery, known-device reconnect, 10-second RTT probes, uninterrupted motion past half-second snapshots, slow-link isolation, metadata filtering and cross-platform wire vector");
    }
    public static async Task CheckFileTransfers() {
        await CheckMetadata(); await CheckDirectoryStagingAndConflictFinish(); await CheckConflictApplyAll();
        Console.WriteLine("PASS: hidden Windows staging, visible final file, cleanup and encrypted file transfer/conflict completion.");
    }
    private static async Task Check(bool legacy) {
        await using var a=new Fixture("A"); await using var b=new Fixture("B");
        if(legacy) { await a.Group.Create("我的桌面"); await b.Group.Create("我的桌面"); }
        var original=a.Group.Active?.Id;
        a.Group.Start(); b.Group.Start(); a.Manager.Start(a.Port); b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2 && a.Group.Active?.Id==b.Group.Active?.Id);
        Require(a.GroupPrompts+b.GroupPrompts==0,"Redundant admission prompt after authenticated pairing");
        if(legacy) {
            Require(b.Group.Active?.Id==original,"Legacy desktops did not converge to the initiating peer");
            var saved=JsonSerializer.Deserialize<GroupStore>(File.ReadAllText(Path.Combine(b.Directory,"groups.json")),json)!;
            Require(saved.Groups.Length==2,"Legacy saved desktop was deleted"); return;
        }
        var first=a.Group.Active!; var lease=await a.Group.BeginEdit("layout");
        var layout=first.Layout.Select((s,i)=>i==1?s with { Y=100 }:s).ToArray();
        await a.Group.CommitLayout(layout,lease); await a.Group.Release(lease);
        await Wait(()=>b.Group.Active!.Layout.SequenceEqual(layout));
        var frames=new ConcurrentDictionary<string,bool>();
        b.Manager.Receive("stress",(_,bytes)=> { frames.TryAdd(Encoding.UTF8.GetString(bytes),true); return Task.CompletedTask; });
        await Task.WhenAll(Enumerable.Range(0,512).Select(i=>a.Manager.SendAsync(b.Id,"stress",Encoding.UTF8.GetBytes(i.ToString()))));
        await Wait(()=>frames.Count==512);
        await a.Manager.SetCapabilityAsync("input",true); await b.Manager.SetCapabilityAsync("input",true);
        await Wait(()=>a.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("input")));
        var packets=new ConcurrentQueue<InputPacket>();
        b.Manager.Receive("input",(_,bytes)=> { packets.Enqueue(JsonSerializer.Deserialize<InputPacket>(bytes,json)!); return Task.CompletedTask; });
        using var context=new FixtureInputContext(); var injections=0;
        var input=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(_,_,_,_)=>injections++,(_,_)=>{},_=>{}));
        try {
            await context.Invoke(async()=> { input.Update(a.Group.Active,[a.Id,b.Id],a.Manager.CurrentSessions()); await input.Enable(); });
            context.Invoke(()=> {
                injections=0; var local=layout.Single(s=>s.PeerID==a.Id);
                foreach(var e in new[] { new CapturedInput("keyDown",Key:"KeyA"),new("keyUp",Key:"KeyA"),new("buttonDown"),new("buttonUp"),new("scroll",DeltaY:30),new("move",DeltaX:10,ScreenID:local.Id,X:.5,Y:.5) })
                    Require(!input.Capture(e),"Local event was consumed instead of passing through");
                Require(injections==0,"Local events were synthetically reinjected");
                foreach(var key in new[]{"KeyC","KeyX","KeyV","KeyZ","KeyY"})foreach(var e in new[]{new CapturedInput("keyDown",Key:"ControlLeft"),new("keyDown",Key:key),new("keyUp",Key:key),new("keyUp",Key:"ControlLeft")})Require(!input.Capture(e),"Local clipboard/undo chords were intercepted");
                Require(injections==0,"Native clipboard chords injected synthetic input");
                Require(input.Capture(new("move",DeltaX:8,ScreenID:local.Id,X:1,Y:.5)),"Failed to cross the contact edge");
                for(var i=0;i<200;i++) input.Capture(new("move",DeltaX:1,ScreenID:local.Id,X:1,Y:.5));
                input.Capture(new("buttonDown")); input.Capture(new("buttonUp")); input.Capture(new("keyDown",Key:"KeyA")); input.Capture(new("keyUp",Key:"KeyA"));
                return true;
            });
            await Wait(()=>packets.Any(p=>p.Type=="keyUp")); var received=packets.ToArray();
            Require(received.Count(p=>p.Type=="move")<20,"Continuous mouse movement was not coalesced");
            var critical=received.Where(p=>new[]{"buttonDown","buttonUp","keyDown","keyUp"}.Contains(p.Type)).Select(p=>p.Type);
            Require(critical.SequenceEqual(new[]{"buttonDown","buttonUp","keyDown","keyUp"}),"Critical input was reordered or lost");
            Require(received.Select(p=>p.Sequence).SequenceEqual(received.Select(p=>p.Sequence).Order()),"Input sequence is out of order");
            context.Invoke(()=> { input.Pause(); Require(!input.Capture(new("keyDown",Key:"KeyA")),"Pause still intercepts local input"); return true; });
        } finally { context.Invoke(()=> { input.Dispose(); return true; }); }
        a.Registry.SetPreferences(b.Id,true,true); b.Registry.SetPreferences(a.Id,true,true);
        a.Manager.Disconnect(b.Id); await Wait(()=>a.Manager.CurrentSessions().Length==0 && b.Manager.CurrentSessions().Length==0);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,autoOnly:true);
        await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2);
        Require(b.ConnectionPrompts==1,"AutoConnect silently accepted a fresh sharing session");
        Require(a.Group.Active!.Id==first.Id && b.Group.Active!.Layout.SequenceEqual(layout),"Reconnect lost saved layout");
        var store=JsonSerializer.Deserialize<GroupStore>(File.ReadAllText(Path.Combine(a.Directory,"groups.json")),json)!;
        Require(store.Groups.Length==1,"Reconnect created duplicate desktops");
        a.Manager.Disconnect(b.Id); await Wait(()=>a.Manager.CurrentSessions().Length==0 && b.Manager.CurrentSessions().Length==0);
        b.AllowConnections=false;
        for(var i=0;i<2;i++) {
            var failed=false; try { await a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,autoOnly:true); } catch(InvalidDataException) { failed=true; }
            Require(failed,"Declined automatic connection was accepted");
        }
        Require(b.ConnectionPrompts==2,"Declining triggered repeated confirmation dialogs");
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2);
        a.Manager.Disconnect(b.Id); await Wait(()=>a.Manager.CurrentSessions().Length==0 && b.Manager.CurrentSessions().Length==0);
        await a.Group.ConnectionsChanged([]); await b.Group.ConnectionsChanged([]);
        await a.Group.Leave(); await b.Group.Leave(); await a.Group.Create("我的桌面"); await b.Group.Create("我的桌面");
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Active?.Id==first.Id && b.Group.Active?.Id==first.Id && b.Group.Online.Length==2);
        Require(b.Group.Active!.Layout.SequenceEqual(layout),"Inactive saved desktop layout was lost");
        var retained=JsonSerializer.Deserialize<GroupStore>(File.ReadAllText(Path.Combine(a.Directory,"groups.json")),json)!;
        Require(retained.Groups.Length==2,"Restoring deleted the legacy solo desktop");
    }
    [System.Runtime.InteropServices.DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint period);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint period);
    private static async Task CheckCompactDelivery() {
        await using var a=new Fixture("InputA"); await using var b=new Fixture("InputB");
        a.Group.Start(); b.Group.Start(); a.Manager.Start(a.Port); b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret"); await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2);
        a.Registry.SetPreferences(b.Id,false,true); b.Registry.SetPreferences(a.Id,false,true);
        a.Manager.Disconnect(b.Id); await Wait(()=>a.Manager.CurrentSessions().Length==0 && b.Manager.CurrentSessions().Length==0);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,autoOnly:true); await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2);
        Require(b.ConnectionPrompts==1,"Known-device quick reconnect did not request confirmation");
        foreach(var manager in new[] {a.Manager,b.Manager}) {await manager.SetCapabilityAsync("compact-input",true); await manager.SetCapabilityAsync("input",true);}
        await Wait(()=>a.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("compact-input")));
        var group=a.Group.Active!; var packets=new ConcurrentQueue<InputPacket>();
        b.Manager.Receive("input",(peer,bytes)=> {var packet=MotionCodec.Decode(bytes,group,peer,b.Id)??JsonSerializer.Deserialize<InputPacket>(bytes,json); if(packet is not null) packets.Enqueue(packet); return Task.CompletedTask;});
        using var context=new FixtureInputContext(); var events=new List<CapturedInput>();
        var input=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(e,_,_,_)=>events.Add(e),(_,_)=>{},_=>{}));
        var resolution=timeBeginPeriod(1)==0;
        try {
            await context.Invoke(async()=> {input.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());await input.Enable();});
            var local=group.Layout.Single(s=>s.PeerID==a.Id);
            context.Invoke(()=> {input.Capture(new("buttonDown")); input.Capture(new("move",DeltaX:8,ScreenID:local.Id,X:1,Y:.5)); Require(events.Any(e=>e.Type=="buttonUp"),"Crossing did not end the original local drag");return true;});
            for(var i=0;i<50;i++) {context.Invoke(()=>input.Capture(new("move",DeltaX:1,ScreenID:local.Id,X:1,Y:.5)));await Task.Delay(2);}
            await Task.Delay(20); var moves=packets.Where(p=>p.Type=="move").ToArray();
            Require(moves.Length==8,"The unacknowledged motion window was not bounded to eight"); Require(!packets.Any(p=>p.Type=="buttonDown"),"Dragging continued after crossing");
            var ack=new InputPacket {Type="motionAck",GroupID=group.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,AcknowledgedSequence=moves.Last().Sequence};
            await b.Manager.SendAsync(a.Id,"input",MotionCodec.Encode(ack,group.Layout)!); await Wait(()=>packets.Count(p=>p.Type=="move")>8);
            context.Invoke(()=> {input.Capture(new("buttonDown"));input.Capture(new("buttonUp"));return true;}); await Wait(()=>packets.Any(p=>p.Type=="buttonUp"));
            var sequences=packets.Select(p=>p.Sequence).ToArray(); Require(sequences.SequenceEqual(sequences.Order()),"Compact and critical input was reordered");
            var release=new InputPacket {Type="release",GroupID=group.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,Sequence=1}; await b.Manager.SendAsync(a.Id,"input",JsonSerializer.SerializeToUtf8Bytes(release,json));
            await Wait(()=>context.Invoke(()=>input.Pointer?.ScreenID==local.Id)); Require(context.Invoke(()=>input.Enabled),"Temporary release disabled sharing permanently");
            var latency=await a.Manager.TestLatencyAsync(b.Id); Require(latency.Length==1 && latency[0].Kind=="tcp" && latency[0].Values.Length>150,"10-second RTT echo test failed");
            Require(latency[0].Samples.All(s=>s.Seconds<10.1),"The diagnostics ran past their 10-second window");
        } finally {context.Invoke(()=> {input.Dispose();return true;});if(resolution) timeEndPeriod(1);}
    }
    private static async Task CheckContinuousMotion() {
        await using var a=new Fixture("MotionA"); await using var b=new Fixture("MotionB");
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret"); await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2);
        foreach(var manager in new[] {a.Manager,b.Manager}) {await manager.SetCapabilityAsync("compact-input",true);await manager.SetCapabilityAsync("input",true);}
        await Wait(()=>a.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("compact-input")));
        var group=a.Group.Active!; var packets=new ConcurrentQueue<InputPacket>();
        b.Manager.Receive("input",async (peer,bytes)=> {
            var packet=MotionCodec.Decode(bytes,group,peer,b.Id)??JsonSerializer.Deserialize<InputPacket>(bytes,json); if(packet is null) return; packets.Enqueue(packet);
            if(packet.Type=="move") await b.Manager.SendAsync(a.Id,"input",MotionCodec.Encode(new InputPacket {Type="motionAck",GroupID=group.Id,SourcePeerID=b.Id,TargetPeerID=a.Id,AcknowledgedSequence=packet.Sequence},group.Layout)!);
        });
        using var context=new FixtureInputContext(); var input=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{})); var resolution=timeBeginPeriod(1)==0;
        try {
            await context.Invoke(async()=> {input.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());await input.Enable();}); var local=group.Layout.Single(s=>s.PeerID==a.Id);
            context.Invoke(()=>input.Capture(new("move",DeltaX:8,ScreenID:local.Id,X:1,Y:.5))); await Task.Delay(30);var start=packets.Count;
            var until=Environment.TickCount64+1250;
            while(Environment.TickCount64<until) {context.Invoke(()=>input.Capture(new("move",DeltaX:.5,ScreenID:local.Id,X:1,Y:.5)));await Task.Delay(2);}
            await Task.Delay(30);var moving=packets.Skip(start).ToArray(); Require(moving.Count(p=>p.Type=="move")>100,"Continuous movement was not delivered");
            Require(!moving.Any(p=>p.Type is "pointer" or "held"),"Half-second repair interrupted continuous movement");
            await Wait(()=>packets.Skip(start).Any(p=>p.Type=="pointer"));
        } finally {context.Invoke(()=> {input.Dispose();return true;});if(resolution) timeEndPeriod(1);}
    }
    private static async Task CheckSlowLinkIsolation() {
        await using var a=new Fixture("LinkA"); await using var b=new Fixture("LinkB"); a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();var port=((IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();
        b.Manager.StartBluetoothListener(port);await a.Manager.ConnectAsync("127.0.0.1",port,"123456","fixture-secret",kind:"ble");
        var flags=System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance;
        var sessions=typeof(SessionManager).GetField("sessions",flags)!.GetValue(a.Manager)!;object?[] arguments=[b.Id,null];sessions.GetType().GetMethod("TryGetValue")!.Invoke(sessions,arguments);
        var links=(ConcurrentDictionary<string,ISessionTransport>)arguments[1]!.GetType().GetProperty("Links")!.GetValue(arguments[1])!;
        var slow=links["ble"];var gate=(SemaphoreSlim)typeof(SecureTcp).GetField("sendGate",flags)!.GetValue(slow)!;
        var delivered=new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);b.Manager.Receive("isolation",(_,_)=> {delivered.TrySetResult(true);return Task.CompletedTask;});
        await gate.WaitAsync();Task? heartbeat=null;
        try {
            heartbeat=(Task)typeof(SessionManager).GetMethod("SendFrame",flags)!.Invoke(a.Manager,["ping",b.Id,null,null,slow])!;
            Require(!heartbeat.IsCompleted,"The slow-link fault did not block the heartbeat");
            await a.Manager.SendAsync(b.Id,"isolation",[1]).WaitAsync(TimeSpan.FromMilliseconds(300));
            await delivered.Task.WaitAsync(TimeSpan.FromMilliseconds(300));Console.WriteLine("Slow-link regression: LAN frame delivered while BLE-tagged TLS stream remains blocked");
        } finally {gate.Release();if(heartbeat is not null) await heartbeat;}
    }
    private static async Task CheckMetadata() {
        var root=Path.Combine(Path.GetTempPath(),"ShareMouse-Metadata-"+Guid.NewGuid()); Directory.CreateDirectory(root);
        try {
            var source=Path.Combine(root,"source"); var destination=Path.Combine(root,"destination"); Directory.CreateDirectory(source);Directory.CreateDirectory(destination);
            foreach(var name in new[] {".DS_Store",".ShareMouse.xxxxxx",".keep-user-file","中文.txt"}) File.WriteAllText(Path.Combine(source,name),name);
            Directory.CreateDirectory(Path.Combine(source,".ShareMouse-"+Guid.NewGuid()));
            var (_,files)=await FileStorage.Scan([source]); Require(files.Select(f=>Path.GetFileName(f.Path)).Order().SequenceEqual(new[] {"source",".keep-user-file","中文.txt"}.Order()),"Transfer metadata filtering lost or included entries");
            var item=new FileItem(Guid.NewGuid().ToString("D"),Guid.NewGuid().ToString("D"),"中文.txt",false,4,0);
            var partial=FileStorage.Partial(destination,Guid.NewGuid().ToString("D"),item.Id);File.WriteAllBytes(partial,"data"u8.ToArray());
            Require(File.GetAttributes(Path.GetDirectoryName(partial)!).HasFlag(FileAttributes.Hidden),"Windows staging directory is visible as a delivered folder");
            var file=new TransferFile {Item=item,Provider="fixture",Target=FileStorage.Target(destination,item.RelativePath),Partial=partial}; FileStorage.Finish(file,destination);
            Require(!Directory.Exists(Path.GetDirectoryName(partial)),"Empty transfer staging folder remained");Require(File.ReadAllText(file.Target)=="data","Transferred file contents changed");
            Require(!File.GetAttributes(file.Target).HasFlag(FileAttributes.Hidden),"Final delivered file inherited staging's hidden flag");
        } finally {Directory.Delete(root,true);}
    }
    public static async Task CheckHistoryRealtime() {
        await using var a=new Fixture("HistoryA");await using var b=new Fixture("HistoryB");
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Online.Length==2&&b.Group.Online.Length==2&&a.Group.Active?.Id==b.Group.Active?.Id);
        using var context=new FixtureInputContext();
        var ha=context.Invoke(()=>new HistoryService(a.Id,a.Directory,a.Manager,context));var hb=context.Invoke(()=>new HistoryService(b.Id,b.Directory,b.Manager,context));
        try {
            await context.Invoke(()=>ha.Start());await context.Invoke(()=>hb.Start());
            context.Invoke(()=> {ha.Update(a.Group.Active,[a.Id,b.Id]);hb.Update(b.Group.Active,[a.Id,b.Id]);ha.ConfigurePopup(9,"right");hb.ConfigurePopup(3,"left");return true;});
            var text=string.Concat(Enumerable.Repeat("实时中文🙂/",8000));
            context.Invoke(()=> {ha.Remember(text);return true;});await Wait(()=>context.Invoke(()=>hb.Entries.Any(e=>e.Text==text)));
            context.Invoke(()=> {hb.Remember("来自另一端的文本",favorite:true);return true;});await Wait(()=>context.Invoke(()=>ha.Entries.Any(e=>e.Text=="来自另一端的文本"&&e.Favorite)));
            context.Invoke(()=> {Require(ha.Entries.Count(e=>e.Text==text)==1&&hb.Entries.Count(e=>e.Text==text)==1,"Realtime sync duplicated records");ha.Update(a.Group.Active,[a.Id]);hb.Update(b.Group.Active,[b.Id]);ha.Remember("离线 A");hb.Remember("离线 B");return true;});
            context.Invoke(()=> {Require(!hb.Entries.Any(e=>e.Text=="离线 A")&&!ha.Entries.Any(e=>e.Text=="离线 B"),"Offline histories leaked before reconnect");ha.Update(a.Group.Active,[a.Id,b.Id]);hb.Update(b.Group.Active,[a.Id,b.Id]);return true;});
            await Wait(()=>context.Invoke(()=>ha.Entries.Any(e=>e.Text=="离线 B")&&hb.Entries.Any(e=>e.Text=="离线 A")));
            context.Invoke(()=> {hb.Dispose();using var restored=new HistoryService(b.Id,b.Directory,b.Manager,context);Require(restored.VisibleCount==3&&restored.PreferredSide=="left"&&ha.VisibleCount==9,"Remote history overwrote local display settings");Require(restored.Entries.Any(e=>e.Text==text),"Restart lost synchronized text");return true;});
            Console.WriteLine("PASS: encrypted bidirectional realtime long-text history, offline/reconnect merge, dedupe and independent persisted display settings");
        } finally {context.Invoke(()=> {ha.Dispose();hb.Dispose();return true;});}
    }
    private static async Task CheckDirectoryStagingAndConflictFinish() {
        await using var a=new Fixture("A"); await using var b=new Fixture("B");
        a.Group.Start(); b.Group.Start(); a.Manager.Start(a.Port); b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2 && a.Group.Active?.Id==b.Group.Active?.Id);
        using var context=new FixtureInputContext(); var decision="overwrite";
        var ca=context.Invoke(()=>new ClipboardService(a.Id,a.Manager,context,_=>{},a.Directory));
        var cb=context.Invoke(()=>new ClipboardService(b.Id,b.Manager,context,_=>{},b.Directory));
        FileTransferService Service(Fixture fixture,ClipboardService clipboard)=>new(fixture.Id,fixture.Directory,fixture.Manager,clipboard,context,Console.WriteLine,
            _=>Task.FromResult(false),(_,_,_)=>Task.FromResult(decision),_=>Task.FromResult("abort"),_=>Task.FromResult(false));
        var fa=context.Invoke(()=>Service(a,ca)); var fb=context.Invoke(()=>Service(b,cb));
        try {
            context.Invoke(()=> { ca.Update(a.Group.Active,[a.Id,b.Id]); cb.Update(a.Group.Active,[a.Id,b.Id]); fa.Update(a.Group.Active,[a.Id,b.Id],a.Manager.CurrentSessions()); fb.Update(a.Group.Active,[a.Id,b.Id],b.Manager.CurrentSessions()); return true; });
            await context.Invoke(()=>ca.Start()); await context.Invoke(()=>cb.Start()); await context.Invoke(()=>fa.Start()); await context.Invoke(()=>fb.Start());
            var source=Path.Combine(a.Directory,"selected"); var target=Path.Combine(b.Directory,"target"); Directory.CreateDirectory(source); Directory.CreateDirectory(target);
            foreach(var name in new[]{"one.txt","中文.txt","empty.txt"}) File.WriteAllText(Path.Combine(source,name),name=="empty.txt"?"":name);
            var binary=Path.Combine(source,"binary.apk"); File.WriteAllBytes(binary,Enumerable.Repeat((byte)0xff,2*1024*1024).ToArray());
            await context.Invoke(()=>fa.Copy([source],false)); await Wait(()=>context.Invoke(()=>cb.Current?.Id==ca.Current?.Id));
            var first=await context.Invoke(()=>fb.Paste(target));
            Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==first).State)=="completed","Directory transfer failed after first staging file");
            Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==first).Transport)=="tcp","Transfer display did not report the actual data link");
            foreach(var name in new[]{"one.txt","中文.txt","empty.txt","binary.apk"}) Require(File.ReadAllBytes(Path.Combine(target,"selected",name)).SequenceEqual(File.ReadAllBytes(Path.Combine(source,name))),"Multi-file contents differ");
            context.Invoke(()=> {fa.Dispose();return true;});
            var record=Path.Combine(a.Directory,"file-transfers.json");
            var saved=JsonSerializer.Deserialize<FileTransferStore>(File.ReadAllText(record),json)!;
            var legacy=saved.Tasks.Single(t=>t.Id==first);legacy.State="paused";legacy.PausedBy=null;
            File.WriteAllText(record,JsonSerializer.Serialize(saved,json));
            fa=context.Invoke(()=>Service(a,ca));
            context.Invoke(()=> {fa.Update(a.Group.Active,[a.Id,b.Id],a.Manager.CurrentSessions());return true;});
            await context.Invoke(()=>fa.Start());
            var received=context.Invoke(()=>fb.Tasks.Single(t=>t.Id==first).Files.Single(f=>f.Item.RelativePath=="selected/binary.apk"));
            context.Invoke(()=> {received.Completed=false;received.Received=20000;received.Partial=FileStorage.Partial(target,first,received.Item.Id);File.WriteAllBytes(received.Partial,Enumerable.Repeat((byte)0xff,20000).ToArray());return true;});
            await context.Invoke(()=>fb.Resume(first));
            Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==first).State)=="completed","Partial resume after legacy sender shutdown failed");
            await Wait(()=>context.Invoke(()=>fa.Tasks.Single(t=>t.Id==first).State=="completed"));
            Require(await FileStorage.Hash(received.Target)==received.Item.Hash,"Resumed binary file hash differs");
            Require(!Directory.EnumerateDirectories(target,".ShareMouse-*").Any(),"Resumed file left staging directory");
            Console.WriteLine("PASS: dense binary APK, partial resume after legacy sender shutdown, final SHA256 and staging cleanup");
            context.Invoke(()=> {File.Delete(received.Target);received.Completed=false;received.Received=20000;Require(!File.Exists(received.Partial),"Missing partial fixture still exists");return true;});
            await context.Invoke(()=>fb.Resume(first));
            Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==first).State)=="completed","Missing partial data did not restart from zero on the first retry");
            await Wait(()=>context.Invoke(()=>fa.Tasks.Single(t=>t.Id==first).State=="completed"));
            Require(await FileStorage.Hash(received.Target)==received.Item.Hash,"File restarted after lost staging differs");
            Console.WriteLine("PASS: missing partial data resets saved progress; first retry produces the complete original file");
            foreach(var action in new[]{"cancel","skip"}) {
                context.Invoke(()=> {decision=action; return true;}); var taskID=await context.Invoke(()=>fb.Paste(target)); var expected=action=="cancel"?"cancelled":"completed";
                Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==taskID).State)==expected,"Conflict result differs");
                await Wait(()=>context.Invoke(()=>fa.Tasks.Single(t=>t.Id==taskID).State==expected));
            }
            Console.WriteLine("PASS: encrypted multi-file directory, empty file, staging recreation and sender completion after early cancel/skip");
        } finally { context.Invoke(()=> {fa.Dispose();fb.Dispose();ca.Dispose();cb.Dispose();return true;}); }
    }
    public static async Task CheckAcceptanceFeedback() {
        CheckScrollShortcutAndNativeGeometry();
        await CheckSingleSideResumeAndScroll();
        var legacy=JsonSerializer.Deserialize<ScreenGeometry>("{\"id\":\"a\",\"peerID\":\"a\",\"name\":\"A\",\"number\":1,\"pixelWidth\":1000,\"pixelHeight\":500,\"primary\":true,\"x\":0,\"y\":0,\"scale\":1.25}",json)!;
        Require(legacy.Width==1250&&legacy.Height==625,"Legacy layout changed");
        foreach(var angle in new[]{0,90,180,270}) {var screen=legacy with {Rotation=angle,ScaleX=1.5,ScaleY=.75};var position=screen.Logical(.3,.7);var native=screen.Native(position.X,position.Y);Require(Math.Abs(native.X-.3)<.00001&&Math.Abs(native.Y-.7)<.00001,"Rotated pointer mapping does not round trip");Require(JsonSerializer.Deserialize<ScreenGeometry>(JsonSerializer.Serialize(screen,json),json)==screen,"Layout fields lost in JSON");}
        var simple=legacy with {Scale=1};var stretched=ScreenGeometry.Resize(simple,200,300,"se",false,[]);Require(stretched.Width==1200&&stretched.Height==800,"Independent resize failed");
        var locked=ScreenGeometry.Resize(simple,-200,700,"nw",true,[]);Require(Math.Abs(locked.Width/locked.Height-2)<.0001&&locked.X+locked.Width==1000&&locked.Y+locked.Height==500,"Ratio or opposite anchor changed");
        var neighbor=simple with {Id="b",X=1500,Y=750};var snapped=ScreenGeometry.Resize(simple,495,245,"se",false,[neighbor],10);Require(snapped.Width==1500&&snapped.Height==750,"Resize snapping failed");
        var ratioSnap=ScreenGeometry.Resize(simple,495,200,"se",true,[neighbor],10);Require(ratioSnap.Width==1500&&ratioSnap.Height==750,"Shift resize did not snap with ratio preserved");
        Require(!ScreenGeometry.ValidLayout([simple with {Rotation=45}]),"Invalid rotation accepted");
        await using var a=new Fixture("AdditionsA");await using var b=new Fixture("AdditionsB");a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Online.Length==2&&b.Group.Online.Length==2&&a.Group.Active?.Id==b.Group.Active?.Id);
        using var context=new FixtureInputContext();var decision="exclude";var prompts=0;
        var ca=context.Invoke(()=>new ClipboardService(a.Id,a.Manager,context,_=>{},a.Directory));var cb=context.Invoke(()=>new ClipboardService(b.Id,b.Manager,context,_=>{},b.Directory));
        FileTransferService Service(Fixture fixture,ClipboardService clip)=>new(fixture.Id,fixture.Directory,fixture.Manager,clip,context,Console.WriteLine,_=>Task.FromResult(false),(_,_,_)=>Task.FromResult("overwrite"),_=>Task.FromResult("abort"),_=>Task.FromResult(false),paths=> {prompts++;Require(paths.Any(p=>p.EndsWith("/new.txt",StringComparison.Ordinal)),"New descendant missing from prompt");return Task.FromResult(decision);});
        var fa=context.Invoke(()=>Service(a,ca));var fb=context.Invoke(()=>Service(b,cb));
        try {
            context.Invoke(()=> {ca.Update(a.Group.Active,[a.Id,b.Id]);cb.Update(a.Group.Active,[a.Id,b.Id]);fa.Update(a.Group.Active,[a.Id,b.Id],a.Manager.CurrentSessions());fb.Update(a.Group.Active,[a.Id,b.Id],b.Manager.CurrentSessions());return true;});
            await context.Invoke(()=>ca.Start());await context.Invoke(()=>cb.Start());await context.Invoke(()=>fa.Start());await context.Invoke(()=>fb.Start());
            foreach(var reverse in new[]{false,true}) {
                var origin=reverse?b:a;var target=reverse?a:b;var sender=reverse?fb:fa;var receiver=reverse?fa:fb;
                var source=Path.Combine(origin.Directory,"selected-"+reverse);var destination=Path.Combine(target.Directory,"received-"+reverse);Directory.CreateDirectory(source);Directory.CreateDirectory(destination);File.WriteAllText(Path.Combine(source,"old.txt"),"old");
                await context.Invoke(()=>sender.Copy([source],true));await Wait(()=>context.Invoke(()=>ca.Current?.Id==cb.Current?.Id));
                var moved=await context.Invoke(()=>receiver.Paste(destination));Require(context.Invoke(()=>receiver.Tasks.Single(t=>t.Id==moved).State)=="completed","Initial directory Cut failed");await Wait(()=>!Directory.Exists(source));
                var provider=Path.Combine(destination,Path.GetFileName(source));Directory.CreateDirectory(Path.Combine(provider,"nested"));File.WriteAllText(Path.Combine(provider,"nested","new.txt"),"new");
                foreach(var action in new[]{"exclude","cancel","include"}) {
                    var before=context.Invoke(()=> {decision=action;return prompts;});var output=Path.Combine(origin.Directory,action+reverse);Directory.CreateDirectory(output);
                    var pasted=await context.Invoke(()=>sender.Paste(output));Require(context.Invoke(()=>sender.Tasks.Single(t=>t.Id==pasted).State)==(action=="cancel"?"cancelled":"completed"),"Addition decision result differs");await Wait(()=>context.Invoke(()=>receiver.Tasks.Single(t=>t.Id==pasted).State)==(action=="cancel"?"cancelled":"completed"));Require(context.Invoke(()=>prompts)==before+1,"Addition prompt missing or repeated");
                    Require(File.Exists(Path.Combine(output,Path.GetFileName(source),"nested","new.txt"))==(action=="include"),"Addition selection was ignored");if(action=="cancel") Require(!Directory.EnumerateFileSystemEntries(output).Any(),"Cancel created target files");Require(File.Exists(Path.Combine(provider,"nested","new.txt")),"Repeated Cut paste deleted the completed provider");
                }
            }
            Console.WriteLine("PASS: compatible layout JSON, four rotations, independent/Shift resize, opposite anchors and edge snapping; TLS directory Cut additions include/exclude/cancel both directions, completed providers retained.");
        } finally {context.Invoke(()=> {fa.Dispose();fb.Dispose();ca.Dispose();cb.Dispose();return true;});}
    }
    private static void CheckWireVector() {
        const string source="66666666-7777-8888-9999-aaaaaaaaaaaa",target="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",id="11111111-2222-3333-4444-555555555555";
        var screen=new ScreenGeometry("screen-一",target,"Screen",1,1000,1000,true,0,0);var group=new SharedGroup(id,"Fixture",source,1,[],[screen],[],"");
        var packet=new InputPacket {Type="move",GroupID=id,SourcePeerID=source,TargetPeerID=target,Sequence=123,Pointer=new(screen.Id,40.5,20.25,source,9)};
        var bytes=MotionCodec.Encode(packet,group.Layout)!;Require(Convert.ToHexString(bytes).ToLowerInvariant()=="534d493111111111222233334444555555555555000000000000007b0000000000000009000a73637265656e2de4b8804222000041a20000","Swift/C# wire vector differs");
        Require(MotionCodec.Decode(bytes,group,source,target)?.Pointer==packet.Pointer,"Compact pointer did not round trip");
        var frame=new SessionMessage {Type="data",SourcePeerID=source,TargetPeerID=target,SessionID=id,Sequence=44,Channel="input",Payload=bytes};var compact=SessionFrameCodec.Encode(frame);var decoded=SessionFrameCodec.Decode(compact);
        Require(compact.Length==bytes.Length+28 && decoded.SessionID==id && decoded.Sequence==44 && decoded.Payload!.SequenceEqual(bytes),"Compact session envelope differs");
    }
    private static void CheckScrollShortcutAndNativeGeometry() {
        const string source="66666666-7777-8888-9999-aaaaaaaaaaaa",target="bbbbbbbb-cccc-dddd-eeee-ffffffffffff",id="11111111-2222-3333-4444-555555555555";
        var screen=new ScreenGeometry("screen-一",target,"Screen",1,1000,1000,true,0,0);var group=new SharedGroup(id,"Fixture",source,1,[],[screen],[],"");
        var packet=new InputPacket {Type="scroll",GroupID=id,SourcePeerID=source,TargetPeerID=target,Sequence=123,Pointer=new(screen.Id,40.5,20.25,source,9),DeltaX=1.5,DeltaY=-2.25,ScrollPhase=2,MomentumPhase=3,PreciseScroll=true};
        Require(MotionCodec.Encode(packet,group.Layout) is null,"Old peers must retain JSON scroll");
        var bytes=MotionCodec.Encode(packet,group.Layout,compactScroll:true)!;
        Require(Convert.ToHexString(bytes).ToLowerInvariant()=="534d533111111111222233334444555555555555000000000000007b0000000000000009000a73637265656e2de4b8804222000041a200003fc00000c01000000002000301","Swift/C# scroll wire vector differs");
        var decoded=MotionCodec.Decode(bytes,group,source,target)!;
        Require(decoded.DeltaX==1.5 && decoded.DeltaY==-2.25 && decoded.ScrollPhase==2 && decoded.MomentumPhase==3 && decoded.PreciseScroll==true,"Scroll phases or precision lost");
        var invalid=bytes.ToArray();invalid[^1]=2;Require(MotionCodec.Decode(invalid,group,source,target) is null && MotionCodec.Decode(bytes[..^1],group,source,target) is null,"Malformed scroll accepted");
        packet.DeltaY=10001;Require(MotionCodec.Encode(packet,group.Layout,compactScroll:true) is null,"Oversized scroll accepted");
        var primary=new ScreenGeometry("main","a","Retina",1,2000,1000,true,900,600);var right=new ScreenGeometry("external","a","External",2,1000,1000,false,2900,800);
        var sizes=new Dictionary<string,(double Width,double Height)> {["main"]=(1000,500),["external"]=(1920,1080)};
        var plan=ScreenGeometry.NativeLayout([primary,right],sizes)!;Require(plan[0].X==0 && plan[0].Y==0 && plan[1].X==1000 && plan[1].Y==100,"Mixed DPI native origins differ");
        var negative=ScreenGeometry.NativeLayout([primary,right with {X=-100}],sizes)!;Require(negative[1].X==-1920 && negative[1].Y==100,"Negative monitor position lost");
        var a=new ScreenGeometry("a1","a","A",1,1000,500,true,0,0);var b=a with {Id="b",PeerID="b",X=1000};var a2=a with {Id="a2",Primary=false,X=2000};
        Require(!ScreenGeometry.ValidLayout([a,b,a2]) && ScreenGeometry.ValidLayout([a,a2 with {X=1000},b with {X=2000}]),"One computer's displays must stay connected");
        var shortcut=new SharingShortcut();var enabled=true;var toggles=0;shortcut.Toggle=()=>{enabled=!enabled;toggles++;};
        foreach(var key in new[]{"ControlLeft","AltRight","ShiftLeft"})shortcut.Capture(new("keyDown",key));
        Require(shortcut.Capture(new("keyDown","Escape")) && !enabled,"Shortcut did not pause");for(var i=0;i<10;i++)shortcut.Capture(new("keyDown","Escape"));Require(toggles==1,"Held shortcut repeated");
        shortcut.Capture(new("keyUp","Escape"));Require(shortcut.Capture(new("keyDown","Escape")) && enabled && toggles==2,"Same shortcut must reconnect while paused");
        shortcut.Reset();Require(!shortcut.Capture(new("keyDown","Escape")),"MCP suspension must clear remembered modifiers");
    }
    private static async Task CheckSingleSideResumeAndScroll() {
        await using var a=new Fixture("ResumeA");await using var b=new Fixture("ResumeB");
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2 && a.Group.Active?.Id==b.Group.Active?.Id);
        using var context=new FixtureInputContext();var delivered=new List<CapturedInput>();var resumes=0;var group=a.Group.Active!;
        var sa=context.Invoke(()=>new InputService(a.Id,"windows",a.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{}));
        var sb=context.Invoke(()=>new InputService(b.Id,"macos",b.Manager,context,(value,_,_,_)=>delivered.Add(value),(_,_)=>{},_=>{}));
        try {
            context.Invoke(()=>{sa.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());sb.Update(group,[a.Id,b.Id],b.Manager.CurrentSessions());return true;});
            await context.Invoke(()=>sa.Enable());await context.Invoke(()=>sb.Enable());
            await Wait(()=>a.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("input")) && b.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("input")));
            var original=a.Manager.CurrentSessions().Single().SessionID;
            context.Invoke(()=>{sa.Pause();sb.Pause();sb.ResumeRequested=()=>{resumes++;_=sb.Enable();};return true;});
            await Wait(()=>a.Manager.CurrentSessions().All(s=>!s.Capabilities.Contains("input")) && b.Manager.CurrentSessions().All(s=>!s.Capabilities.Contains("input")));
            await context.Invoke(()=>sa.Enable());context.Invoke(()=>{sa.RequestPeerResume();return true;});
            await Wait(()=>context.Invoke(()=>sb.Enabled && resumes==1) && a.Manager.CurrentSessions().Any(s=>s.Capabilities.Contains("input")));
            context.Invoke(()=>{sa.Update(group,[a.Id,b.Id],a.Manager.CurrentSessions());sb.Update(group,[a.Id,b.Id],b.Manager.CurrentSessions());return true;});
            var local=group.Layout.Single(s=>s.PeerID==a.Id);context.Invoke(()=>sa.Capture(new("move",DeltaX:8,ScreenID:local.Id,X:1,Y:.5)));await Task.Delay(30);
            context.Invoke(()=>{delivered.Clear();for(var i=0;i<250;i++)Require(sa.Capture(new("scroll",DeltaY:1,ScrollPhase:2,MomentumPhase:0,PreciseScroll:true)),"Scroll did not route to remote screen");sa.Capture(new("buttonDown"));sa.Capture(new("buttonUp"));return true;});
            await Wait(()=>context.Invoke(()=>delivered.Any(e=>e.Type=="buttonUp")));
            context.Invoke(()=>{var scroll=delivered.Where(e=>e.Type=="scroll").ToArray();Require(scroll.Length<10 && Math.Abs(scroll.Sum(e=>e.DeltaY)-250)<.001,"Scroll burst accumulated or lost fresh deltas");Require(delivered.FindIndex(e=>e.Type=="scroll")<delivered.FindIndex(e=>e.Type=="buttonDown"),"Click overtook scroll");return true;});
            Require(a.Manager.CurrentSessions().Length==1 && a.Manager.CurrentSessions().Single().SessionID==original,"Input resume replaced or duplicated the paired session");
        } finally {context.Invoke(()=>{sa.Dispose();sb.Dispose();return true;});}
    }
    private static async Task CheckConflictApplyAll() {
        await using var a=new Fixture("ConflictA");await using var b=new Fixture("ConflictB");a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Online.Length==2 && b.Group.Online.Length==2 && a.Group.Active?.Id==b.Group.Active?.Id);
        using var context=new FixtureInputContext();var decision="overwrite:all";var prompts=0;
        var ca=context.Invoke(()=>new ClipboardService(a.Id,a.Manager,context,_=>{},a.Directory));var cb=context.Invoke(()=>new ClipboardService(b.Id,b.Manager,context,_=>{},b.Directory));
        FileTransferService Service(Fixture fixture,ClipboardService clip)=>new(fixture.Id,fixture.Directory,fixture.Manager,clip,context,_=>{},_=>Task.FromResult(false),(_,_,_)=>{prompts++;return Task.FromResult(decision);},_=>Task.FromResult("abort"),_=>Task.FromResult(false));
        var fa=context.Invoke(()=>Service(a,ca));var fb=context.Invoke(()=>Service(b,cb));
        try {
            context.Invoke(()=>{ca.Update(a.Group.Active,[a.Id,b.Id]);cb.Update(a.Group.Active,[a.Id,b.Id]);fa.Update(a.Group.Active,[a.Id,b.Id],a.Manager.CurrentSessions());fb.Update(a.Group.Active,[a.Id,b.Id],b.Manager.CurrentSessions());return true;});
            await context.Invoke(()=>ca.Start());await context.Invoke(()=>cb.Start());await context.Invoke(()=>fa.Start());await context.Invoke(()=>fb.Start());
            var target=Path.Combine(b.Directory,"target");Directory.CreateDirectory(target);var paths=new[]{"one.txt","two.txt","three.txt"}.Select(n=>Path.Combine(a.Directory,n)).ToArray();
            foreach(var path in paths){File.WriteAllText(path,"new");File.WriteAllText(Path.Combine(target,Path.GetFileName(path)),"old");}
            await context.Invoke(()=>fa.Copy(paths,false));await Wait(()=>context.Invoke(()=>cb.Current?.Id==ca.Current?.Id));
            var first=await context.Invoke(()=>fb.Paste(target));Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==first).State=="completed" && prompts==1),"Apply all must prompt once per transfer");
            foreach(var path in paths)Require(File.ReadAllText(Path.Combine(target,Path.GetFileName(path)))=="new","Overwrite failed");
            context.Invoke(()=>{decision="skip:all";return true;});var second=await context.Invoke(()=>fb.Paste(target));Require(context.Invoke(()=>fb.Tasks.Single(t=>t.Id==second).State=="completed" && prompts==2),"A later paste reused the previous conflict rule");
        } finally {context.Invoke(()=>{fa.Dispose();fb.Dispose();ca.Dispose();cb.Dispose();return true;});}
    }
    private static void Require(bool value,string message) { if(!value) throw new InvalidOperationException(message); }
    private static async Task Wait(Func<bool> ready) {
        var deadline=DateTime.UtcNow.AddSeconds(12); while(!ready()) { if(DateTime.UtcNow>=deadline) throw new TimeoutException("Sharing regression condition timed out"); await Task.Delay(20); }
    }
    private sealed class UnpumpedContext:SynchronizationContext {
        public int Posted;
        public override void Post(SendOrPostCallback d,object? state){Interlocked.Increment(ref Posted);}
    }
    public static async Task CheckBleTransportContext() {
        var stalled=new UnpumpedContext();var previous=SynchronizationContext.Current;object bridge;int port;
        var forwarded=new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        Func<byte[],Task> forward=bytes=>{forwarded.TrySetResult(bytes);return Task.CompletedTask;};
        var type=typeof(SessionManager).Assembly.GetType("ShareMouse.Network.BleByteBridge",true)!;
        try{SynchronizationContext.SetSynchronizationContext(stalled);bridge=Activator.CreateInstance(type,new object[]{forward,(Action)(()=>{}),(Action<string>)(_=>{})})!;port=(int)type.GetMethod("Listen")!.Invoke(bridge,null)!;}finally{SynchronizationContext.SetSynchronizationContext(previous);}
        try{
            using var socket=new System.Net.Sockets.TcpClient();await socket.ConnectAsync("127.0.0.1",port).ConfigureAwait(false);var bytes=Enumerable.Repeat((byte)0xa5,257).ToArray();await socket.GetStream().WriteAsync(bytes).ConfigureAwait(false);
            var result=await forwarded.Task.WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);Require(result.Length>0&&result.All(b=>b==0xa5),"BLE bridge forwarding failed");Require(stalled.Posted==0,"BLE bridge captured UI context");
            Console.WriteLine("PASS: BLE framing forwards while the creating UI context is deliberately unpumped");
        }finally{((IDisposable)bridge).Dispose();}
    }
    public static async Task CheckLinkSpeed() {
        await CheckBulkPriority();
        await using var a=new Fixture("SpeedA");await using var b=new Fixture("SpeedB");
        b.Manager.StartBluetoothListener(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret",kind:"ble");
        var delivered=0;var control=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        b.Manager.Receive("background-qa",async(_,_)=>{await Task.Delay(80);Interlocked.Increment(ref delivered);});
        b.Manager.Receive("input",(_,_)=>{control.TrySetResult();return Task.CompletedTask;});
        var work=Task.WhenAll(Enumerable.Range(0,10).Select(n=>a.Manager.SendBackgroundAsync(b.Id,"background-qa",Enumerable.Repeat((byte)n,128).ToArray())));
        await Task.Delay(20);await a.Manager.SendAsync(b.Id,"input",System.Text.Encoding.UTF8.GetBytes("responsive"));await control.Task.WaitAsync(TimeSpan.FromSeconds(3));Require(Volatile.Read(ref delivered)<10,"Background queued ahead of input");await work;Require(delivered==10,"Background transfer lost a packet");
        var port=Random.Shared.Next(45000,48000);b.Manager.Start(port);await a.Manager.ConnectAsync("127.0.0.1",port,null,null);
        var results=await a.Manager.TestThroughputAsync(b.Id);Require(results.Select(r=>r.Kind).Order().SequenceEqual(new[]{"ble","tcp"})&&results.All(r=>r.Bytes>0&&r.Seconds>0&&r.Error is null),"Throughput did not use confirmed bytes on both links");Require(results.First(r=>r.Kind=="ble").Bytes<=65536,"BLE test exceeded byte budget");
        var policy=new InputRoutePolicy();for(var i=0;i<4;i++){policy.Observe("quic",30,i);policy.Observe("tcp",1,i);}Require(policy.Choose(new[]{"quic","tcp"},false,0)=="quic"&&policy.Choose(new[]{"quic","tcp"},false,12)=="quic","Available QUIC was replaced by TCP");
        Console.WriteLine("PASS: authenticated receiver-confirmed TCP/BLE speed measurement, byte budget, background fairness, QUIC/UDP input priority");
    }
    public static async Task CheckInputAckRoute() {
        await using var a=new Fixture("AckA",bluetoothInputOnly:true);await using var b=new Fixture("AckB",bluetoothInputOnly:false);
        a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);
        await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Online.Length==2&&b.Group.Online.Length==2&&a.Group.Active?.Id==b.Group.Active?.Id);
        var port=Random.Shared.Next(45000,48000);b.Manager.StartBluetoothListener(port);await a.Manager.ConnectAsync("127.0.0.1",port,null,null,kind:"ble");
        await a.Manager.SetCapabilitiesAsync(new Dictionary<string,bool>{{"input",true},{"compact-input",true},{"compact-input-v3",true},{"scroll-flow-v1",true}});
        using var context=new FixtureInputContext();var input=context.Invoke(()=>new InputService(b.Id,"windows",b.Manager,context,(_,_,_,_)=>{},(_,_)=>{},_=>{}));
        context.Invoke(()=>{input.Update(a.Group.Active,[a.Id,b.Id],b.Manager.CurrentSessions());return true;});await context.Invoke(()=>input.Enable());
        await Wait(()=>b.Manager.CurrentSessions().Single().Capabilities.Contains("compact-input-v3"));
        context.Invoke(()=>{input.Update(a.Group.Active,[a.Id,b.Id],b.Manager.CurrentSessions());return true;});await Task.Delay(150);
        var group=a.Group.Active!;var screen=group.Layout.Single(s=>s.PeerID==b.Id);var point=new PointerState(screen.Id,screen.X+50,screen.Y+50,a.Id,100);
        var json=new System.Text.Json.JsonSerializerOptions{PropertyNamingPolicy=System.Text.Json.JsonNamingPolicy.CamelCase};
        var flags=System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance;
        ISessionTransport Link(SessionManager manager,string peer,string kind){var table=typeof(SessionManager).GetField("sessions",flags)!.GetValue(manager)!;object?[] values=[peer,null];table.GetType().GetMethod("TryGetValue")!.Invoke(table,values);return ((ConcurrentDictionary<string,ISessionTransport>)values[1]!.GetType().GetProperty("Links")!.GetValue(values[1])!)[kind];}
        var tcp=Link(b.Manager,a.Id,"tcp");var gate=(SemaphoreSlim)typeof(SecureTcp).GetField("sendGate",flags)!.GetValue(tcp)!;
        var ack=new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        a.Manager.ReceiveWithTransport("input",(_,bytes,link)=>{var packet=MotionCodec.Decode(bytes,group,b.Id,a.Id);if(packet?.Type=="motionAck"&&packet.AcknowledgedSequence>=102)ack.TrySetResult(link.Kind);return Task.CompletedTask;});
        await gate.WaitAsync();
        try {
            await a.Manager.SendOnTransportAsync(b.Id,"input",System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new InputPacket{Type="control",GroupID=group.Id,SourcePeerID=a.Id,TargetPeerID=b.Id,Sequence=101,Pointer=point},json),Link(a.Manager,b.Id,"ble"));
            var move=new InputPacket{Type="move",GroupID=group.Id,SourcePeerID=a.Id,TargetPeerID=b.Id,Sequence=102,Pointer=point with{X=point.X+1}};
            await a.Manager.SendOnTransportAsync(b.Id,"input",MotionCodec.Encode(move,group.Layout,compactContext:true)!,Link(a.Manager,b.Id,"ble"));
            Require(await ack.Task.WaitAsync(TimeSpan.FromMilliseconds(600))=="ble","BLE input ACK waited on the blocked network stream");
            Console.WriteLine("PASS: actual InputService BLE ACK returns on ingress BLE while receiver prefers network and its TCP stream is blocked");
        }finally{gate.Release();context.Invoke(()=>{input.Dispose();return true;});}
    }
    public static async Task CheckFileWindow() {
        var policy=new FileWindowPolicy();Require(policy.Window(0)==8,"Idle file window");
        for(var i=0;i<8;i++)policy.Observe("quic",80,i*.01);
        Require(policy.Window(.08)==2,"Initial input tail did not shrink window");
        policy.Congested(.1);Require(policy.Window(.11)==2,"Duplicate congestion repeatedly halved");
        for(var i=0;i<64;i++)policy.Observe("quic",10,1.2+i*.01);
        Require(policy.Window(1.85)>2,"Healthy input did not recover throughput");
        policy.RemoteLimit(1,100,2);policy.RemoteLimit(8,99,2.1);policy.RemoteLimit(0,101,2.2);
        Require(policy.Window(2.2)==1&&policy.Window(5.1)>1,"Stale or invalid peer hint or expiry");
        var request=new FilePacket{Type="chunk",GroupID="g",EntryID="e",TaskID="t",Offset=123,MaximumBytes=256};
        foreach(var compact in new[]{false,true})Require(FilePacketCodec.Decode(FilePacketCodec.Encode(request,compact),compact).MaximumBytes==256,"Requested range lost in codec");
        await using var a=new Fixture("WindowA");await using var b=new Fixture("WindowB");
        b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");
        Require(a.Manager.HasCapability(b.Id,"adaptive-file-window-v1"),"File window capability negotiation");
        a.Manager.YieldBulkForInput(b.Id);Require(a.Manager.FileTransferWindow(b.Id).Count==4,"Local pressure ignored");
        await Wait(()=>b.Manager.FileTransferWindow(a.Id).Count==4);
        await Task.Delay(600);a.Manager.YieldBulkForInput(b.Id);
        await Wait(()=>b.Manager.FileTransferWindow(a.Id).Count==2);
        await b.Manager.SetCapabilityAsync("adaptive-file-window-v1",false);
        await Wait(()=>!a.Manager.HasCapability(b.Id,"adaptive-file-window-v1"));
        await a.Manager.SendAsync(b.Id,"input",[0]);Require(a.Manager.FileTransferWindow(b.Id).Count==2,"Legacy peer did not retain conservative active window");
        await using var source=new Fixture("TailA");await using var target=new Fixture("TailB");
        target.Manager.Start(target.Port);await source.Manager.ConnectAsync("127.0.0.1",target.Port,"123456","fixture-secret");
        var acknowledged=0;
        target.Manager.ReceiveWithTransport("input",async(peer,bytes,link)=>{await Task.Delay(80);await target.Manager.SendOnTransportAsync(peer,"input",bytes,link);});
        source.Manager.ReceiveWithTransport("input",(peer,bytes,link)=>{source.Manager.InputAcknowledged(peer,bytes[0],link);Interlocked.Increment(ref acknowledged);return Task.CompletedTask;});
        for(var seq=1;seq<=8;seq++){await source.Manager.SendInputAsync(target.Id,[(byte)seq],(ulong)seq);await Wait(()=>Volatile.Read(ref acknowledged)==seq);}
        Require(source.Manager.FileTransferWindow(target.Id).Count<=2,"Actual confirmed input tail ignored");
        await Wait(()=>target.Manager.FileTransferWindow(source.Id).Count<=2);
        Console.WriteLine("PASS: tail shrink/recovery, peer TTL/sequence, chunk request range, encrypted peer window propagation, legacy fallback");
    }
    private static async Task CheckBulkPriority() {
        const string id="11111111-2222-3333-4444-555555555555";
        var rawData=Enumerable.Repeat((byte)255,32000).ToArray();
        var packet=new FilePacket{Type="chunk-data",GroupID=id,EntryID=id,TaskID=id,RequestID=id,ItemID=id,Index=0,Final=true,Offset=123,Checksum=ChunkCheck.Adler32(rawData),Data=rawData};
        var raw=FilePacketCodec.Encode(packet,true);var back=FilePacketCodec.Decode(raw,true);
        Require(raw.Length==32096&&back.Data!.SequenceEqual(rawData)&&back.Offset==123&&back.Checksum==packet.Checksum,"Compact file changed bytes or offset");
        try{FilePacketCodec.Decode(raw,false);throw new Exception("Unnegotiated file codec accepted");}catch(InvalidDataException){}
        var frame=new SessionMessage{Type="data",SourcePeerID=id,Sequence=44,Channel="files",Mode="compact-data-v1",DeliveryID=id,Payload=[0,255,128]};
        var bytes=SessionFrameCodec.Encode(frame);Require(Convert.ToHexString(bytes).ToLowerInvariant()=="534c4431000000000000002c050166696c65731111111122223333444455555555555500ff80","Swift/C# raw frame vector differs");
        var decoded=SessionFrameCodec.Decode(bytes);Require(decoded.Payload!.SequenceEqual(frame.Payload)&&decoded.DeliveryID==id,"Compact data roundtrip failed");
        var parts=BulkFrameCodec.Fragments("files",rawData,160);var assembly=new Dictionary<Guid,BulkFrameCodec.Assembly>();
        try{BulkFrameCodec.Consume(parts[1],assembly);throw new Exception("Out of order accepted");}catch(InvalidDataException){}
        (string Channel,byte[] Payload)? result=null;foreach(var part in parts)result=BulkFrameCodec.Consume(part,assembly);Require(result?.Channel=="files"&&result.Value.Payload.SequenceEqual(rawData)&&assembly.Count==0,"Fragment reconstruction failed");
        await using var a=new Fixture("BulkA");await using var b=new Fixture("BulkB");
        b.Manager.StartBluetoothListener(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret",kind:"ble");
        var data=Enumerable.Range(0,32000).Select(n=>(byte)(n%251)).ToArray();var complete=new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);var controls=0;
        b.Manager.Receive("files",(_,payload)=>{complete.TrySetResult(payload);return Task.CompletedTask;});b.Manager.Receive("input",(_,_)=>{Interlocked.Increment(ref controls);return Task.CompletedTask;});
        await a.Manager.SendAsync(b.Id,"input",[0]);var work=a.Manager.SendBulkTrackedAsync(b.Id,"files",data);
        for(var n=1;n<=40;n++){await a.Manager.SendAsync(b.Id,"input",[(byte)n]);await Task.Delay(10);}
        Require(Volatile.Read(ref controls)==41&&!complete.Task.IsCompleted,"Bulk queued ahead of continuous input");
        Require(await work.WaitAsync(TimeSpan.FromSeconds(8))=="ble"&&(await complete.Task.WaitAsync(TimeSpan.FromSeconds(2))).SequenceEqual(data),"Bulk integrity or route failed");
        var delayed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);b.Manager.Receive("files",(_,_)=>{delayed.TrySetResult();return Task.CompletedTask;});
        await a.Manager.SendAsync(b.Id,"input",[0]);a.Manager.YieldBulkForInput(b.Id);var began=System.Diagnostics.Stopwatch.GetTimestamp();var paused=a.Manager.SendBulkTrackedAsync(b.Id,"files",[1]);
        await Task.Delay(80);await a.Manager.SendAsync(b.Id,"input",[0]);await paused;await delayed.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Require(System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalMilliseconds>=180,"Bulk ignored active-input tail feedback");
        Console.WriteLine("PASS: raw binary Swift/C# vectors, negotiated codec, bounded fragment order, continuous input while 32KB BLE bulk completes exactly");
    }
    public static async Task CheckNewAcceptance() {
        var owner=Guid.NewGuid().ToString("D");var id=Guid.NewGuid().ToString("D");
        var config=new KeyboardConfig(id,owner,"双向",new(){{"KeyA","KeyB"},{"ControlLeft","ControlRight"},{"MetaRight","NoAction"},{"F12","F1"}},new(){{"KeyA","KeyC"},{"ControlLeft","NoAction"}},2,1000);
        Require(KeyboardMapping.Valid([config],[],id),"Full mapping was rejected");
        Require(KeyboardMapping.Map("KeyA","windows","macos",config)=="KeyB"&&KeyboardMapping.Map("KeyA","macos","windows",config)=="KeyC","Mapping direction leaked");
        Require(KeyboardMapping.Map("ControlLeft","windows","macos",config)=="ControlRight"&&KeyboardMapping.Map("MetaRight","windows","macos",config)=="NoAction","L/R or No Action failed");
        Require(KeyboardMapping.Command("ArrowUp",["ControlLeft","ArrowUp"],"macos","windows",config) is null,"No Action modifier triggered semantic shortcut");
        var policy=new InputRoutePolicy();Require(policy.Choose(["ble","tcp"],true,0)=="ble","Preferred startup route failed");foreach(var t in new[]{5d,10,15}){policy.Observe("ble",90,t);policy.Observe("tcp",10,t);}for(var n=1;n<=150;n++)Require(policy.Choose(["ble","tcp"],true,n/10d)=="ble","Route changed during continuous input");Require(policy.Choose(["ble","tcp"],true,16)=="tcp","Measured idle route did not improve");Require(policy.Choose(["ble"],true,16.01)=="ble","Missing link did not fall back");
        Console.WriteLine("PASS: full directional key mapping, L/R, No Action, semantic override and adaptive route hysteresis");
        await using(var a=new Fixture("TrustA"))await using(var b=new Fixture("TrustB")){
            a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>a.Group.Online.Length==2&&b.Group.Online.Length==2);
            b.Registry.SetPreferences(a.Id,true,false);a.Registry.SetPreferences(b.Id,false,false);a.Manager.Disconnect(b.Id);await Wait(()=>a.Manager.CurrentSessions().Length==0&&b.Manager.CurrentSessions().Length==0);
            var denied=false;try{await b.Manager.ConnectAsync("127.0.0.1",a.Port,null,null,quickOnly:true);}catch{denied=true;}Require(denied,"Reverse quick connection ignored receiver trust");
            await a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,quickOnly:true);a.Manager.Disconnect(b.Id);await Wait(()=>a.Manager.CurrentSessions().Length==0&&b.Manager.CurrentSessions().Length==0);
            a.Registry.SetPreferences(b.Id,true,true);b.AllowConnections=false;denied=false;try{await a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,autoOnly:true);}catch{denied=true;}Require(denied&&a.Manager.AutoConnectionDeclined(b.Id),"Auto decline was not remembered");b.AllowConnections=true;await a.Manager.ConnectAsync("127.0.0.1",b.Port,null,null,quickOnly:true);Require(a.Manager.CurrentSessions().Length==1,"Manual quick retry remained blocked");
        }
        Console.WriteLine("PASS: receiver-only Trusted privilege, automatic rejection and manual quick reconnect");
        await using(var a=new Fixture("PureBLEA"))await using(var b=new Fixture("PureBLEB")){
            b.Manager.UpdateCredentials("123456","");a.Manager.NetworkAvailable=false;b.Manager.NetworkAvailable=false;b.Manager.StartBluetoothListener(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456",null,kind:"ble");Require(b.BluetoothPrompts==1&&a.CertificatePrompts==0&&a.Manager.CurrentSessions()[0].Capabilities.Contains("ble"),"Pure BLE handshake still required a network password");
        }
        Console.WriteLine("PASS: pure BLE receiver-approved handshake without network credentials");
        await using(var a=new Fixture("ConfigA"))await using(var b=new Fixture("ConfigB")){
            var configID=Guid.NewGuid().ToString("D");var local=new KeyboardConfig(configID,a.Id,"共同配置",new(){{"KeyA","KeyB"}},new(),2,1000);var remote=local with{WindowsToMac=new(){{"KeyA","KeyC"}},Modified=2000};var unrelated=b.Group.KeyboardLibrary[0].Id;
            await a.Group.SaveKeyboardLibrary(a.Group.KeyboardLibrary.Append(local).ToArray(),configID);await b.Group.SaveKeyboardLibrary(b.Group.KeyboardLibrary.Append(remote).ToArray(),configID);a.Group.ConfirmConfig=(_,_,_)=>Task.FromResult("skip");b.Group.ConfirmConfig=(_,offered,existing)=>{if(offered.Id==configID){Require(existing?.WindowsToMac.GetValueOrDefault("KeyA")=="KeyC","Conflict did not retain local snapshot");return Task.FromResult("copy");}return Task.FromResult("skip");};
            a.Group.Start();b.Group.Start();a.Manager.Start(a.Port);b.Manager.Start(b.Port);await a.Manager.ConnectAsync("127.0.0.1",b.Port,"123456","fixture-secret");await Wait(()=>b.Group.Active?.Configs.FirstOrDefault(c=>c.Id==b.Group.Active.CurrentConfigID)?.Name=="共同配置（副本）"&&a.Group.Active?.CurrentConfigID==b.Group.Active?.CurrentConfigID);
            var values=b.Group.KeyboardLibrary;Require(values.Any(c=>c.Id==unrelated)&&values.First(c=>c.Id==configID).WindowsToMac["KeyA"]=="KeyC"&&values.First(c=>c.Name=="共同配置（副本）").WindowsToMac["KeyA"]=="KeyB","Conflict copy erased a configuration");
        }
        Console.WriteLine("PASS: encrypted UUID conflict resolution, both versions retained, shared selection and unrelated private config retained");
        var basePath=Path.Combine(Path.GetTempPath(),"ShareMouse-LinkTest-"+Guid.NewGuid().ToString("N"));
        try{
            var source=Path.Combine(basePath,"folder");var destination=Path.Combine(basePath,"received");Directory.CreateDirectory(Path.Combine(source,"deps","package"));File.WriteAllText(Path.Combine(source,"deps","package","a.txt"),"dependency");Directory.CreateSymbolicLink(Path.Combine(source,"deps","link"),"package");var scan=await FileStorage.Scan([source]);var link=scan.Item2.Single(f=>f.Item.LinkTarget is not null);Require(link.Item.LinkTarget=="package"&&link.Item.LinkDirectory==true&&link.Item.Size==0,"Folder link manifest incorrect");var root=Path.Combine(destination,"folder");Directory.CreateDirectory(Path.Combine(root,"deps","package"));var transfer=new TransferFile{Item=link.Item,Provider="test",Target=Path.Combine(root,"deps","link"),Partial=""};FileStorage.FinishLink(transfer,destination,root);Require(FileStorage.CompletedUnchanged(transfer)&&new DirectoryInfo(transfer.Target).LinkTarget=="package","Native received link verification failed");Require(!FileStorage.ValidLink("folder/deps/link","../../outside"),"Link path traversal accepted");Directory.CreateSymbolicLink(Path.Combine(source,"bad"),"../outside");var denied=false;try{await FileStorage.Scan([source]);}catch{denied=true;}Require(denied,"Outside symbolic link was accepted");
        }finally{if(Directory.Exists(basePath))Directory.Delete(basePath,true);}
        Console.WriteLine("PASS: Windows native relative directory links, receipt identity and outside-root rejection");
    }
    private sealed class Fixture : IAsyncDisposable {
        public string Id { get; }
        public string Directory { get; }=Path.Combine(Path.GetTempPath(),"ShareMouse-SharingRegression-"+Guid.NewGuid().ToString("N"));
        public int Port { get; }
        public IdentityStore Identity { get; }
        public PeerRegistry Registry { get; }
        public SessionManager Manager { get; }
        public GroupManager Group { get; set; }
        public int GroupPrompts,ConnectionPrompts,CertificatePrompts,BluetoothPrompts;
        public volatile bool AllowConnections=true;
        public volatile bool AllowBluetooth=true;
        public Fixture(string name, int approvalDelay=0, string? id=null, bool? bluetoothInputOnly=null) {
            Id=id??Guid.NewGuid().ToString("D");
            System.IO.Directory.CreateDirectory(Directory); Identity=new(Id); Registry=new(Directory);
            var available=new TcpListener(IPAddress.Loopback,0); available.Start(); Port=((IPEndPoint)available.LocalEndpoint).Port; available.Stop();
            Manager=new(Id,name,Identity,Registry,"123456","fixture-secret",_=> {Interlocked.Increment(ref CertificatePrompts); return true;},_=> { Interlocked.Increment(ref ConnectionPrompts); Thread.Sleep(approvalDelay); return AllowConnections; },text=> {if(text.StartsWith("NetworkRecovery",StringComparison.Ordinal))Console.WriteLine(name+" "+text);},
                _=> {Interlocked.Increment(ref BluetoothPrompts); Thread.Sleep(approvalDelay); return AllowBluetooth;}, bluetoothInputOnly: bluetoothInputOnly);
            Group=new(Id,name,Identity.Identity.PublicKey,[new(Id+":test",Id,"Fixture",1,1000,720,true,0,0)],Directory,Manager,Registry,
                _=> { Interlocked.Increment(ref GroupPrompts); return Task.FromResult(false); },_=>{},automaticSharing:true);
            Manager.Changed+=sessions=> { _=Group.ConnectionsChanged(sessions); };
        }
        public async ValueTask DisposeAsync() {
            await Manager.DisposeAsync(); Identity.Dispose();
            using(var store=new X509Store(StoreName.My,StoreLocation.CurrentUser)) {
                store.Open(OpenFlags.ReadWrite);
                foreach(var certificate in store.Certificates.Cast<X509Certificate2>().Where(c=>c.Subject=="CN=ShareMouse-"+Id)) store.Remove(certificate);
            }
            if(CngKey.Exists("ShareMouse-"+Id)) { using var key=CngKey.Open("ShareMouse-"+Id); key.Delete(); }
            System.IO.Directory.Delete(Directory,true);
        }
    }
}
