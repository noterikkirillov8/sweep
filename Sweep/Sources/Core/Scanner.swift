import Foundation

/// One thing Sweep can move to the Trash. Usually a single folder; `__pycache__` folders are
/// grouped per project into one item with several URLs.
struct Found: Identifiable, Sendable, Equatable, Codable {
    var id: String                 // first path; unique per item
    var kind: String               // label shown in the list
    var urls: [URL]
    var project: String            // group in the list
    var display: String            // path relative to the root (or ~/ for global caches)
    var modified: Date
    var size: Int64?               // allocated bytes; nil while still being measured
    var docker: DockerKind? = nil  // set for Docker rows: no paths, removed with a prune command instead of the Trash

    var agent: AgentState? = nil
    var unavailableSimulators: Bool { id == XcodeLeftovers.simulatorID }
    var permanent: Bool { docker != nil || unavailableSimulators }
    func inUse(now: Date = Date()) -> Bool { agent == nil && now.timeIntervalSince(modified) < Scanner.inUseSeconds }
    func selectable(includeInUse: Bool = false, now: Date = Date()) -> Bool {
        (agent == nil || agent == .pushed) && (includeInUse || !inUse(now: now))
    }
}

struct ScanConfig: Sendable {
    var roots: [URL]
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var now: Date = Date()
    var includeGlobal = true
    var xcrun: String? = XcodeLeftovers.xcrun
    var git: AgentDisk.Query = AgentDisk.git
    /// Polled while walking; the weekly check uses it to stop when the system asks it to defer.
    var shouldStop: @Sendable () -> Bool = { false }
}

/// Lock-protected mailbox between the background scan and the UI: the walker pushes finds and the
/// folder it is in, sizers push sizes, the main actor drains everything in one batch per tick.
final class ScanFeed: @unchecked Sendable {
    struct Batch { var found: [Found]; var sizes: [(String, Int64)]; var path: String; var done: Bool }
    private let lock = NSLock()
    private var found: [Found] = [], sizes: [(String, Int64)] = []
    private var path = "", done = false
    func push(_ f: Found) { lock.lock(); found.append(f); lock.unlock() }
    func visit(_ p: String) { lock.lock(); path = p; lock.unlock() }
    func setSize(_ id: String, _ n: Int64) { lock.lock(); sizes.append((id, n)); lock.unlock() }
    func finish() { lock.lock(); done = true; lock.unlock() }
    func drain() -> Batch {
        lock.lock(); defer { lock.unlock() }
        let b = Batch(found: found, sizes: sizes, path: path, done: done)
        found = []; sizes = []
        return b
    }
}

/// Finds well-known rebuildable folders. Read-only: it never changes anything on disk.
enum Scanner {
    static let inUseSeconds: TimeInterval = 24 * 3600
    static let maxDepth = 10
    static let globalGroup = "Global caches"

    // MARK: Finding

    static func projectRoots(in home: URL) -> [URL] {
        let common = ["Projects", "Developer", "code", "Code", "dev", "src", "repos", "workspace", "GitHub"]
        let excluded: Set<String> = ["library", "pictures", "music", "movies", "applications", ".trash", "icloud drive", "desktop", "documents"]
        func children(_ folder: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        }
        let top = children(home)
        var roots = common.compactMap { name in top.first { $0.lastPathComponent == name && isRealDirectory($0) } }
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let github = documents.appendingPathComponent("GitHub", isDirectory: true)
        if isRealDirectory(documents), isRealDirectory(github) { roots.append(github) }
        for folder in top.sorted(by: { $0.path < $1.path }) {
            guard !excluded.contains(folder.lastPathComponent.lowercased()), !roots.contains(folder), isRealDirectory(folder) else { continue }
            if children(folder).contains(where: { child in
                guard isRealDirectory(child) else { return false }
                let marker = child.appendingPathComponent(".git", isDirectory: false)
                let values = try? marker.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                return values?.isSymbolicLink == false && (values?.isRegularFile == true || values?.isDirectory == true)
            }) { roots.append(folder) }
        }
        return roots
    }

    static func find(_ cfg: ScanConfig, feed: ScanFeed? = nil) -> [Found] {
        var out: [String: Found] = [:]
        var pycache: [String: Found] = [:]        // per root + project
        for root in cfg.roots {
            let root = root.standardizedFileURL
            guard isRealDirectory(root) else { continue }
            walk(root, root: root, depth: 0, cfg: cfg, out: &out, pycache: &pycache, feed: feed)
        }
        for p in pycache.values { out[p.id] = p; feed?.push(p) }
        if cfg.includeGlobal { for g in globals(cfg) { out[g.id] = g; feed?.push(g) } }
        return Array(out.values)
    }

    private static let activityFiles: Set<String> = ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "Cargo.lock", "Podfile.lock"]
    private static let projectMarkers = activityFiles.union([".git", "Package.swift", "Cargo.toml", "Podfile", "pyproject.toml", ".gitignore"])

    private static func projectActivity(in dir: URL, names: Set<String>) -> Date {
        var files = names.intersection(activityFiles).map { dir.appendingPathComponent($0) }
        let git = dir.appendingPathComponent(".git")
        if names.contains(".git"), isRealDirectory(git) {
            files += ["HEAD", "index"].map { git.appendingPathComponent($0) }
        }
        return files.reduce(mtime(dir)) { newest, file in
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink == false, let date = values?.contentModificationDate else { return newest }
            return max(newest, date)
        }
    }

    private static func walk(_ dir: URL, root: URL, depth: Int, cfg: ScanConfig, projectDate: Date? = nil, out: inout [String: Found], pycache: inout [String: Found], feed: ScanFeed?) {
        if Task.isCancelled || cfg.shouldStop() || depth > maxDepth { return }
        if historyPaths.contains(where: { let path = cfg.home.appendingPathComponent($0).path; return dir.path == path || dir.path.hasPrefix(path + "/") }) { return }
        feed?.visit(dir.path)
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        else { return }
        let names = Set(kids.map(\.lastPathComponent))
        if names.contains(".git") {
            let marker = dir.appendingPathComponent(".git"), linked = !isRealDirectory(marker)
            if linked {
                let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink == false, values?.isRegularFile == true else { return }
            }
            if (linked || isRealDirectory(marker.appendingPathComponent("worktrees"))), out[dir.path]?.agent == nil,
               let (project, trees) = AgentDisk.trees(dir, query: cfg.git) {
                for tree in trees where out[tree.url.path] == nil && !AgentDisk.overlapsHistory(tree.url, home: cfg.home) {
                    let measurement = measure([tree.url])
                    let row = Found(id: tree.url.path, kind: "Worktree", urls: [tree.url], project: AgentDisk.group,
                                    display: project + " / " + tree.url.lastPathComponent, modified: measurement.modified,
                                    size: measurement.size, agent: AgentDisk.state(tree, query: cfg.git))
                    out[row.id] = row; feed?.push(row)
                }
            }
            if linked { return }
        }
        let activity = !names.isDisjoint(with: projectMarkers) || (depth == 1 && projectDate == nil)
            ? projectActivity(in: dir, names: names) : projectDate
        for url in kids {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard v?.isSymbolicLink != true, v?.isDirectory == true else { continue }   // never follow links
            if name == ".git" || name == ".Trash" { continue }
            let modified = activity ?? v?.contentModificationDate ?? .distantPast

            func add(_ kind: String, _ target: URL = url, _ date: Date = modified) {
                let rel = relative(target, to: root)
                let f = Found(id: target.path, kind: kind, urls: [target], project: project(rel, root), display: rel, modified: date)
                out[f.id] = f
                feed?.push(f)
            }

            if exists(url.appendingPathComponent(".git")) {
                walk(url, root: root, depth: depth + 1, cfg: cfg, projectDate: activity, out: &out, pycache: &pycache, feed: feed)
                continue
            }
            switch name {
            case "node_modules":
                if names.contains("package.json") { add("node_modules") }
                continue                                    // never look inside
            case ".build":
                if names.contains("Package.swift") { add("SwiftPM .build") }
                continue
            case "DerivedData":
                if looksLikeDerivedData(url) { add("DerivedData"); continue }
            case ".venv", "venv":
                if exists(url.appendingPathComponent("pyvenv.cfg")) { add("Python venv"); continue }
            case "__pycache__":
                let rel = relative(url, to: root)
                let proj = project(rel, root)
                let key = root.path + "\u{0}" + proj
                if var g = pycache[key] {
                    g.urls.append(url); g.modified = max(g.modified, modified)
                    g.display = "\(g.urls.count) __pycache__ folders"
                    pycache[key] = g
                } else {
                    pycache[key] = Found(id: url.path, kind: "__pycache__", urls: [url], project: proj,
                                         display: "1 __pycache__ folder", modified: modified)
                }
                continue
            case ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit": add(name); continue
            case ".angular":
                let cache = url.appendingPathComponent("cache")
                if isRealDirectory(cache) { add("Angular cache", cache, activity ?? mtime(cache)) }
                continue
            case "target":
                if names.contains("Cargo.toml") { add("Rust target"); continue }
            case "Pods":
                if names.contains("Podfile") { add("CocoaPods"); continue }
            case "build", "dist", "out":
                if gitignored(name, in: dir, root: root) { add("ignored build output"); continue }
            default: break
            }
            walk(url, root: root, depth: depth + 1, cfg: cfg, projectDate: activity, out: &out, pycache: &pycache, feed: feed)
        }
    }

    /// Xcode's DerivedData holds `<Name>-<hash>` folders with a Build folder or an info.plist; a user folder of that name does not.
    static func looksLikeDerivedData(_ url: URL) -> Bool {
        let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return kids.contains { kid in
            guard kid.lastPathComponent.contains("-"), isRealDirectory(kid) else { return false }
            return isRealDirectory(kid.appendingPathComponent("Build")) || exists(kid.appendingPathComponent("info.plist"))
        }
    }

    /// True when a .gitignore in `dir` or any folder up to the project root lists `name`.
    /// Handles plain names, `name/`, `/name` (only for the .gitignore's own folder), `**/name`.
    static func gitignored(_ name: String, in dir: URL, root: URL) -> Bool {
        var cur = dir.standardizedFileURL
        let stop = root.standardizedFileURL.path
        let projectDepth = root.standardizedFileURL.pathComponents.count + 1
        while cur.path.hasPrefix(stop), cur.path != stop || dir.path == stop {
            if let text = try? String(contentsOf: cur.appendingPathComponent(".gitignore"), encoding: .utf8) {
                for raw in text.split(whereSeparator: \.isNewline) {
                    var line = raw.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
                    if line.hasPrefix("**/") { line.removeFirst(3) }
                    let anchored = line.hasPrefix("/")
                    if anchored { line.removeFirst() }
                    while line.hasSuffix("/") || line.hasSuffix("*") { line.removeLast() }
                    if line == name && (!anchored || cur.path == dir.standardizedFileURL.path) { return true }
                }
            }
            if cur.pathComponents.count <= projectDepth { break }   // do not read above the project folder
            cur = cur.deletingLastPathComponent()
        }
        return false
    }

    // MARK: Global caches

    static let toolCaches = [
        (".gradle/caches", "Gradle cache"), (".cargo/registry/cache", "Cargo cache"),
        ("Library/Caches/go-build", "Go build cache"), ("Library/Caches/pip", "pip cache"),
        ("Library/Caches/Homebrew/downloads", "Homebrew cache"),
    ]

    private static func cacheDirectory(_ path: String, in home: URL) -> URL? {
        var url = home
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
            guard isRealDirectory(url) else { return nil }
        }
        return url
    }

    static func validToolCache(_ item: Found, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard item.project == globalGroup, let target = toolCaches.first(where: { $0.1 == item.kind }) else { return true }
        guard let url = cacheDirectory(target.0, in: home) else { return false }
        return item.urls.map(\.path) == [url.path]
    }

    static let historyPaths = [".claude/projects", ".codex/sessions"]

    static func globals(_ cfg: ScanConfig) -> [Found] {
        let home = cfg.home
        func item(_ url: URL, _ kind: String) -> Found? {
            guard isRealDirectory(url) else { return nil }
            return Found(id: url.path, kind: kind, urls: [url], project: globalGroup,
                         display: tilde(url, home), modified: mtime(url))
        }
        func children(_ url: URL, _ kind: String) -> [Found] {
            let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return kids.compactMap { item($0, kind) }
        }
        let lib = home.appendingPathComponent("Library")
        var all: [Found] = []
        all += children(lib.appendingPathComponent("Developer/Xcode/DerivedData"), "Xcode DerivedData")
        all += XcodeLeftovers.find(cfg)
        let single: [(String, String)] = [
            ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
            (".npm/_cacache", "npm cache"),
            ("Library/pnpm/store", "pnpm store"),
            (".cache/uv", "uv cache"),
        ]
        all += single.compactMap { item(home.appendingPathComponent($0.0), $0.1) }
        all += toolCaches.compactMap { path, kind in cacheDirectory(path, in: home).flatMap { item($0, kind) } }
        all += historyPaths.compactMap { path in
            guard let url = cacheDirectory(path, in: home) else { return nil }
            return Found(id: url.path, kind: "Session history", urls: [url], project: AgentDisk.group,
                         display: "~/" + path, modified: .distantPast, agent: .history)
        }
        return all
    }

    // MARK: Sizes

    /// Allocated bytes of everything inside `url` (links are counted as links, not followed).
    static func size(of urls: [URL]) -> Int64 {
        measure(urls, activity: false).size
    }

    private static func measure(_ urls: [URL], activity: Bool = true) -> (size: Int64, modified: Date) {
        var total: Int64 = 0, modified = Date.distantPast
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey] + (activity ? [.contentModificationDateKey] : [])
        for url in urls {
            let top = try? url.resourceValues(forKeys: Set(keys))
            if let date = top?.contentModificationDate { modified = max(modified, date) }
            total += Int64(top?.totalFileAllocatedSize ?? top?.fileAllocatedSize ?? 0)
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            else { continue }
            for case let f as URL in e {
                if Task.isCancelled { return (total, modified) }
                let v = try? f.resourceValues(forKeys: Set(keys))
                if let date = v?.contentModificationDate { modified = max(modified, date) }
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return (total, modified)
    }

    // MARK: Helpers

    static func relative(_ url: URL, to root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }
    static func project(_ rel: String, _ root: URL) -> String {
        let parts = rel.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : root.lastPathComponent
    }
    static func tilde(_ url: URL, _ home: URL) -> String {
        let p = url.path, h = home.path
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }
    static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func isRealDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }
}

// MARK: Trashing

enum Trasher {
    struct Identity: Equatable, Sendable {
        let device: dev_t, inode: ino_t, generation: UInt32
        let birthSeconds: Int, birthNanoseconds: Int
        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            device = info.st_dev; inode = info.st_ino; generation = info.st_gen
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    struct LandedItem: Sendable {
        let url: URL
        let identity: Identity?
    }

    struct Result: Sendable {
        var movedIDs: [String] = []
        var failures: [String] = []           // "name: reason"
        var trashed: [LandedItem] = []
    }

    static func deleteTracked(_ batch: [LandedItem]) -> Int {
        var deleted = 0
        for item in batch {
            guard let identity = item.identity, Identity(item.url) == identity else { continue }
            let staged = item.url.deletingLastPathComponent().appendingPathComponent("Sweep-\(UUID())")
            guard renamex_np(item.url.path, staged.path, UInt32(RENAME_EXCL)) == 0 else { continue }
            if Identity(staged) == identity, (try? FileManager.default.removeItem(at: staged)) != nil {
                deleted += 1
            } else {
                _ = renamex_np(staged.path, item.url.path, UInt32(RENAME_EXCL))
            }
        }
        return deleted
    }

    /// Moves each item's folders to the Trash, one at a time. Never deletes.
    static func trash(_ items: [Found], git: AgentDisk.Query = AgentDisk.git, move: (URL) throws -> URL? = { url in
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return landed as URL?
    }) -> Result {
        var r = Result()
        for item in items {
            guard AgentDisk.canTrash(item, query: git) else { r.failures.append("\(item.display): worktree or history is protected"); continue }
            guard Scanner.validToolCache(item) else { r.failures.append("\(item.display): cache path changed"); continue }
            var ok = true
            for url in item.urls {
                let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard url.pathComponents.count >= 3, Scanner.exists(url), v?.isSymbolicLink != true else {
                    if Scanner.exists(url) { r.failures.append("\(url.lastPathComponent): refused (link or too close to the top)"); ok = false }
                    continue                                            // already gone is fine
                }
                do {
                    let identity = Identity(url)
                    if let landed = try move(url) { r.trashed.append(LandedItem(url: landed, identity: identity)) }
                } catch {
                    r.failures.append("\(item.display): \(error.localizedDescription)")
                    ok = false
                }
            }
            if ok { r.movedIDs.append(item.id) }
        }
        return r
    }
}
