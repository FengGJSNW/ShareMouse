import SwiftUI
import AppKit

struct ScreenLayoutView: View {
    @ObservedObject private var appearance = SMAppearance.shared
    @ObservedObject var model: PairingViewModel
    @State private var layout: [ScreenGeometry] = []
    @State private var starts: [String: ScreenGeometry] = [:]
    @State private var dragEdges: [String: String] = [:]
    @State private var selectedID: String?
    @State private var autoAlign = true
    @State private var percent = false
    @State private var saving = false
    @State private var error = ""
    private static let scaleFormatter: NumberFormatter = {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 3; return formatter
    }()
    private static let northwestCursor = resizeCursor(descending: true)
    private static let northeastCursor = resizeCursor(descending: false)
    private static func resizeCursor(descending: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let a = NSPoint(x: 5, y: descending ? 19 : 5), b = NSPoint(x: 19, y: descending ? 5 : 19)
            let path = NSBezierPath(); path.move(to: a); path.line(to: b)
            let sign: CGFloat = descending ? -1 : 1
            path.move(to: NSPoint(x: a.x, y: a.y+6*sign)); path.line(to: a); path.line(to: NSPoint(x: a.x+6, y: a.y))
            path.move(to: NSPoint(x: b.x-6, y: b.y)); path.line(to: b); path.line(to: NSPoint(x: b.x, y: b.y-6*sign))
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke(); NSColor.black.setStroke(); path.lineWidth = 1.5; path.stroke(); return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
    private var locked: Bool {
        model.groupOnline.count < 2 || model.groupLocks.contains { $0.resource == "layout" && $0.ownerPeerID != model.peer.id.value.uuidString.lowercased() }
    }
    @State private var viewScale = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart: CGSize?
    @State private var magnifyStart: Double?
    @State private var viewportWidth = 700.0
    private var offsetX: Double { (viewportWidth-contentWidth*zoom)/2 + pan.width }
    private var offsetY: Double { (350-contentHeight*zoom)/2 + pan.height }
    private var contentWidth: Double { let base=model.groupState?.layout ?? layout;return (base.map { $0.x+$0.width }.max() ?? 1)-(base.map(\.x).min() ?? 0) }
    private var contentHeight: Double { let base=model.groupState?.layout ?? layout;return (base.map { $0.y+$0.height }.max() ?? 1)-(base.map(\.y).min() ?? 0) }
    private func bounded(_ value: CGSize) -> CGSize { let x=max(0,(viewportWidth+contentWidth*zoom)/2-24),y=max(0,(350+contentHeight*zoom)/2-24);return CGSize(width:max(-x,min(x,value.width)),height:max(-y,min(y,value.height))) }
    private var zoom: Double {
        let base = model.groupState?.layout ?? layout
        let width = (base.map { $0.x + $0.width }.max() ?? 1) - (base.map(\.x).min() ?? 0)
        let height = (base.map { $0.y + $0.height }.max() ?? 1) - (base.map(\.y).min() ?? 0)
        return min(max(100,viewportWidth-48) / max(1, width), 300 / max(1, height))*viewScale
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(layout.isEmpty ? "配对成功后自动显示两端屏幕并启用键鼠共享。" : "选择屏幕后拖动或拉伸边缘；Shift 保持比例。修改后保存。")
                .foregroundStyle(.secondary)
            canvas
            Text("同色屏幕属于同一台电脑，须保持相连；保存后同步各电脑的系统屏幕位置。").font(.caption).foregroundStyle(.secondary)
            Toggle("尝试自动对齐边缘", isOn: $autoAlign).toggleStyle(SMSwitchStyle())
            selectedSettings
            notices
            actions
        }
        .onAppear { layout = model.groupState?.layout ?? [] }
        .onChange(of: model.groupState?.revision) { _, _ in
            if model.layoutLease == nil && starts.isEmpty { layout = model.groupState?.layout ?? [] }
        }
        .onChange(of: model.groupState?.id) { _, _ in model.cancelLayoutEdit(); layout = model.groupState?.layout ?? [] }
        .onChange(of: model.layoutLease?.token) { _, token in
            if token == nil && !saving { starts = [:]; dragEdges = [:]; layout = model.groupState?.layout ?? []; error = "" }
        }
        .onDisappear { model.cancelLayoutEdit() }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context,size in
                    context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(SMTheme.canvas))
                    let spacing=20.0
                    for x in stride(from:pan.width.truncatingRemainder(dividingBy:spacing),through:size.width,by:spacing) {
                        for y in stride(from:pan.height.truncatingRemainder(dividingBy:spacing),through:size.height,by:spacing) {
                            context.fill(Path(ellipseIn:CGRect(x:x,y:y,width:2,height:2)),with:.color(SMTheme.border))
                        }
                    }
                }.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                    if panStart == nil {panStart=pan};pan=bounded(CGSize(width:panStart!.width+value.translation.width,height:panStart!.height+value.translation.height))
                }.onEnded { _ in panStart=nil })
                ForEach(layout.indices, id: \.self) { index in screenView(index) }
                alignmentGuides
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name:"screenLayout").clipped()
            .simultaneousGesture(MagnificationGesture().onChanged { value in
                if magnifyStart == nil {magnifyStart=viewScale};viewScale=max(0.25,min(4,magnifyStart!*value));pan=bounded(pan)
            }.onEnded { _ in magnifyStart=nil })
            .overlay(alignment:.bottomTrailing) {
                HStack(spacing:7) {
                    Button("聚焦"){viewScale=1;pan = .zero}
                    Button("−"){viewScale=max(0.25,viewScale/1.2)}
                    SMZoomSlider(value:Binding(get:{viewScale},set:{viewScale = $0;pan=bounded(pan)})).frame(width:120, height:28)
                    Button("+"){viewScale=min(4,viewScale*1.2)}
                    Text(viewScale, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width:46)
                }.padding(10).background(LinearGradient(colors:[SMTheme.elevation,SMTheme.surface],startPoint:.top,endPoint:.bottom),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(SMTheme.border)).shadow(color:.black.opacity(0.18),radius:6,y:3).padding(12)
            }
            .onAppear {viewportWidth=geometry.size.width}
            .onChange(of:geometry.size.width) {_,width in viewportWidth=width;pan=bounded(pan)}
        }.frame(height:350)
    }
    private func edgeAt(_ point: CGPoint, width: Double, height: Double) -> String {
        (point.y < 8 ? "n" : point.y > height-8 ? "s" : "") + (point.x < 8 ? "w" : point.x > width-8 ? "e" : "")
    }
    private func cursor(_ edge: String) -> NSCursor {
        switch edge {
        case "nw", "se": Self.northwestCursor
        case "ne", "sw": Self.northeastCursor
        case "n", "s": NSCursor.resizeUpDown
        case "w", "e": NSCursor.resizeLeftRight
        default: NSCursor.arrow
        }
    }
    private func screenView(_ index: Int) -> some View {
        let screen = layout[index]
        let selected = selectedID == screen.id
        let peers = model.groupState?.members.sorted { $0.joinOrder == $1.joinOrder ? $0.peerID < $1.peerID : $0.joinOrder < $1.joinOrder } ?? []
        let palette: [Color] = [.red,.orange,.yellow,.green,.cyan,.blue,.purple,.pink,.gray]
        let color = palette[(peers.firstIndex { $0.peerID == screen.peerID } ?? 0) % palette.count]
        let computer = model.groupState?.members.first { $0.peerID == screen.peerID }?.name ?? screen.name
        let originX = model.groupState?.layout.map(\.x).min() ?? 0, originY = model.groupState?.layout.map(\.y).min() ?? 0
        let width = max(20, screen.width * zoom), height = max(20, screen.height * zoom)
        return VStack(spacing: 4) {
            Text("\(computer) · \(screen.number)").font(.headline).lineLimit(1)
            Text(screen.name).font(.caption).lineLimit(1)
            Text("\(Int(screen.width)) × \(Int(screen.height)) · \(screen.angle)°").font(.caption)
        }.frame(width: width, height: height)
        .background(LinearGradient(colors:[color.opacity(selected ? 0.3 : 0.20), color.opacity(0.08)],startPoint:.topLeading,endPoint:.bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
        .background(SMTheme.surface.opacity(0.8),in:RoundedRectangle(cornerRadius:10))
        .shadow(color:.black.opacity(0.16),radius:5,y:3)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle()).onTapGesture { selectedID = screen.id }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): cursor(dragEdges[screen.id] ?? (selected ? edgeAt(point, width: width, height: height) : "")).set()
            case .ended: if starts[screen.id] == nil { NSCursor.arrow.set() }
            }
        }
        .gesture(DragGesture(coordinateSpace: .named("screenLayout")).onChanged { value in
            guard !locked, !saving else { return }
            if starts[screen.id] == nil {
                let point = CGPoint(x: value.startLocation.x-offsetX-(screen.x-originX)*zoom, y: value.startLocation.y-offsetY-(screen.y-originY)*zoom)
                dragEdges[screen.id] = selectedID == screen.id ? edgeAt(point, width: width, height: height) : ""
                starts[screen.id] = screen; selectedID = screen.id; model.editLayout()
            }
            guard let start = starts[screen.id] else { return }
            let edge = dragEdges[screen.id] ?? ""
            if edge.isEmpty {
                var moved = start; moved.x += value.translation.width / zoom; moved.y += value.translation.height / zoom
                layout[index] = autoAlign ? ScreenGeometry.snap(moved, others: layout, tolerance: 10 / zoom) : moved
            } else {
                layout[index] = ScreenGeometry.resize(start, dx: value.translation.width / zoom, dy: value.translation.height / zoom, edge: edge, proportional: NSEvent.modifierFlags.contains(.shift), others: layout, tolerance: autoAlign ? 10/zoom : 0)
            }
        }.onEnded { _ in starts.removeValue(forKey: screen.id); dragEdges.removeValue(forKey: screen.id); NSCursor.arrow.set() })
        .overlay {
            if selected { ZStack {
                ForEach(["n", "s", "w", "e", "nw", "ne", "sw", "se"], id: \.self) { edge in
                    let corner = edge.count == 2
                    Rectangle().fill(color.opacity(corner ? 0.85 : 0.01))
                        .frame(width: corner ? 9 : (edge == "n" || edge == "s" ? max(9,width-18) : 9), height: corner ? 9 : (edge == "w" || edge == "e" ? max(9,height-18) : 9))
                        .position(x: edge.contains("w") ? 0 : edge.contains("e") ? width : width/2, y: edge.contains("n") ? 0 : edge.contains("s") ? height : height/2)
                }
            }.frame(width: width, height: height).allowsHitTesting(false) }
        }
        .offset(x: offsetX + (screen.x-originX)*zoom, y: offsetY + (screen.y-originY)*zoom)
    }
    @ViewBuilder private var selectedSettings: some View {
        if let index = layout.firstIndex(where: { $0.id == selectedID }) {
            let screen = layout[index]
            GroupBox("所选屏幕 · " + screen.name) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("原生尺寸：\(screen.pixelWidth) × \(screen.pixelHeight) · 屏幕 \(screen.number)" + (screen.primary ? " · 主屏" : "")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("尺寸单位", selection: $percent) { Text("像素").tag(false); Text("百分比").tag(true) }.frame(width: 170)
                        Text("宽")
                        TextField("宽", value: Binding(get: { percent ? layout[index].width/layout[index].baseWidth*100 : layout[index].width }, set: { value in guard value.isFinite, value > 0 else { return }; model.editLayout(); layout[index].setSize(width: percent ? value/100*layout[index].baseWidth : value, height: layout[index].height) }), formatter: Self.scaleFormatter).frame(width: 85)
                        Text("高")
                        TextField("高", value: Binding(get: { percent ? layout[index].height/layout[index].baseHeight*100 : layout[index].height }, set: { value in guard value.isFinite, value > 0 else { return }; model.editLayout(); layout[index].setSize(width: layout[index].width, height: percent ? value/100*layout[index].baseHeight : value) }), formatter: Self.scaleFormatter).frame(width: 85)
                    }.textFieldStyle(SMInputStyle())
                    HStack {
                        Picker("旋转", selection: Binding(get: { layout[index].angle }, set: { model.editLayout(); layout[index].rotation = $0 })) { ForEach([0,90,180,270], id: \.self) { Text("\($0)°").tag($0) } }.frame(width: 170)
                        Button("还原设置") { model.editLayout(); layout[index].scale = 1; layout[index].scaleX = nil; layout[index].scaleY = nil; layout[index].rotation = nil }
                        Text("调整共享桌面的逻辑尺寸和方向").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }.disabled(locked || saving)
        }
    }
    private var alignmentGuides: some View {
        Canvas { context, size in
            guard autoAlign, !starts.isEmpty, let selected = layout.first(where: { $0.id == selectedID }) else { return }
            let originX = model.groupState?.layout.map(\.x).min() ?? 0, originY = model.groupState?.layout.map(\.y).min() ?? 0
            for other in layout where other.id != selected.id {
                for x in [selected.x, selected.x+selected.width] where [other.x,other.x+other.width].contains(where: { abs($0-x)<0.01 }) {
                    var path = Path(); let value = offsetX+(x-originX)*zoom; path.move(to: CGPoint(x: value,y: 0)); path.addLine(to: CGPoint(x: value,y: size.height)); context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4,3]))
                }
                for y in [selected.y, selected.y+selected.height] where [other.y,other.y+other.height].contains(where: { abs($0-y)<0.01 }) {
                    var path = Path(); let value = offsetY+(y-originY)*zoom; path.move(to: CGPoint(x: 0,y: value)); path.addLine(to: CGPoint(x: size.width,y: value)); context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4,3]))
                }
            }
        }.allowsHitTesting(false)
    }
    private var notices: some View {
        VStack(alignment: .leading) {
            if locked, !layout.isEmpty {
                Text(model.groupLocks.contains { $0.resource == "layout" } ? "另一台电脑正在编辑排布" : "等待已配对电脑上线").foregroundStyle(.secondary)
            }
            if !layout.isEmpty, !ScreenGeometry.validLayout(layout) { Text("请连接所有屏幕边缘、移除重叠，同色屏幕也必须彼此相连").foregroundStyle(.red) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if !model.layoutError.isEmpty { Text(model.layoutError).foregroundStyle(.red) }
            if !model.nativeLayoutError.isEmpty { Text(model.nativeLayoutError).foregroundStyle(.red) }
            if model.layoutStarting { Text("正在获取编辑权限…").foregroundStyle(.secondary) }
        }
    }
    private var actions: some View {
        HStack {
            Spacer()
            Button("取消修改") { model.cancelLayoutEdit(); layout = model.groupState?.layout ?? []; error = "" }
                .disabled(model.layoutLease == nil && !model.layoutStarting)
            Button(saving ? "保存中…" : "保存排布") {
                guard let lease = model.layoutLease else { return }; saving = true
                Task {
                    do { try await model.commitLayout(layout, lease: lease); error = "" }
                    catch { self.error = "保存未完成，已刷新共享排布，请重新拖动屏幕" }
                    layout = model.groupState?.layout ?? []; starts = [:]
                    saving = false
                }
            }.disabled(saving || locked || model.layoutLease == nil || !ScreenGeometry.validLayout(layout))
        }
    }
}
