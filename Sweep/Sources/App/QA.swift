import AppKit
import SwiftUI

/// `Sweep -qa <dir>`: renders the real views with fake data to PNGs, then quits.
@MainActor
enum QA {
    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(where: { $0 == "-qa" || $0 == "-intro-preview" }), i + 1 < args.count else { return false }
        let introOnly = args[i] == "-intro-preview"
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.prohibited)           // QA never shows or activates anything
        Task {
            if !introOnly { await run(dir) }
            await introShots(dir)
            NSApp.terminate(nil)
        }
        return true
    }

    /// Realistic rows (names and sizes modelled on a read-only -scandump of ~/Projects). `done` sizes everything.
    static func fake(sized: Int = .max, docker: Bool = false) -> SweepModel {
        let m = SweepModel()
        m.roots = [URL(fileURLWithPath: NSHomeDirectory() + "/Projects")]
        let now = Date(), day = 86400.0
        var n = 0
        func f(_ kind: String, _ proj: String, _ rel: String, _ mb: Double, _ days: Double) -> Found {
            n += 1
            return Found(id: proj + rel, kind: kind, urls: [], project: proj, display: rel,
                         modified: now.addingTimeInterval(-days * day), size: n <= sized ? Int64(mb * 1e6) : nil)
        }
        let g = Scanner.globalGroup
        var docks: [Found] = []
        if docker {
            m.dockerSeen = true
            for (k, c, mb) in [(DockerKind.images, 7, 3420.0), (.buildCache, 41, 6150), (.containers, 3, 84), (.volumes, 2, 520)] {
                docks.append(Found(id: "docker:" + k.rawValue, kind: k.label, urls: [], project: "Docker", display: k.describe(c),
                                   modified: .distantPast, size: Int64(mb * 1e6), docker: k))
            }
        }
        m.setItemsForQA(docks + [
            f("Xcode DerivedData", g, "~/Library/Developer/Xcode/DerivedData/Marlin-dkqzrjv", 8420, 6),
            f("Xcode DerivedData", g, "~/Library/Developer/Xcode/DerivedData/Quarry-bwfpaxo", 3180, 9),
            f("iOS DeviceSupport", g, "~/Library/Developer/Xcode/iOS DeviceSupport/iPhone16,1 18.2", 2940, 130),
            f("npm cache", g, "~/.npm/_cacache", 2310, 25),
            f("Homebrew cache", g, "~/Library/Caches/Homebrew/downloads", 1720, 40),
            f("uv cache", g, "~/.cache/uv", 960, 12),
            f("Simulator caches", g, "~/Library/Developer/CoreSimulator/Caches", 410, 64),
            f("Rust target", "fern", "fern/tools/target", 3920, 70),
            f("node_modules", "orbit", "orbit/node_modules", 1180, 4),
            f("ignored build output", "orbit", "orbit/dist", 310, 18),
            f("node_modules", "orbit", "orbit/app/node_modules", 640, 18),
            f("DerivedData", "marlin", "marlin/DerivedData", 5610, 33),
            f("CocoaPods", "marlin", "marlin/ios/Pods", 740, 33),
            f("SwiftPM .build", "quarry", "quarry/.build", 2140, 12),
            f("SwiftPM .build", "press", "press/.build", 1630, 2),
            f("SwiftPM .build", "harbor", "harbor/.build", 6200, 0.1),
            f("Python venv", "artemis", "artemis/.venv", 1120, 90),
            f("__pycache__", "artemis", "14 __pycache__ folders", 22, 3),
            f("node_modules", "field-notes", "field-notes/node_modules", 1420, 45),
            f(".next", "field-notes", "field-notes/web/.next", 620, 0.3),
            f("node_modules", "paper-planes", "paper-planes/node_modules", 880, 120),
            f("node_modules", "atlas-web", "atlas-web/node_modules", 530, 1.5),
            f(".turbo", "atlas-web", "atlas-web/.turbo", 14, 1.5),
            f("Python venv", "night-owl", "night-owl/.venv", 2480, 41),
            f("node_modules", "night-owl", "night-owl/ui/node_modules", 770, 41),
        ])
        return m
    }

    static func run(_ dir: URL) async {
        _ = xcodeGroup(dir)
        _ = agentDisk(dir)
        let idle = SweepModel(); idle.reset(); await shot(idle, "01-idle", dir)
        // The scan moment: start, middle, late, end (figure, strip segments and rows grow as items are measured).
        let early = SweepModel(); early.reset(); early.setScanning(status: "~/Projects/marlin/Marlin/Views", keepOrder: true)
        await shot(early, "02a-scan-start", dir)
        let mid = fake(sized: 8); mid.keepFirst(10); mid.setScanning(status: "~/Projects/night-owl/ui/src/components", keepOrder: true)
        await shot(mid, "02b-scan-middle", dir)
        let late = fake(sized: 19); late.setScanning(status: "Measuring sizes, 19 of 25", keepOrder: true)
        await shot(late, "02c-scan-late", dir)
        let end = fake(); end.setItemsForQA(end.items); await shot(end, "02d-scan-end", dir)
        // Window entrance: first frame (hidden) and settled.
        let ent = fake(); ent.shown = false; await shot(ent, "17-entrance-start", dir)
        let res = fake(); await shot(res, "04-results", dir)
        let sel = fake(); sel.selectOlder(); await shot(sel, "05-selected", dir)
        let filt = fake(); filt.selectOlder(); filt.filter = .xcode; await shot(filt, "06-filtered", dir)
        let conf = fake(); conf.selectOlder(); conf.confirming = true; await shot(conf, "07-confirm", dir)
        let inuse = fake(); inuse.includeInUse = true; inuse.filter = .xcode; inuse.selectOlder(); inuse.toggle(inuse.items.first { $0.display == "harbor/.build" }!); await shot(inuse, "08-include-in-use", dir)
        let done = fake(); done.removeForQA(["fern/tools/target", "marlin/DerivedData", "quarry/.build"])
        done.lastTrashBatch = ["target", "DerivedData", "build"].map { .init(url: dir.appendingPathComponent($0), identity: nil) }
        done.message = "Moved 11.7 GB to the Trash."; await shot(done, "09-done", dir)
        _ = freeSpace(dir)
        let fail = fake(); fail.selectOlder(); fail.failures = ["field-notes/node_modules: permission denied"]
        fail.lastTrashBatch = Array(done.lastTrashBatch.prefix(1))
        fail.message = "Moved 1.1 GB to the Trash."; await shot(fail, "10-failure", dir)
        let nothing = SweepModel(); nothing.reset(); nothing.setDoneEmpty(); await shot(nothing, "11-nothing-found", dir)
        let one = SweepModel(); one.reset(); one.setItemsForQA([fake().items[8]]); await shot(one, "12-one-item", dir)
        // Docker: category in the strip and legend, rows, confirm with the exact commands (Docker only, and mixed with folders).
        let dk = fake(docker: true); dk.filter = .docker; await shot(dk, "18-docker-results", dir)
        let dkSel = fake(docker: true); for d in dkSel.items where d.docker == .buildCache || d.docker == .images { dkSel.toggle(d) }
        dkSel.filter = .docker; dkSel.confirmation = .permanentDockerDeletion; await shot(dkSel, "19-docker-confirm", dir)
        let dkMix = fake(docker: true); dkMix.selectOlder(); for d in dkMix.items where d.docker == .volumes { dkMix.toggle(d) }
        dkMix.confirmation = .permanentDockerDeletion; await shot(dkMix, "20-docker-confirm-with-folders", dir)
        let dkDone = fake(docker: true); dkDone.removeForQA(["7 dangling images"]); dkDone.message = "Docker removed 3.4 GB."; await shot(dkDone, "21-docker-done", dir)
        let dkLight = fake(docker: true); dkLight.filter = .docker; await shot(dkLight, "22-docker-filtered-light", dir, appearance: .aqua)
        await settingsShots(dir)
        menuBarShots(dir)
        await shot(fake(), "14-results-light", dir, appearance: .aqua)
        let sl = fake(); sl.selectOlder(); await shot(sl, "15-selected-light", dir, appearance: .aqua)
        let il = SweepModel(); il.reset(); await shot(il, "16-idle-light", dir, appearance: .aqua)
    }

    static func agentDisk(_ dir: URL) -> Int32 {
        let model = SweepModel(roots: [])
        let fixtures: [(String, AgentState, Int64, Double)] = [
            ("Moonrise / paper-lantern", .pushed, 4200, 43), ("Moonrise / night-ferry", .unsaved, 760, 2),
            ("Moonrise / cloud-atlas", .unsaved, 680, 18), ("~/.claude/projects", .history, 390, 0), ("~/.codex/sessions", .history, 140, 0)
        ]
        model.setItemsForQA(fixtures.map { name, state, mb, days in
            Found(id: name, kind: state == .history ? "Session history" : "Worktree", urls: [], project: AgentDisk.group,
                  display: name, modified: Date().addingTimeInterval(-days * 86400), size: mb * 1_000_000, agent: state)
        })
        let view = VStack(spacing: 0) {
            ForEach(model.rows) { row in
                switch row {
                case .header(let name, let total, let count): GroupHeader(name: name, total: total, count: count)
                case .item(let item): ItemRow(item: item, on: false, selectable: model.selectable(item), maxSize: model.maxSize, model: model, stagger: nil)
                }
            }
        }.padding(.bottom, KitSpace.m).frame(width: 760).background(KitColor.window).sweepAccent().environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("agent-worktrees.png")); return 0
        } catch { print(error); return 1 }
    }

    static func freeSpace(_ dir: URL) -> Int32 {
        let model = SweepModel(roots: [])
        model.message = "Moved 1.2 GB to the Trash."
        model.lastTrashBatch = ["cache", "build"].map { .init(url: dir.appendingPathComponent($0), identity: nil) }
        func write<V: View>(_ view: V, _ name: String) throws {
            let renderer = ImageRenderer(content: view.frame(width: 760).background(KitColor.window).sweepAccent().environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: dir.appendingPathComponent(name))
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write(ContentView(model: model).bottomBar, "free-space-result.png")
            model.confirmation = .freeSpace
            try write(ConfirmBar(model: model), "free-space-confirm.png")
            return 0
        } catch { print(error); return 1 }
    }

    static func toolCaches(_ dir: URL) -> Int32 {
        let model = SweepModel(roots: [])
        let rows = zip(Scanner.toolCaches, [1840, 690, 410, 230, 160]).map { target, mb in
            Found(id: target.0, kind: target.1, urls: [], project: Scanner.globalGroup, display: "~/" + target.0,
                  modified: Date().addingTimeInterval(-40 * 86400), size: Int64(mb) * 1_000_000)
        }
        model.setItemsForQA(rows)
        let view = VStack(spacing: 0) {
            GroupHeader(name: Scanner.globalGroup, total: model.reclaimable, count: rows.count)
            ForEach(rows) { item in
                ItemRow(item: item, on: false, selectable: true, maxSize: model.maxSize, model: model, stagger: nil)
            }
        }.padding(.bottom, KitSpace.m).frame(width: 760).background(KitColor.window).sweepAccent().environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("tool-caches.png"))
            return 0
        } catch { print(error); return 1 }
    }

    static func xcodeGroup(_ dir: URL) -> Int32 {
        let model = SweepModel(roots: [])
        let examples: [(String, String, Int64, Double)] = [
            ("Archive", "Archives/2026-02-12/Orbit.xcarchive", 3_420_000_000, 160),
            ("DeviceSupport", "iOS DeviceSupport/18.2", 1_870_000_000, 50),
            ("DeviceSupport", "xrOS DeviceSupport/2.1", 950_000_000, 43),
            ("DeviceSupport", "tvOS DeviceSupport/18.1", 620_000_000, 36),
            ("DeviceSupport", "watchOS DeviceSupport/11.1", 490_000_000, 28)
        ]
        let folders = examples.map { kind, path, bytes, days in
            Found(id: path, kind: kind, urls: [], project: "Xcode", display: path, modified: Date().addingTimeInterval(-days * 86400), size: bytes)
        }
        model.setItemsForQA(folders + [Found(id: XcodeLeftovers.simulatorID, kind: "Simulators", urls: [], project: "Xcode", display: "2 unavailable devices", modified: .distantPast, size: 2_410_000_000)])
        let view = VStack(spacing: 0) {
            ForEach(model.rows) { row in
                switch row {
                case let .header(name, total, count): GroupHeader(name: name, total: total, count: count)
                case let .item(item): ItemRow(item: item, on: false, selectable: true, maxSize: model.maxSize, model: model, stagger: nil)
                }
            }
        }.padding(.vertical, KitSpace.m).frame(width: 760).background(KitColor.window).sweepAccent().environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("xcode-group.png")); return 0
        } catch { print(error); return 1 }
    }

    static func dockerDetails(_ dir: URL) -> Int32 {
        let model = SweepModel()
        let rows = DockerKind.allCases.map { kind in
            Found(id: kind.rawValue, kind: kind.label, urls: [], project: "Docker", display: kind.describe(3), modified: .distantPast, size: 480_000_000, docker: kind)
        }
        model.setItemsForQA(rows); model.toggle(rows[0]); model.confirming = true
        guard !model.authorizeCleanup(), model.confirmation?.warning != nil else { return 1 }
        func write<V: View>(_ view: V, _ name: String) throws {
            let renderer = ImageRenderer(content: view.frame(width: 760).background(KitColor.window).sweepAccent().environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: dir.appendingPathComponent(name))
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write(VStack(spacing: 0) {
                ForEach(rows) { item in
                    ItemRow(item: item, on: model.selected.contains(item.id), selectable: true, maxSize: model.maxSize, model: model, stagger: nil)
                }
            }, "docker-rows.png")
            try write(ConfirmBar(model: model), "docker-permanent-confirm.png")
            return 0
        } catch { print(error); return 1 }
    }

    /// The standard Settings window, every tab, plus light; rendered without a window on screen.
    static func settingsShots(_ dir: URL) async {
        let m = projectFoldersModel()
        for (n, t) in SettingsTab.allCases.enumerated() {
            UserDefaults.standard.set(t.rawValue, forKey: "sweepSettingsTab")
            await render(SettingsView(model: m), size: NSSize(width: 520, height: 560), name: "13-settings-\(n + 1)-\(t.rawValue.lowercased())", dir)
        }
        UserDefaults.standard.set("General", forKey: "sweepSettingsTab")
        await render(SettingsView(model: m), size: NSSize(width: 520, height: 560), name: "13-settings-light", dir, appearance: .aqua)
    }

    private static func projectFoldersModel() -> SweepModel {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SweepModel(roots: ["Projects", "Documents/GitHub", "Workshop"].map { home.appendingPathComponent($0, isDirectory: true) })
    }

    static func projectFolders(_ dir: URL) -> Int32 {
        let view = SettingsView(model: projectFoldersModel()).projectFolders
            .padding(20).frame(width: 520).background(KitColor.window).sweepAccent().environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("settings-project-folders.png"))
            return 0
        } catch { print(error); return 1 }
    }

    private static func render<V: View>(_ view: V, size: NSSize, name: String, _ dir: URL, appearance: NSAppearance.Name = .darkAqua) async {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.contentView = NSHostingView(rootView: view)
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000)); w.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(600))
        if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        w.orderOut(nil)
    }

    /// The menu bar icon with and without the weekly-check dot, 4x, on a dark and a light bar.
    static func menuBarShots(_ dir: URL) {
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(320 * scale), pixelsHigh: Int(56 * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (half, dark) in [(0, true), (1, false)] {
            let bar = NSRect(x: CGFloat(half) * 160 * scale, y: 0, width: 160 * scale, height: 56 * scale)
            (dark ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.85, blue: 0.83, alpha: 1)).setFill(); bar.fill()
            for (i, dot) in [false, true].enumerated() {
                let img = SweepApp.statusImage(dot: dot)
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r); (dark ? NSColor.white : NSColor.black).setFill(); r.fill(using: .sourceIn); return true
                }
                tinted.draw(in: NSRect(x: bar.minX + (26 + CGFloat(i) * 60) * scale, y: 14 * scale, width: 24 * scale, height: 14 * scale))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("23-menu-bar-dot.png"))
    }

    /// Start, middle and end frame of every intro scene, rendered off-screen like the rest.
    static func introShots(_ dir: URL) async {
        for s in 0..<IntroCopy.titles.count {
            for (name, t) in [("start", 0.0), ("mid", IntroCopy.mids[s]), ("end", IntroCopy.durations[s] - 0.3)] {
                let demo = Demo(scene: s)
                demo.prime(to: t)
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: .darkAqua)
                w.isOpaque = false; w.backgroundColor = .clear
                w.contentView = NSHostingView(rootView: IntroView(model: IntroModel(index: s, preview: demo)))
                w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                w.orderBack(nil)
                try? await Task.sleep(for: .milliseconds(1100))
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("intro-\(s + 1)-\(name).png"))
                }
                w.orderOut(nil)
            }
        }
    }

    static func shot(_ model: SweepModel, _ name: String, _ dir: URL, appearance: NSAppearance.Name = .darkAqua) async {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.contentView = NSHostingView(rootView: ContentView(model: model, qaChrome: true))
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        w.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(700))
        if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        w.orderOut(nil)
    }
}
