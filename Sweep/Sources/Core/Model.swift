import Foundation
import Observation
import SwiftUI

enum Phase: Equatable { case idle, scanning, done }

enum CleanupConfirmation {
    case review, permanentDockerDeletion, permanentSimulatorDeletion, freeSpace

    var warning: String? {
        switch self {
        case .permanentDockerDeletion: "Docker items won’t go to the Trash. This can’t be undone."
        case .permanentSimulatorDeletion: "These deletions skip the Trash. This can’t be undone."
        default: nil
        }
    }
}

/// The reclaim strip's categories, in fixed order (stable while a scan streams in).
enum Category: Int, CaseIterable, Sendable {
    case node, xcode, python, rust, pods, caches, build, agents, docker

    var name: String {
        switch self {
        case .node: "Node"
        case .xcode: "Xcode"
        case .python: "Python"
        case .rust: "Rust"
        case .pods: "Pods"
        case .caches: "Caches"
        case .build: "Build"
        case .agents: "Agents"
        case .docker: "Docker"
        }
    }

    /// Step on the teal scale (opacity of the accent over graphite).
    var shade: Double { [0.74, 0.62, 0.51, 0.42, 0.34, 0.27, 0.21, 0.19, 0.16][rawValue] }

    static func of(_ kind: String) -> Category {
        switch kind {
        case "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", "Angular cache": .node
        case "SwiftPM .build", "DerivedData", "Xcode DerivedData", "iOS DeviceSupport", "Simulator caches", "Archive", "DeviceSupport", "Simulators": .xcode
        case "Python venv", "__pycache__": .python
        case "Rust target": .rust
        case "CocoaPods": .pods
        case "ignored build output": .build
        case "Worktree", "Session history": .agents
        case "Docker images", "Docker build cache", "Docker containers", "Docker volumes": .docker
        default: .caches
        }
    }
}

struct CatStat: Identifiable, Equatable {
    var cat: Category
    var total: Int64 = 0      // reclaimable bytes (selectable items)
    var picked: Int64 = 0     // selected bytes
    var count = 0
    var id: Int { cat.rawValue }
}

enum ListRow: Identifiable, Equatable {
    case header(name: String, total: Int64?, count: Int)
    case item(Found)
    var id: String {
        switch self {
        case .header(let n, _, _): "h:" + n
        case .item(let f): f.id
        }
    }
}

@MainActor @Observable
final class SweepModel {
    static let shared = SweepModel()
    static let olderThanDays = 30.0

    var roots: [URL] { didSet { UserDefaults.standard.set(roots.map(\.path), forKey: "roots") } }
    private(set) var items: [Found] = []
    private(set) var selected: Set<String> = [] {
        didSet { if selected != oldValue { confirmation = nil } }
    }
    private(set) var phase: Phase = .idle
    var includeInUse = false {
        didSet {
            if !includeInUse { selected = selected.filter { id in !(items.first { $0.id == id }?.inUse() ?? false) } }
            refresh()
        }
    }
    var message: String? { didSet { if message == nil { lastTrashBatch = [] } } }
    var lastTrashBatch: [Trasher.LandedItem] = [] {
        didSet { if confirmation == .freeSpace { confirmation = nil } }
    }
    var offerFreeSpace = UserDefaults.standard.object(forKey: "offerFreeSpace") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(offerFreeSpace, forKey: "offerFreeSpace")
            if !offerFreeSpace && confirmation == .freeSpace { confirmation = nil }
        }
    }
    var canFreeSpace: Bool { offerFreeSpace && !lastTrashBatch.isEmpty }
    var failures: [String] = []
    var lastTotal: Int64? = UserDefaults.standard.object(forKey: "lastTotal") as? Int64
    var filter: Category? { didSet { refresh() } }
    var confirmation: CleanupConfirmation?
    var confirming: Bool {
        get { confirmation != nil }
        set { confirmation = newValue ? .review : nil }
    }
    @ObservationIgnored var onSettings: () -> Void = {}
    /// Set when a scan found Docker answering; the Docker category only exists then.
    var dockerSeen = false
    /// Weekly quiet check: reclaimable bytes when it was over the threshold, else nil. Drives the menu bar dot.
    var reclaimNotice: Int64? = {
        let n = UserDefaults.standard.object(forKey: "reclaimNotice") as? Int64
        return (n ?? 0) > 0 ? n : nil
    }() {
        didSet { UserDefaults.standard.set(reclaimNotice ?? 0, forKey: "reclaimNotice"); onNotice() }
    }
    @ObservationIgnored var onNotice: () -> Void = {}
    var weeklyCheck = UserDefaults.standard.object(forKey: "weeklyCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(weeklyCheck, forKey: "weeklyCheck"); onWeeklyChange() }
    }
    var weeklyGB = UserDefaults.standard.object(forKey: "weeklyGB") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(weeklyGB, forKey: "weeklyGB") }
    }
    @ObservationIgnored var onWeeklyChange: () -> Void = {}
    /// Window entrance (driven by the app on open) and first-show row stagger.
    var shown = true
    /// Set once per session on the first window open: lights the top hairline.
    var powerOn = false
    private(set) var stagger = false
    /// One line under the strip: the folder being read while scanning, a summary afterwards.
    private(set) var status = ""
    /// Set while the list shows the previous scan loaded from disk.
    private(set) var cachedAt: Date?
    private var task: Task<Void, Never>?

    // Derived, rebuilt once per batch (never per row).
    private(set) var stats: [CatStat] = Category.allCases.filter { $0 != .docker && $0 != .agents }.map { CatStat(cat: $0) }
    private(set) var rows: [ListRow] = []
    private(set) var reclaimable: Int64 = 0
    private(set) var reclaimableCount = 0
    private(set) var selectedBytes: Int64 = 0
    private(set) var maxSize: Int64 = 1
    private(set) var projectCount = 0

    /// The folders to scan: the saved list, else ~/Projects and ~/Developer. Also read by the weekly check.
    nonisolated static func savedRoots() -> [URL] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let saved = UserDefaults.standard.stringArray(forKey: "roots")
        return saved?.map { URL(fileURLWithPath: $0) }
            ?? ["Projects", "Developer"].map { home.appendingPathComponent($0) }.filter(Scanner.isRealDirectory)
    }

    init(roots: [URL]? = nil) { self.roots = roots ?? Self.savedRoots() }

    private(set) var findingRoots = false

    func findProjectFolders() async {
        guard !findingRoots else { return }
        findingRoots = true
        let found = await Task.detached(priority: .userInitiated) {
            Scanner.projectRoots(in: FileManager.default.homeDirectoryForCurrentUser)
        }.value
        let existing = Set(roots.map(\.path))
        roots += found.filter { !existing.contains($0.path) }
        findingRoots = false
    }

    /// The weekly check finished: remember the number only when it is worth a dot.
    func weeklyResult(_ bytes: Int64) { reclaimNotice = Weekly.shouldNotify(bytes, thresholdGB: weeklyGB) ? bytes : nil }

    var scanning: Bool { phase == .scanning }
    var sizedCount: Int { items.reduce(0) { $0 + ($1.size == nil ? 0 : 1) } }

    func selectable(_ i: Found) -> Bool { i.selectable(includeInUse: includeInUse) }
    var selectedItems: [Found] { items.filter { selected.contains($0.id) } }

    func toggle(_ i: Found) {
        guard selectable(i) else { return }
        message = nil
        if selected.contains(i.id) { selected.remove(i.id) } else { selected.insert(i.id) }
        refresh()
    }

    func selectOlder() {
        let cutoff = Date().addingTimeInterval(-Self.olderThanDays * 86400)
        message = nil
        selected = Set(items.filter { !$0.permanent && $0.modified < cutoff && $0.selectable() && (filter == nil || Category.of($0.kind) == filter) }.map(\.id))
        refresh()
    }

    func clearSelection() { selected = []; refresh() }

    func pick(_ c: Category) { withAnimation(KitMotion.list) { filter = filter == c ? nil : c } }

    /// Rebuilds the derived values (strip stats, list rows, totals) from `items`, `selected` and `filter`.
    func refresh(now: Date = Date()) {
        var st = Category.allCases.map { CatStat(cat: $0) }
        var reclaim: Int64 = 0, picked: Int64 = 0, big: Int64 = 1, n = 0
        for f in items {
            let c = Category.of(f.kind).rawValue, s = f.size ?? 0
            if f.selectable(includeInUse: includeInUse, now: now) { st[c].total += s; st[c].count += 1; reclaim += s; n += 1 }
            if selected.contains(f.id) { st[c].picked += s; picked += s }
            big = max(big, s)
        }
        let hasAgents = items.contains { $0.agent != nil }
        stats = st.filter { ($0.cat != .docker || dockerSeen) && ($0.cat != .agents || hasAgents) }; reclaimable = reclaim; reclaimableCount = n; selectedBytes = picked; maxSize = big

        var order: [String] = [], by: [String: [Found]] = [:]
        for f in items where filter == nil || Category.of(f.kind) == filter {
            if by[f.project] == nil { order.append(f.project) }
            by[f.project, default: []].append(f)
        }
        projectCount = order.count
        let sorted = phase != .scanning
        var groups = order.map { name -> (String, [Found]) in
            let rs = by[name]!
            return (name, sorted ? rs.sorted { ($0.size ?? -1) > ($1.size ?? -1) } : rs)
        }
        if sorted { groups.sort { $0.1.reduce(0) { $0 + ($1.size ?? 0) } > $1.1.reduce(0) { $0 + ($1.size ?? 0) } } }
        var out: [ListRow] = []
        for (name, rs) in groups {
            let counted = name == AgentDisk.group ? rs.filter(selectable) : rs
            let done = counted.allSatisfy { $0.size != nil }
            out.append(.header(name: name, total: done ? counted.reduce(0) { $0 + ($1.size ?? 0) } : nil, count: rs.count))
            out += rs.map { .item($0) }
        }
        rows = out
    }

    // MARK: QA helpers (fake data only)

    func reset() { items = []; selected = []; phase = .idle; status = ""; lastTotal = nil; refresh() }
    func setItemsForQA(_ f: [Found]) { items = f; phase = .done; status = summary; refresh() }
    func setScanning(status s: String, keepOrder: Bool) { phase = .scanning; status = s; refresh() }
    func keepFirst(_ n: Int) { items = Array(items.prefix(n)); refresh() }
    func setDoneEmpty() { phase = .done; status = summary; refresh() }
    func removeForQA(_ displays: [String]) { items.removeAll { displays.contains($0.display) }; status = summary; refresh() }

    // MARK: Scanning

    func scan() {
        guard !scanning else { return }
        message = nil; failures = []; selected = []; items = []; confirmation = nil; filter = nil; cachedAt = nil; dockerSeen = false
        phase = .scanning; status = "Starting"; refresh()
        let cfg = ScanConfig(roots: roots), feed = ScanFeed()
        Perf.scanStarted()
        task = Task { await runScan(cfg, feed) }
    }

    func cancel() { task?.cancel() }

    /// Walks and sizes in the background; the main actor only applies one batch every ~90 ms.
    private func runScan(_ cfg: ScanConfig, _ feed: ScanFeed) async {
        let docker = Task.detached(priority: .utility) { Docker.items() }      // nil: no docker, or the daemon is not answering
        let finder = Task.detached(priority: .userInitiated) { Scanner.find(cfg, feed: feed); feed.finish() }
        var sizers: [Task<Void, Never>] = []
        var queue: [Found] = [], head = 0, inflight = 0
        var index: [String: Int] = [:]
        var walkEnd: CFAbsoluteTime?
        let limit = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let home = cfg.home, t0 = CFAbsoluteTimeGetCurrent()
        while !Task.isCancelled {
            let b = feed.drain()
            if b.done && walkEnd == nil { walkEnd = CFAbsoluteTimeGetCurrent() }
            queue += b.found.filter { $0.size == nil }
            inflight -= b.sizes.count
            while inflight < limit, head < queue.count {
                let f = queue[head]; head += 1; inflight += 1
                sizers.append(Task.detached(priority: .utility) { feed.setSize(f.id, Scanner.size(of: f.urls)) })
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            withAnimation(KitMotion.list) {
                var arr = items
                for f in b.found { index[f.id] = arr.count; arr.append(f) }
                for (id, s) in b.sizes { if let k = index[id] { arr[k].size = s } }
                items = arr
                status = b.done ? "Measuring sizes, \(head - inflight) of \(queue.count)"
                    : Scanner.tilde(URL(fileURLWithPath: b.path), home)
                refresh()
            }
            Perf.log("batch \(b.found.count) found, \(b.sizes.count) sized, apply \(Perf.ms(since: t1)) ms")
            if b.done && head == queue.count && inflight == 0 { break }
            try? await Task.sleep(for: .milliseconds(90))
        }
        let cancelled = Task.isCancelled
        if cancelled { finder.cancel(); sizers.forEach { $0.cancel() } }
        else if let d = await docker.value {
            withAnimation(KitMotion.list) { dockerSeen = true; items += d; refresh() }
        }
        Perf.log("walk \(walkEnd.map { Int(($0 - t0) * 1000) } ?? -1) ms, total \(Perf.ms(since: t0)) ms, \(items.count) items")
        finish(cancelled: cancelled)
    }

    private func finish(cancelled: Bool) {
        withAnimation(KitMotion.list) {
            if cancelled { items.removeAll { $0.size == nil }; message = "Scan cancelled." }
            phase = .done
            lastTotal = items.filter { $0.selectable() }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            status = summary
            reclaimNotice = nil                          // a fresh scan replaces the weekly number
            refresh()
        }
        if !cancelled { KitSound.play(.confirm) }
        UserDefaults.standard.set(lastTotal, forKey: "lastTotal")
        Perf.scanFinished()
        saveCache()
    }

    var summary: String {
        let n = Set(items.map(\.project)).count
        return items.isEmpty ? "Nothing found" : "\(items.count) \(items.count == 1 ? "folder" : "folders") in \(n) \(n == 1 ? "project" : "projects")"
    }

    // MARK: Trashing (same logic as before: one item at a time, FileManager.trashItem only)

    func authorizeCleanup() -> Bool {
        guard let confirmation, confirmation != .freeSpace, !selectedItems.isEmpty else { return false }
        if confirmation == .review && !selectedCommands.isEmpty {
            self.confirmation = selectedSimulators ? .permanentSimulatorDeletion : .permanentDockerDeletion
            return false
        }
        self.confirmation = nil
        return true
    }

    func confirmCleanup() {
        guard authorizeCleanup() else { return }
        let picked = selectedItems.filter(selectable)
        guard !picked.isEmpty else { return }
        lastTrashBatch = []
        let folders = picked.filter { !$0.permanent }, dockers = picked.filter { $0.docker != nil }
        let simulators = picked.contains(where: \.unavailableSimulators)
        KitSound.play(.thunk)
        Task {
            let r = await Task.detached { Trasher.trash(folders) }.value
            let pruned = await Task.detached { Docker.prune(dockers.compactMap(\.docker)) }.value
            let dockerOK = Set(dockers.filter { pruned[$0.docker!] == true }.map(\.id))
            let simulatorOK = await Task.detached { simulators && XcodeLeftovers.deleteUnavailable() }.value
            var moved = Set(r.movedIDs).union(dockerOK)
            if simulatorOK { moved.insert(XcodeLeftovers.simulatorID) }
            let folderBytes = folders.filter { moved.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let dockerBytes = dockers.filter { dockerOK.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            var failed = r.failures
            if simulators && !simulatorOK { failed.append("\(XcodeLeftovers.command): failed") }
            for d in dockers where !dockerOK.contains(d.id) { failed.append("\(d.docker!.command): failed") }
            withAnimation(KitMotion.list) {
                items.removeAll { moved.contains($0.id) }
                selected.subtract(moved)
                failures = failed
                lastTrashBatch = r.trashed
                var parts: [String] = []
                if folderBytes > 0 { parts.append("Moved \(Fmt.bytes(folderBytes)) to the Trash") }
                else if !r.trashed.isEmpty { parts.append("Moved \(r.trashed.count) \(r.trashed.count == 1 ? "item" : "items") to the Trash") }
                if dockerBytes > 0 { parts.append("Docker removed \(Fmt.bytes(dockerBytes))") }
                if simulatorOK { parts.append("Deleted unavailable simulators") }
                message = parts.isEmpty ? "Nothing was moved." : parts.joined(separator: " and ") + "."
                let total = items.filter { $0.selectable() }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                lastTotal = total; UserDefaults.standard.set(total, forKey: "lastTotal")
                status = summary
                refresh()
            }
            if !failed.isEmpty { KitSound.play(.error) }
            saveCache()
        }
    }

    func confirmFreeSpace() {
        guard confirmation == .freeSpace, canFreeSpace else { return }
        let batch = lastTrashBatch
        lastTrashBatch = []; failures = []
        let progress = "Deleting swept items…"
        message = progress
        Task {
            let deleted = await Task.detached { Trasher.deleteTracked(batch) }.value
            guard message == progress else { return }
            message = deleted == batch.count ? "Deleted \(deleted) swept \(deleted == 1 ? "item" : "items") for good."
                : "Deleted \(deleted) of \(batch.count) swept items. The rest changed or could not be deleted."
        }
    }

    var selectedDockerKinds: [DockerKind] { selectedItems.filter(selectable).compactMap(\.docker) }
    var selectedSimulators: Bool { selected.contains(XcodeLeftovers.simulatorID) }
    var selectedCommands: [String] { selectedDockerKinds.map(\.command) + (selectedSimulators ? [XcodeLeftovers.command] : []) }
    var selectedFolderCount: Int { selectedItems.filter { selectable($0) && !$0.permanent }.count }

    // MARK: Last scan on disk, so the window opens with data

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sweep/last-scan.json")
    }
    private struct Cache: Codable, Sendable { var date: Date; var items: [Found] }

    private func saveCache() {
        let snapshot = Cache(date: Date(), items: items.filter { !$0.permanent && $0.agent == nil })
        Task.detached(priority: .utility) {
            let url = Self.cacheURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// Shows the previous scan right away; rows whose folders are gone are dropped.
    func loadCache() {
        guard phase == .idle, items.isEmpty else { return }
        Task {
            let c: Cache? = await Task.detached(priority: .userInitiated) {
                guard let d = try? Data(contentsOf: Self.cacheURL), var c = try? JSONDecoder().decode(Cache.self, from: d) else { return nil }
                c.items = c.items.filter { $0.kind != "iOS DeviceSupport" && $0.kind != "DeviceSupport" && $0.agent == nil && $0.size != nil && Scanner.validToolCache($0) && $0.urls.contains { Scanner.exists($0) } }
                return c
            }.value
            guard let c, phase == .idle, items.isEmpty, !c.items.isEmpty else { return }
            stagger = true
            withAnimation(KitMotion.list) {
                items = c.items; cachedAt = c.date; phase = .done
                status = summary + ", from the last scan"
                refresh()
            }
            try? await Task.sleep(for: .seconds(1)); stagger = false
            Perf.log("cache shown: \(c.items.count) items")
        }
    }
}

enum Fmt {
    /// Number and unit, decimal units like Finder ("38.4", "GB").
    static func parts(_ n: Int64) -> (String, String) {
        let d = Double(n)
        if d >= 1e12 { return (String(format: "%.2f", d / 1e12), "TB") }
        if d >= 1e9 { return (String(format: "%.1f", d / 1e9), "GB") }
        if d >= 1e6 { return (String(format: "%.0f", d / 1e6), "MB") }
        if d >= 1e3 { return (String(format: "%.0f", d / 1e3), "KB") }
        return ("\(n)", "B")
    }
    static func bytes(_ n: Int64) -> String { let p = parts(n); return p.0 + " " + p.1 }
    /// "now", "5 h", "45 d", "3 mo", "2 y".
    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 3600 { return "now" }
        if s < 86400 { return "\(Int(s / 3600)) h" }
        if s < 86400 * 60 { return "\(Int(s / 86400)) d" }
        if s < 86400 * 730 { return "\(Int(s / (86400 * 30))) mo" }
        return "\(Int(s / (86400 * 365))) y"
    }
}
