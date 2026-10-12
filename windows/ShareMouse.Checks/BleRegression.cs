using System.Net.Sockets;
using ShareMouse.Core;
using ShareMouse.Network;

internal static class BleRegression {
    public static async Task Run() {
        var sender=new BleStreamFraming();var receiver=new BleStreamFraming();
        var frames=Enumerable.Range(0,32).Select(i=>sender.Encode(Enumerable.Repeat((byte)i,500).ToArray())).ToArray();
        var ordered=new List<byte>();
        for(var i=0;i<32;i+=2) {
            if(receiver.Receive(frames[i+1]).Length!=0)throw new Exception("Unordered fragment leaked.");
            ordered.AddRange(receiver.Receive(frames[i]).SelectMany(p=>p));
        }
        if(!ordered.SequenceEqual(Enumerable.Range(0,32).SelectMany(i=>Enumerable.Repeat((byte)i,500))) || receiver.Reordered!=16 || receiver.Receive(frames[0]).Length!=0)throw new Exception("Fragment reorder/duplicate regression.");
        if(Convert.ToHexString(frames[0][..12])!="534246310000000000000000")throw new Exception("Fragment wire vector mismatch.");
        var window=new BleMotionWindow();for(var i=0;i<16;i++)window.Acknowledged(.045);
        if(window.Capacity(240)!=13 || window.Capacity(60)!=5 || !window.Allows(12,240,.045) || window.Allows(2,240,.081))throw new Exception("BLE motion admission regression.");
        window.Acknowledged(.300);if(window.Capacity(240)!=13)throw new Exception("Congestion expanded window.");
        Console.WriteLine("PASS: cross-platform sequenced fragments, reordering/duplicates, adaptive flight window, stale-motion bound.");
        using var bridge=new BleByteBridge(_=>Task.CompletedTask,()=>{});
        var port=bridge.Listen();
        var fragments=Enumerable.Range(0,200).Select(i=>Enumerable.Repeat((byte)i,512).ToArray()).ToArray();
        // The remote TLS hello can precede the local client connecting to the bridge.
        var writes=fragments.Select(bridge.ReceiveAsync).ToArray();
        using var client=new TcpClient(); await client.ConnectAsync("127.0.0.1",port);
        var received=new byte[200*512]; using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await client.GetStream().ReadExactlyAsync(received,deadline.Token);
        await Task.WhenAll(writes).WaitAsync(deadline.Token);
        if(!received.SequenceEqual(fragments.SelectMany(p=>p))) throw new Exception("Early/ordered BLE bytes corrupted.");
        using var blocked=new BleByteBridge(_=>Task.CompletedTask,()=>{});
        var pending=blocked.ReceiveAsync([1,2,3]); blocked.Dispose();
        try {await pending.WaitAsync(TimeSpan.FromSeconds(2));throw new Exception("Closed bridge accepted bytes.");}
        catch(IOException) {}
        var source="66666666-7777-8888-9999-aaaaaaaaaaaa";var target="bbbbbbbb-cccc-dddd-eeee-ffffffffffff";var id="11111111-2222-3333-4444-555555555555";
        var screen=new ScreenGeometry("screen-一",target,"Screen",1,1000,1000,true,0,0);
        var group=new SharedGroup(id,"Fixture",source,1,[],[screen],[],"");
        foreach(var type in new[]{"control","pointer"}) {
            var packet=new InputPacket {Type=type,GroupID=id,SourcePeerID=source,TargetPeerID=target,Sequence=123,Pointer=new(screen.Id,40.5,20.25,source,9)};
            if(MotionCodec.Encode(packet,group.Layout) is not null) throw new Exception("Extension sent without negotiation.");
            var bytes=MotionCodec.Encode(packet,group.Layout,extended:true)!;
            var expected=(type=="control"?"534d4331":"534d5031")+"11111111222233334444555555555555000000000000007b0000000000000009000a73637265656e2de4b8804222000041a20000";
            if(Convert.ToHexString(bytes).ToLowerInvariant()!=expected) throw new Exception("BLE cross-platform wire vector mismatch.");
            var decoded=MotionCodec.Decode(bytes,group,source,target);
            if(decoded?.Type!=type || decoded.Pointer!=packet.Pointer) throw new Exception("Boundary pointer corrupted.");
        }
        Console.WriteLine("PASS: 200 preconnection BLE fragments ordered exactly; close releases pending writer; negotiated crossing/pointer wire vectors.");
    }
}
