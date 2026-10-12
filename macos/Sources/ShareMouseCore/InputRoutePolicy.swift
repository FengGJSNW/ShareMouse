import Foundation
/// RTT-based transport selection stays below the application protocols. Changes use idle boundaries and hysteresis.
public struct InputRoutePolicy: Sendable {
    private struct Sample: Sendable {var mean:Double;var jitter:Double;var count:Int;var at:Double}
    private var samples:[String:Sample]=[:]
    private var current:String?
    private var switched = -Double.infinity
    private var lastInput = -Double.infinity
    public init() {}
    public mutating func observe(_ kind:String,milliseconds:Double,now:Double) {
        guard milliseconds.isFinite,milliseconds>=0,milliseconds<20_000 else{return}
        if var old=samples[kind] {old.jitter=old.jitter*0.75+abs(milliseconds-old.mean)*0.25;old.mean=old.mean*0.75+milliseconds*0.25;old.count+=1;old.at=now;samples[kind]=old}
        else{samples[kind]=Sample(mean:milliseconds,jitter:0,count:1,at:now)}
    }
    public mutating func resetPreference(){current=nil}
    public mutating func choose(_ available:Set<String>,bluetoothPreferred:Bool,now:Double) -> String? {
        let available=available.contains("quic") ? available.subtracting(["tcp"]) : available
        let order=bluetoothPreferred ? ["ble","quic","tcp"]:["quic","tcp","ble"]
        guard let fallback=order.first(where:available.contains) else{current=nil;return nil}
        guard let previous=current,available.contains(previous) else{current=fallback;switched=now;lastInput=now;return fallback}
        defer{lastInput=now}
        // Keep one ordered stream throughout a continuous movement, drag or held-key burst.
        guard now-lastInput>=0.5,now-switched>=10 else{return previous}
        let measured=available.filter{samples[$0].map{$0.count>=3&&now-$0.at<16} ?? false}
        guard measured.contains(previous),measured.count>1 else{return previous}
        func score(_ kind:String)->Double {let s=samples[kind]!;let preferred=bluetoothPreferred ? kind=="ble":kind != "ble";return s.mean+s.jitter+(preferred ? 0:20)+(kind=="tcp" ? 1:0)}
        let next=measured.min{score($0)<score($1)}!
        guard next != previous,score(next)+5<score(previous) else{return previous}
        current=next;switched=now;return next
    }
}
