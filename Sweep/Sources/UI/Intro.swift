import AppKit
import SwiftUI

// First-launch intro. Every scene is built from Sweep's real views (hero, strip, legend, rows, bottom bar,
// confirm bar) on a throwaway SweepModel that a keyframe script drives. Nothing here touches the disk.

typealias DemoStep = @MainActor (Demo) -> Void

enum IntroCopy {
    static let titles = ["Finds what you can rebuild", "Sorted by kind", "Pick what you have not touched",
                         "Moves to the Trash, nothing more", "Only ever the Trash"]
    static let lines = ["It looks through your project folders and sizes every node_modules, build and cache folder.",
                        "The strip splits the space by category. Press a key to look at one kind.",
                        "One press selects everything older than 30 days. Anything in use stays out.",
                        "You confirm first. Folders go to the Trash, so you can put them back.",
                        "Nothing is deleted for good. Sweep lives in the menu bar and opens with a key."]
    /// Seconds each scene plays before auto-advancing (the last one waits for Get started).
    static let durations: [Double] = [5.0, 4.8, 4.6, 5.0, 4.4]
    /// Frame times QA renders besides the start and the end.
    static let mids: [Double] = [2.6, 2.6, 1.5, 1.4, 1.8]
}

/// Scripted state of one scene: the demo model, the ghost cursor and the menu bar mock.
@MainActor @Observable
final class Demo {
    let scene: Int
    let model = SweepModel()
    var cursor = CGPoint(x: 560, y: 210)
    var cursorShown = false
    var pressed = false
    var instant = false
    var reduce = false
    var spot = CGRect(x: 0, y: 0, width: 100, height: 100)
    var spotOn = false
    // menu bar scene
    var iconFill = false
    var menuOpen = false
    var hot = -1
    var keyLit = false

    static let items: [Found] = {
        var a = QA.fake().items
        if let i = a.firstIndex(where: { $0.display == "marlin/DerivedData" }) { a[i].size = 5_640_000_000 }   // older-than-30-days adds up to 22.0 GB
        return a
    }()

    init(scene: Int) {
        self.scene = scene
        switch scene {
        case 0: model.reset()
        case 1, 2: model.setItemsForQA(Self.items)
        case 3: model.setItemsForQA(Self.items); model.selectOlder()
        default: break
        }
    }

    func ani(_ a: Animation, _ body: () -> Void) { withAnimation(instant ? nil : a, body) }
    func move(_ p: CGPoint) { ani(.spring(duration: 0.7, bounce: 0.1)) { cursor = p; cursorShown = true } }
    func light(_ r: CGRect) { withAnimation(instant || reduce ? nil : KitMotion.list) { spot = r; spotOn = true } }
    func hide() { ani(KitMotion.soft) { cursorShown = false } }
    /// The button press releases 170 ms later, on the same clock as the keyframes.
    func tap(_ action: () -> Void) {
        ani(KitMotion.press) { pressed = true }
        action()
        if instant { pressed = false } else { releaseAt = clock + 0.17 }
    }

    @ObservationIgnored private var keys: [(Double, DemoStep)] = []
    @ObservationIgnored private var fired = 0
    @ObservationIgnored private var clock = 0.0
    @ObservationIgnored private var releaseAt: Double?

    /// Applies every key up to `t` at once, with no animation (QA frames and the first tick).
    func prime(to t: Double) {
        instant = true
        step(to: t)
        instant = false
    }

    /// The one clock: fires every keyframe whose time has come. `t` is the scene's local time.
    func step(to t: Double) {
        if keys.isEmpty { keys = script.sorted { $0.0 < $1.0 } }
        clock = t
        while fired < keys.count, keys[fired].0 <= t { keys[fired].1(self); fired += 1 }
        if let r = releaseAt, t >= r { releaseAt = nil; ani(KitMotion.press) { pressed = false } }
    }

    // Targets in the 760 pt wide stage space (tip of the arrow lands here).
    static let scanButton = CGPoint(x: 706, y: 52)
    static func key(_ i: Int) -> CGPoint { CGPoint(x: 73 + 102.3 * Double(i), y: 128) }
    static let selectOlder = CGPoint(x: 520, y: 330)
    static let trashButton = CGPoint(x: 680, y: 330)

    var script: [(Double, DemoStep)] {
        let m = model
        switch scene {
        case 0:
            let n = Self.items.count
            var k: [(Double, DemoStep)] = [
                (0.0, { $0.light(CGRect(x: 8, y: 4, width: 744, height: 94)) }),
                (2.8, { $0.light(CGRect(x: 0, y: 106, width: 760, height: 178)) }),
                (0.2, { $0.move(Self.scanButton) }),
                (1.1, { d in d.tap { withAnimation(KitMotion.list) { m.setScanning(status: "Starting", keepOrder: true) } } }),
                (1.6, { $0.hide() }),
            ]
            for i in 1...n {
                k.append((1.5 + 0.1 * Double(i), { d in
                    let part = Array(Self.items.prefix(i)).enumerated().map { j, f -> Found in var f = f; if j >= i - 3 { f.size = nil }; return f }
                    d.ani(KitMotion.list) {
                        m.setItemsForQA(part)
                        let f = Self.items[i - 1]
                        m.setScanning(status: f.display.hasPrefix("~") ? f.display : "~/Projects/" + f.display, keepOrder: true)
                    }
                }))
            }
            k.append((1.5 + 0.1 * Double(n) + 0.5, { d in d.ani(KitMotion.list) { m.setItemsForQA(Self.items) } }))
            return k
        case 1:
            return [
                (0.0, { $0.light(CGRect(x: 12, y: 96, width: 736, height: 62)) }),
                (0.3, { $0.move(Self.key(1)) }),
                (1.0, { d in d.tap { m.pick(.xcode) } }),
                (2.3, { $0.move(Self.key(0)) }),
                (2.9, { d in d.tap { m.pick(.node) } }),
                (3.8, { $0.hide() }),
            ]
        case 2:
            return [
                (0.0, { $0.light(CGRect(x: 380, y: 286, width: 380, height: 60)) }),
                (1.5, { $0.light(CGRect(x: 8, y: 76, width: 744, height: 22)) }),
                (2.4, { $0.light(CGRect(x: 0, y: 106, width: 760, height: 178)) }),
                (0.2, { $0.move(Self.selectOlder) }),
                (0.9, { d in d.tap { d.ani(KitMotion.list) { m.selectOlder() } } }),
                (3.0, { $0.hide() }),
            ]
        case 3:
            return [
                (0.0, { $0.light(CGRect(x: 440, y: 286, width: 320, height: 60)) }),
                (0.9, { $0.light(CGRect(x: 0, y: 274, width: 760, height: 72)) }),
                (2.7, { $0.light(CGRect(x: 0, y: 106, width: 760, height: 178)) }),
                (3.5, { $0.light(CGRect(x: 0, y: 286, width: 520, height: 60)) }),
                (0.2, { $0.move(Self.trashButton) }),
                (0.8, { d in d.tap { m.confirming = true } }),
                (2.0, { $0.move(CGPoint(x: 680, y: 336)) }),
                (2.6, { d in d.tap {
                    let ids = m.selectedItems.map(\.display), bytes = m.selectedBytes
                    d.ani(KitMotion.list) {
                        m.confirming = false; m.clearSelection(); m.removeForQA(ids)
                        m.message = "Moved \(Fmt.bytes(bytes)) to the Trash. Empty the Trash in Finder to free the space."
                    }
                } }),
                (4.0, { $0.hide() }),
            ]
        default:
            return [
                (0.0, { $0.light(CGRect(x: 462, y: 0, width: 76, height: 26)) }),
                (1.5, { $0.light(CGRect(x: 372, y: 28, width: 194, height: 150)) }),
                (3.1, { $0.light(CGRect(x: 90, y: 112, width: 160, height: 88)) }),
                (0.2, { d in d.ani(.spring(duration: 0.8, bounce: 0.1)) { d.iconFill = true } }),
                (0.7, { d in d.cursor = CGPoint(x: 400, y: 150); d.move(MenuStage.iconPoint) }),
                (1.4, { d in d.tap { d.ani(KitMotion.panelIn) { d.menuOpen = true } } }),
                (2.2, { d in d.move(MenuStage.rowPoint(2)); d.ani(KitMotion.soft) { d.hot = 2 } }),
                (3.1, { d in d.hide(); d.ani(KitMotion.panelOut) { d.menuOpen = false; d.hot = -1 }
                          d.ani(KitMotion.press) { d.keyLit = true } }),
            ]
        }
    }
}

// MARK: Stages

/// The real Sweep views stacked like the window, on the demo model. Never takes input.
struct AppStage: View {
    let demo: Demo
    static let size = CGSize(width: 760, height: 346)
    var body: some View {
        let m = demo.model
        let c = ContentView(model: m)
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                c.hero
                ReclaimStrip(stats: m.stats, scanning: m.scanning, filter: m.filter, onPick: { _ in }).padding(.horizontal, KitSpace.xl)
                if demo.scene == 1 { c.legend } else { Spacer().frame(height: KitSpace.m) }
                KitDivider()
                list(m)
                KitDivider()
                c.bottomBar
            }
            if m.confirming { ConfirmBar(model: m).transition(.kitBar) }
        }
        .animation(m.confirming ? KitMotion.panelIn : KitMotion.panelOut, value: m.confirming)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(KitColor.window)
        .allowsHitTesting(false)
    }

    @ViewBuilder func list(_ m: SweepModel) -> some View {
        Color.clear.overlay(alignment: .top) { VStack(spacing: 0) {
            if m.rows.isEmpty {
                ForEach(0..<4, id: \.self) { SkeletonRow(seed: $0) }
            } else {
                ForEach(m.rows) { r in
                    switch r {
                    case .header(let name, let total, let count): GroupHeader(name: name, total: total, count: count).transition(.kitRow)
                    case .item(let f): ItemRow(item: f, on: m.selected.contains(f.id), selectable: m.selectable(f), maxSize: m.maxSize, model: m, stagger: nil)
                        .equatable().transition(.kitRow)
                    }
                }
            }
        } }
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}

/// Last scene: the drawn menu bar icon, its menu and the hot key.
struct MenuStage: View {
    let demo: Demo
    static let size = CGSize(width: 592, height: 270)
    static let iconPoint = CGPoint(x: 508, y: 12)
    static func rowPoint(_ i: Int) -> CGPoint { CGPoint(x: 420, y: 58 + 26 * Double(i)) }
    private let rows = ["Scan", "Last scan: 22.0 GB reclaimable", "Open Sweep", "Settings", "Quit Sweep"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                icon.background(RoundedRectangle(cornerRadius: 4).fill(demo.menuOpen ? KitColor.line : .clear).frame(width: 28, height: 18))
                Text("Thu 9:41").font(.system(size: 11, weight: .medium))
            }
            .font(.system(size: 11)).foregroundStyle(KitColor.text2).padding(.horizontal, 14)
            .frame(width: Self.size.width, height: 24)
            .background(KitColor.well)
            .overlay(alignment: .bottom) { KitDivider() }

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(demo.keyLit ? Color.teal : .clear, lineWidth: 1.5).frame(width: 142, height: 58)
                    KitKeycaps(keys: "⌃⌥S").scaleEffect(1.7)
                }
                .frame(height: 58).scaleEffect(demo.keyLit ? 0.96 : 1)
                Text("Opens Sweep from any app").font(KitFont.detail).foregroundStyle(KitColor.text2)
            }
            .frame(width: 300).position(x: 170, y: 150)

            menu.frame(width: 190).offset(x: 400 - 28, y: 30)
                .kitPanelEntrance(demo.menuOpen, anchor: .topTrailing)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(KitColor.window)
        .allowsHitTesting(false)
    }

    /// Same drawing as the real status item (SweepApp.statusImage), segments growing in.
    var icon: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(KitColor.text, lineWidth: 1.3).frame(width: 17, height: 11).offset(x: 1.5, y: 1.5)
            HStack(spacing: 1.2) {
                ForEach(Array([6.0, 3.5, 2.5].enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 0.8).fill(KitColor.text).frame(width: demo.iconFill ? w : 0.01, height: 5)
                }
            }.offset(x: 4, y: 4.5)
        }
        .frame(width: 20, height: 14)
    }

    var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, t in
                if i == 3 { KitDivider().padding(.vertical, 2) }
                Text(t).font(i == 1 ? KitFont.detail : KitFont.body)
                    .foregroundStyle(demo.hot == i ? Color.black.opacity(0.85) : (i == 1 ? KitColor.text2 : KitColor.text))
                    .padding(.horizontal, 8).frame(height: 24, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(demo.hot == i ? Color.teal : .clear))
            }
        }
        .padding(5)
        .background(KitColor.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KitColor.line, lineWidth: 1))
    }
}

struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = [(0.0, 0.0), (0, 16), (4, 12.5), (7, 19), (10, 17.7), (7, 11.3), (12, 11.3)]
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }
}

struct GhostCursor: View {
    let demo: Demo
    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle().strokeBorder(KitColor.text.opacity(0.6), lineWidth: 1).frame(width: 30, height: 30)
                .scaleEffect(demo.pressed ? 1 : 0.3).opacity(demo.pressed ? 1 : 0).offset(x: -15, y: -15)
            Arrow().fill(KitColor.text)
            .overlay(Arrow().stroke(KitColor.window, lineWidth: 1))
            .scaleEffect(demo.pressed ? 0.88 : 1, anchor: .topLeading)
        }
        .offset(x: demo.cursor.x, y: demo.cursor.y)
        .opacity(demo.cursorShown ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// Stage minus a crisp rounded hole (element rect padded 4 pt, radius 9 + 4), clipped to the stage; `ring` is just the outline.
struct SpotRing: Shape {
    var rect: CGRect
    var size: CGSize
    var ring = false
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(rect.minX, rect.minY), .init(rect.width, rect.height)) }
        set { rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in _: CGRect) -> Path {
        var p = Path()
        if !ring { p.addRect(CGRect(x: -4, y: -4, width: size.width + 8, height: size.height + 8)) }
        let hole = rect.insetBy(dx: -4, dy: -4).intersection(CGRect(origin: .zero, size: size))
        if !hole.isNull { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 13, height: 13)) }
        return p
    }
}

struct SpotOverlay: View {
    let demo: Demo
    let size: CGSize
    @Environment(\.kitAccent) private var accent
    var body: some View {
        ZStack {
            SpotRing(rect: demo.spot, size: size).fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true)).blur(radius: 1)
            SpotRing(rect: demo.spot, size: size, ring: true).stroke(accent.opacity(0.35), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .opacity(demo.spotOn ? 1 : 0)
        .allowsHitTesting(false)
    }
}

struct IntroStage: View {
    let demo: Demo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scene = demo.scene
        let s = MenuStage.size.width / AppStage.size.width
        ZStack(alignment: .topLeading) {
            if scene < 4 {
                ZStack(alignment: .topLeading) {
                    AppStage(demo: demo); SpotOverlay(demo: demo, size: AppStage.size)
                    if !reduceMotion { GhostCursor(demo: demo) }
                }
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: MenuStage.size.width, height: MenuStage.size.height, alignment: .topLeading)
            } else {
                ZStack(alignment: .topLeading) {
                    MenuStage(demo: demo); SpotOverlay(demo: demo, size: MenuStage.size)
                    if !reduceMotion { GhostCursor(demo: demo) }
                }
            }
        }
        .frame(width: MenuStage.size.width, height: MenuStage.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KitColor.line, lineWidth: 1))
        .onAppear { demo.reduce = reduceMotion }
    }
}

// MARK: Window content

/// The one clock: an IntroFlow plus a single 30 Hz timer that ends the intro, advances scenes and steps the
/// current scene's keyframes. Next, Back and Skip go through the flow, so nothing pending survives them.
@MainActor @Observable
final class IntroModel {
    var index: Int
    var demos: [Int: Demo] = [:]
    @ObservationIgnored var flow = IntroFlow(durations: IntroCopy.durations)
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var started = false          // closed with Get started (the app then opens and scans)
    @ObservationIgnored private var timer: Timer?
    static let last = IntroCopy.titles.count - 1
    var isLast: Bool { index == Self.last }

    init(index: Int = 0, preview: Demo? = nil) {
        self.index = index
        if let preview { demos[index] = preview }
    }

    func start() {
        flow = IntroFlow(durations: IntroCopy.durations, now: CACurrentMediaTime())
        demos[0] = Demo(scene: 0)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        let now = CACurrentMediaTime()
        flow.tick(now: now)
        sync()
        if flow.scene == index { demos[index]?.step(to: flow.time(now: now)) }
    }
    func next() { flow.next(now: CACurrentMediaTime()); sync() }
    func back() { flow.back(now: CACurrentMediaTime()); sync() }
    func skip() { flow.close(); sync() }
    func getStarted() { started = true; flow.close(); sync() }
    /// Window closed by any other path.
    func finish() { flow.close(); sync() }

    private func sync() {
        if flow.closed { stop(); onClose(); return }
        guard flow.scene != index else { return }
        demos[flow.scene] = Demo(scene: flow.scene)
        withAnimation(KitMotion.list) { index = flow.scene }
    }
}

struct IntroView: View {
    let model: IntroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let index = model.index
        VStack(spacing: 0) {
            ZStack {
                KitColor.well
                if let demo = model.demos[index] {
                    IntroStage(demo: demo).id(index)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .offset(x: -24).combined(with: .opacity)))
                }
            }
            .frame(height: 300).clipped()
            KitDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text(IntroCopy.titles[index]).font(Font.system(size: 17, weight: .semibold)).foregroundStyle(KitColor.text)
                Text(IntroCopy.lines[index]).font(KitFont.body).foregroundStyle(KitColor.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .id("t\(index)").transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 16)
            Spacer(minLength: 0)
            ZStack {
                HStack(spacing: 8) { ForEach(0...IntroModel.last, id: \.self) { KitLed(on: $0 == index) } }
                HStack {
                    Button("Skip") { model.skip() }.buttonStyle(.kitQuiet).focusable(false)
                    Spacer()
                    if model.isLast { Button("Get started") { model.getStarted() }.buttonStyle(.kitPrimary).focusable(false) }
                    else { Button("Next") { model.next() }.buttonStyle(.kitSecondary).focusable(false) }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 640, height: 440)
        .background(KitColor.window)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KitColor.line, lineWidth: 1))
        .sweepAccent()
    }
}
