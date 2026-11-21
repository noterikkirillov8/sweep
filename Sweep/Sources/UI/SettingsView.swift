import AppKit
import Carbon
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable { case general = "General", scan = "Scan", about = "About" }

/// The global hot key, kept as JSON in UserDefaults; default is ⌃⌥S.
enum HotKeyPref {
    static let key = "sweepHotKey"
    static let fallback = KitHotKey(keyCode: UInt16(kVK_ANSI_S), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, display: "⌃⌥S")

    static func load() -> KitHotKey? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        if data == Data("null".utf8) { return nil }
        return (try? JSONDecoder().decode(KitHotKey.self, from: data)) ?? fallback
    }
    static func save(_ k: KitHotKey?) {
        UserDefaults.standard.set(k.flatMap { try? JSONEncoder().encode($0) } ?? Data("null".utf8), forKey: key)
    }
    static func carbon(_ k: KitHotKey) -> HotKeys.Combo {
        let f = NSEvent.ModifierFlags(rawValue: k.modifiers)
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return .init(keyCode: UInt32(k.keyCode), modifiers: UInt32(m))
    }
}

struct SettingsView: View {
    @Bindable var model: SweepModel
    @AppStorage("sweepSettingsTab") private var tab: SettingsTab = .general
    @State private var hotKey: KitHotKey? = HotKeyPref.load()
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        KitSettings(title: "Sweep settings", tabs: SettingsTab.allCases.map { ($0, $0.rawValue) }, selection: $tab) { t in
            switch t {
            case .general: general
            case .scan: scan
            case .about: KitAboutView(name: "Sweep", tagline: "Finds rebuildable dev folders and moves them to the Trash.",
                                      repoURL: URL(string: "https://github.com/noterikkirillov8/sweep"))
            }
        }
        .sweepAccent()
        .onChange(of: hotKey) { _, k in HotKeyPref.save(k); SettingsController.shared.onHotKey(k) }
    }

    @ViewBuilder private var general: some View {
        KitSection {
            KitToggleRow(title: "Offer to free space right away", isOn: $model.offerFreeSpace)
            KitToggleRow(title: "Launch at login", isOn: $login)
                .onChange(of: login) { _, on in try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
            KitRow(title: "Open Sweep", detail: "Global shortcut for the window") { KitHotKeyField(hotKey: $hotKey) }
            KitRow(title: "Intro") { Button("Show intro") { SettingsController.shared.onIntro() }.buttonStyle(.kitSecondary) }
        }
        KitSoundSection()
    }

    var projectFolders: some View {
        KitSection(title: "Folders to scan") {
            KitRow(title: "Project folders") {
                Button(model.findingRoots ? "Finding folders…" : "Find project folders") { Task { await model.findProjectFolders() } }
                    .buttonStyle(.kitSecondary).disabled(model.findingRoots)
            }
            ForEach(model.roots, id: \.path) { r in
                KitRow(title: Scanner.tilde(r, FileManager.default.homeDirectoryForCurrentUser)) {
                    KitIconButton(symbol: "minus", help: "Remove") { model.roots.removeAll { $0 == r } }
                }
            }
            KitRow(title: "Add folder") { KitIconButton(symbol: "plus", help: "Add folder") { add() } }
        }
    }

    @ViewBuilder private var scan: some View {
        projectFolders
        KitSection(title: "Weekly check", footer: "Scans once a week while the Mac is on power and idle. Nothing is shown unless the total passes the limit, and nothing is ever moved.") {
            KitToggleRow(title: "Check once a week", isOn: $model.weeklyCheck)
            KitRow(title: "Show a dot above") {
                KitSegmented(selection: $model.weeklyGB, options: [(5, "5 GB"), (10, "10 GB"), (20, "20 GB"), (50, "50 GB")]).frame(width: 300)
            }
            .disabled(!model.weeklyCheck)
        }
    }

    private func add() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls where !model.roots.contains(u) { model.roots.append(u) } }
    }
}

/// One Settings window for the app's life; created on first use.
@MainActor
final class SettingsController {
    static let shared = SettingsController()
    var onHotKey: (KitHotKey?) -> Void = { _ in }
    var onIntro: () -> Void = {}
    private var window: NSWindow?

    func show(model: SweepModel) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(KitColor.window)
        w.contentView = NSHostingView(rootView: SettingsView(model: model))
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
