import AppKit
import Carbon
import SwiftUI

@main
@MainActor
final class SweepApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        if CommandLine.arguments.contains("-selftest") { exit(SelfTest.run()) }
        if CommandLine.arguments.contains("-xcode-only"), let index = CommandLine.arguments.firstIndex(of: "-qa"), index + 1 < CommandLine.arguments.count {
            NSApp?.setActivationPolicy(.prohibited)
            exit(QA.xcodeGroup(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("-agents-only"), let index = CommandLine.arguments.firstIndex(of: "-qa"), index + 1 < CommandLine.arguments.count {
            NSApp?.setActivationPolicy(.prohibited)
            exit(QA.agentDisk(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("-free-space-only"), let index = CommandLine.arguments.firstIndex(of: "-qa"), index + 1 < CommandLine.arguments.count {
            NSApp?.setActivationPolicy(.prohibited)
            exit(QA.freeSpace(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("-tool-caches-only"), let index = CommandLine.arguments.firstIndex(of: "-qa"), index + 1 < CommandLine.arguments.count {
            NSApp?.setActivationPolicy(.prohibited)
            exit(QA.toolCaches(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("-roots-only"), let index = CommandLine.arguments.firstIndex(of: "-qa"), index + 1 < CommandLine.arguments.count {
            NSApp?.setActivationPolicy(.prohibited)
            exit(QA.projectFolders(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("-docker-only"), let index = CommandLine.arguments.firstIndex(of: "-qa"), index + 1 < CommandLine.arguments.count {
            exit(QA.dockerDetails(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("-scandump") { SelfTest.dump(); exit(0) }   // read-only scan of the real roots
        let app = NSApplication.shared
        let delegate = SweepApp()
        app.delegate = delegate
        app.setActivationPolicy(Self.quiet ? .prohibited : .accessory)
        app.run()
    }

    static let quiet = CommandLine.arguments.contains("-offscreen")
    let model = SweepModel.shared
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let introPresenter = IntroPresenter()
    private static var poweredOnce = false
    private let totalItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let noticeItem = NSMenuItem(title: "", action: #selector(open), keyEquivalent: "")
    private var weekly: NSBackgroundActivityScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if QA.runIfAsked() { return }
        setUpMainMenu()
        setUpStatusItem()
        makeWindow()
        model.loadCache()
        if !Self.quiet, !UserDefaults.standard.bool(forKey: "introSeen") {
            showIntro(scanOnStart: false)
            Task { await model.findProjectFolders(); model.scan() }
        }
        let register = { (k: KitHotKey?) in
            guard let k else { HotKeys.shared.unregister(1); return }
            HotKeys.shared.register(1, HotKeyPref.carbon(k)) { [weak self] in self?.openWindow() }
        }
        register(HotKeyPref.load())
        SettingsController.shared.onHotKey = register
        SettingsController.shared.onIntro = { [weak self] in self?.showIntro() }
        model.onSettings = { [weak self] in self?.settings() }
        model.onNotice = { [weak self] in self?.updateNotice() }
        model.onWeeklyChange = { [weak self] in self?.updateWeekly() }
        if !Self.quiet { updateWeekly() }
        if CommandLine.arguments.contains("-openOnLaunch") || CommandLine.arguments.contains("-autoscan") { openWindow() }
        if CommandLine.arguments.contains("-autoscan") {
            model.scan()                               // with -perf: scan once, print the numbers, quit
            if Perf.on { Task { while model.phase != .done { try? await Task.sleep(for: .milliseconds(200)) }; exit(0) } }
        }
    }

    /// The window and its view tree are built once at launch; opening only orders it front.
    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Sweep"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 560)
        w.contentView = NSHostingView(rootView: ContentView(model: model))
        w.center()
        window = w
    }

    func openWindow() {
        if introPresenter.isShowing { introPresenter.focus(); return }    // menu, hot key and Scan all land here
        Perf.openStarted()
        model.reclaimNotice = nil
        if window == nil { makeWindow() }
        model.shown = false
        if Self.quiet {                                  // -offscreen: for perf runs, nothing may appear on screen
            window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window?.orderBack(nil)
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
        CATransaction.flush()
        DispatchQueue.main.async {
            Perf.firstFrame(); self.model.shown = true
            if !Self.poweredOnce, !Self.quiet { Self.poweredOnce = true; self.model.powerOn = true }
        }
    }

    /// Drawn template image: a small gauge with a split reclaim strip inside.
    /// With `dot`: a small dot at the top right (the weekly check found a lot to reclaim). The image is 24 wide either way,
    /// the gauge drawn 2 pt in, so it does not move when the dot appears.
    static func statusImage(dot: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 24, height: 14), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let box = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 1.5, width: 17, height: 11), xRadius: 3, yRadius: 3)
            box.lineWidth = 1.3; box.stroke()
            var x: CGFloat = 6
            for w: CGFloat in [6, 3.5, 2.5] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 4.5, width: w, height: 5), xRadius: 0.8, yRadius: 0.8).fill()
                x += w + 1.2
            }
            if dot {
                let c = NSRect(x: 18.6, y: 8.6, width: 5, height: 5)
                NSGraphicsContext.current?.compositingOperation = .clear      // a gap around the dot, like a badge
                NSBezierPath(ovalIn: c.insetBy(dx: -1.4, dy: -1.4)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: c).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.button?.image = Self.statusImage(dot: model.reclaimNotice != nil)
        let menu = NSMenu()
        menu.delegate = self
        noticeItem.target = self; noticeItem.isHidden = true
        menu.addItem(noticeItem)
        menu.addItem(withTitle: "Scan", action: #selector(scan), keyEquivalent: "").target = self
        totalItem.isEnabled = false
        menu.addItem(totalItem)
        menu.addItem(withTitle: "Open Sweep", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Show intro", action: #selector(intro), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Sweep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func updateNotice() { statusItem?.button?.image = Self.statusImage(dot: model.reclaimNotice != nil) }

    /// Once a week, when power and idle time allow: a read-only scan. The result only ever sets the dot.
    private func updateWeekly() {
        weekly?.invalidate(); weekly = nil
        guard model.weeklyCheck else { return }
        let a = NSBackgroundActivityScheduler(identifier: "com.erikkirillov.Sweep.weekly")
        a.repeats = true; a.interval = Weekly.interval; a.tolerance = 24 * 3600; a.qualityOfService = .background
        a.schedule { [weak self] completion in
            guard Weekly.ready(power: Weekly.powerStatus(), idleSeconds: Weekly.idleSeconds()) else { completion(.deferred); return }
            let bytes = Weekly.reclaimable(ScanConfig(roots: SweepModel.savedRoots()))
            Task { @MainActor in self?.model.weeklyResult(bytes); completion(.finished) }
        }
        weekly = a
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        noticeItem.isHidden = model.reclaimNotice == nil
        noticeItem.title = model.reclaimNotice.map { "\(Fmt.bytes($0)) to reclaim" } ?? ""
        totalItem.title = model.lastTotal.map { "Last scan: \(Fmt.bytes($0)) reclaimable" } ?? "Not scanned yet"
    }

    @objc private func scan() { openWindow(); model.scan() }
    @objc private func open() { openWindow() }
    @objc private func intro() { showIntro() }

    /// First launch, or "Show intro". A centred window that fades in and out; marked seen as soon as it is shown,
    /// so a window that fails to appear never repeats. Get started opens the app and scans; any other close just closes.
    private func showIntro(scanOnStart: Bool = true) {
        UserDefaults.standard.set(true, forKey: "introSeen")
        if introPresenter.isShowing { introPresenter.focus(); return }
        window?.orderOut(nil)                             // never the intro and the main window together
        let m = IntroModel()
        m.onClose = { [weak self] in self?.introPresenter.close() }
        introPresenter.onClose = { [weak self, weak m] in
            m?.finish()
            if m?.started == true { self?.openWindow(); if scanOnStart { self?.model.scan() } }
        }
        introPresenter.onNext = { [weak m] in m?.next() }
        introPresenter.onBack = { [weak m] in m?.back() }
        introPresenter.show(IntroView(model: m), size: CGSize(width: 640, height: 440))
        m.start()
    }

    @objc private func settings() { SettingsController.shared.show(model: model) }

    /// Accessory apps get no menu by default; this gives ⌘W, ⌘Q and the edit keys.
    private func setUpMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Sweep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let win = NSMenuItem(); main.addItem(win)
        let winMenu = NSMenu(title: "Window"); win.submenu = winMenu
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
    }
}
