import Foundation
import XCTest
@testable import ShareMouseCore
final class LayoutTransformTests: XCTestCase {
    func testMixedDensityNativeOriginsAndPerDeviceConnectivity() throws {
        let primary = ScreenGeometry(id:"main",peerID:"a",name:"Retina",number:1,pixelWidth:2000,pixelHeight:1000,primary:true,x:900,y:600)
        let right = ScreenGeometry(id:"external",peerID:"a",name:"External",number:2,pixelWidth:1000,pixelHeight:1000,primary:false,x:2900,y:800)
        let plan = try XCTUnwrap(ScreenGeometry.nativeLayout([primary,right], sizes:["main":(1000,500),"external":(1920,1080)]))
        XCTAssertEqual(plan[0].x,0); XCTAssertEqual(plan[0].y,0)
        XCTAssertEqual(plan[1].x,1000); XCTAssertEqual(plan[1].y,100)
        var left = right; left.x = -100; left.y = 800
        let negative = try XCTUnwrap(ScreenGeometry.nativeLayout([primary,left],sizes:["main":(1000,500),"external":(1920,1080)]))
        XCTAssertEqual(negative[1].x,-1920); XCTAssertEqual(negative[1].y,100)
        XCTAssertNil(ScreenGeometry.nativeLayout([primary,right],sizes:["main":(.nan,500),"external":(1920,1080)]))
        let a = ScreenGeometry(id:"a1",peerID:"a",name:"A",number:1,pixelWidth:1000,pixelHeight:500,primary:true,x:0,y:0)
        var b = a; b.id = "b"; b.peerID = "b"; b.x = 1000
        var a2 = a; a2.id = "a2"; a2.primary = false; a2.x = 2000
        XCTAssertFalse(ScreenGeometry.validLayout([a,b,a2]), "Another computer must not bridge disconnected screens on one computer")
        a2.x = 1000; b.x = 2000
        XCTAssertTrue(ScreenGeometry.validLayout([a,a2,b]))
    }
    func testLegacyLayoutAndRotatedCoordinatesRoundTrip() throws {
        let legacy = Data(#"{"id":"screen","peerID":"peer","name":"Display","number":1,"pixelWidth":1920,"pixelHeight":1080,"primary":true,"x":0,"y":0,"scale":1.25}"#.utf8)
        var screen = try JSONDecoder().decode(ScreenGeometry.self, from: legacy)
        XCTAssertEqual(screen.width, 2400); XCTAssertEqual(screen.height, 1350)
        screen.scaleX = 1.5; screen.scaleY = 0.75
        for angle in [0,90,180,270] {
            screen.rotation = angle
            for point in [(0.0,0.0),(1.0,1.0),(0.3,0.7)] {
                let logical = screen.logical(point.0,point.1), native = screen.native(logical.0,logical.1)
                XCTAssertEqual(native.0,point.0,accuracy: 0.00001); XCTAssertEqual(native.1,point.1,accuracy: 0.00001)
            }
            XCTAssertEqual(try JSONDecoder().decode(ScreenGeometry.self,from: JSONEncoder().encode(screen)),screen)
        }
        XCTAssertEqual(screen.width,1620); XCTAssertEqual(screen.height,1440)
    }
    func testResizeAnchorsRatioAndEdgeSnap() {
        let screen = ScreenGeometry(id:"a",peerID:"a",name:"A",number:1,pixelWidth:1000,pixelHeight:500,primary:true,x:0,y:0)
        let neighbor = ScreenGeometry(id:"b",peerID:"b",name:"B",number:1,pixelWidth:1000,pixelHeight:500,primary:true,x:1500,y:750)
        let free = ScreenGeometry.resize(screen,dx:200,dy:300,edge:"se",proportional:false,others:[])
        XCTAssertEqual(free.width,1200); XCTAssertEqual(free.height,800)
        let locked = ScreenGeometry.resize(screen,dx:-200,dy:700,edge:"nw",proportional:true,others:[])
        XCTAssertEqual(locked.width/locked.height,2,accuracy:0.0001)
        XCTAssertEqual(locked.x+locked.width,1000); XCTAssertEqual(locked.y+locked.height,500)
        let snap = ScreenGeometry.resize(screen,dx:495,dy:245,edge:"se",proportional:false,others:[neighbor],tolerance:10)
        XCTAssertEqual(snap.width,1500); XCTAssertEqual(snap.height,750)
        let ratioSnap = ScreenGeometry.resize(screen,dx:495,dy:200,edge:"se",proportional:true,others:[neighbor],tolerance:10)
        XCTAssertEqual(ratioSnap.width,1500); XCTAssertEqual(ratioSnap.height,750)
        var invalid = screen; invalid.rotation = 45
        XCTAssertFalse(ScreenGeometry.validLayout([invalid]))
    }
}
