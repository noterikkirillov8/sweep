import Foundation

/// `Sweep -selftest`: builds a fake tree under $TMPDIR, checks the matcher, sizes and trashing.
/// Never touches real folders.
enum SelfTest {
    nonisolated(unsafe) static var failed = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failed += 1 }
    }

    /// Prints what a real scan would find. Read-only.
    @MainActor static func dump() {
        let m = SweepModel()
        let found = Scanner.find(ScanConfig(roots: m.roots)).map { f -> Found in var f = f; f.size = f.size ?? Scanner.size(of: f.urls); return f }
        for f in found.sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }) {
            print("\(Fmt.bytes(f.size ?? 0))\t\(f.kind)\t\(f.display)\(f.inUse() ? "\t[in use]" : "")")
        }
        print("total \(found.count) items, \(Fmt.bytes(found.reduce(0) { $0 + ($1.size ?? 0) }))")
    }

    @MainActor static func dockerConfirmationChecks() {
        let model = SweepModel()
        let folder = Found(id: "folder", kind: "node_modules", urls: [], project: "demo", display: "demo/node_modules", modified: .distantPast, size: 1)
        let docker = Found(id: "docker", kind: DockerKind.images.label, urls: [], project: "Docker", display: "1 dangling image", modified: .distantPast, size: 1, docker: .images)
        model.setItemsForQA([folder, docker])
        model.toggle(folder); model.confirming = true
        check(model.authorizeCleanup(), "folders need only the normal Trash confirmation")
        for mixed in [false, true] {
            model.clearSelection(); model.toggle(docker)
            if mixed { model.toggle(folder) }
            model.confirming = true
            check(!model.authorizeCleanup() && model.confirmation?.warning == "Docker items won’t go to the Trash. This can’t be undone.", "\(mixed ? "mixed" : "Docker-only") cleanup requires the permanent-deletion warning")
            check(model.authorizeCleanup() && !model.authorizeCleanup(), "explicit Docker confirmation authorizes cleanup only once")
        }
        model.confirming = true; _ = model.authorizeCleanup(); model.toggle(folder)
        check(!model.authorizeCleanup(), "changing the selection invalidates Docker confirmation")
    }

    @MainActor static func run() -> Int32 {
        check(Weekly.ready(power: (true, nil), idleSeconds: 301) && !Weekly.ready(power: (true, nil), idleSeconds: 300), "weekly: AC requires more than 5 idle minutes")
        check([50.0, 85.0].allSatisfy { Weekly.ready(power: (false, $0), idleSeconds: 301) } && !Weekly.ready(power: (false, 100), idleSeconds: 300), "weekly: battery at or above 50% qualifies only while idle")
        check(!Weekly.ready(power: (false, 49), idleSeconds: 900) && !Weekly.ready(power: (false, nil), idleSeconds: 900), "weekly: low or unknown battery defers even while idle")
        if ProcessInfo.processInfo.environment["SWEEP_WEEKLY_TESTS_ONLY"] == "1" { return failed == 0 ? 0 : 1 }
        let rootsOnly = CommandLine.arguments.contains("-roots-only")
        if !rootsOnly { dockerConfirmationChecks() }
        if CommandLine.arguments.contains("-docker-only") { return failed == 0 ? 0 : 1 }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sweep-test-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), root = home.appendingPathComponent("Projects")
        let old = Date().addingTimeInterval(-100 * 86400)

        func dir(_ p: String) { try? fm.createDirectory(at: base.appendingPathComponent(p), withIntermediateDirectories: true) }
        func file(_ p: String, _ text: String = "x", bytes: Int = 0) {
            let u = base.appendingPathComponent(p)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (bytes > 0 ? Data(count: bytes) : Data(text.utf8)).write(to: u)
        }
        let common = ["Projects", "Developer", "code", "Code", "dev", "src", "repos", "workspace", "GitHub"]
        for name in common { dir("common/\(name)") }
        let commonHome = base.appendingPathComponent("common")
        let actualNames = (try? fm.contentsOfDirectory(atPath: commonHome.path)) ?? []
        check(!actualNames.isEmpty && Scanner.projectRoots(in: commonHome).map(\.lastPathComponent).sorted() == actualNames.sorted(), "project roots: conventional folders without duplicate case aliases")

        dir("nested/Documents/GitHub"); dir("nested/Documents/Other/.git")
        check(Scanner.projectRoots(in: base.appendingPathComponent("nested")).map(\.path) == [base.appendingPathComponent("nested/Documents/GitHub").path], "project roots: Documents/GitHub but not Documents itself")

        dir("custom/Workshop/Atlas/.git"); file("custom/Worktrees/Fern/.git", "gitdir: elsewhere")
        for name in ["Library", "Pictures", "Music", "Movies", "Applications", ".Trash", "iCloud Drive", "Desktop", "Documents"] { dir("custom/\(name)/Atlas/.git") }
        dir("custom/TooDeep/First/Second/.git"); dir("custom/LinkedChild"); dir("custom/LinkedMarker/Atlas")
        for (link, target) in [("Projects", "Workshop"), ("LinkedChild/Atlas", "Workshop/Atlas"), ("LinkedMarker/Atlas/.git", "Workshop/Atlas/.git")] {
            try? fm.createSymbolicLink(at: base.appendingPathComponent("custom/\(link)"), withDestinationURL: base.appendingPathComponent("custom/\(target)"))
        }
        check(Scanner.projectRoots(in: base.appendingPathComponent("custom")).map(\.lastPathComponent) == ["Workshop", "Worktrees"], "project roots: direct child repositories only; excluded folders and symlinks skipped")
        if rootsOnly { return failed == 0 ? 0 : 1 }
        do { try agentDiskChecks(in: base.appendingPathComponent("agent-fixture").resolvingSymlinksInPath()) }
        catch { check(false, "agent fixture: \(error)") }

        let P = "home/Projects"
        // Matches
        file("\(P)/web/package.json"); file("\(P)/web/node_modules/a/index.js", bytes: 200_000)
        file("\(P)/web/node_modules/a/node_modules/b/x.js")          // nested, must not match
        file("\(P)/web/.next/cache/x", bytes: 10_000); file("\(P)/web/.nuxt/x"); file("\(P)/web/.turbo/x")
        file("\(P)/web/.parcel-cache/x"); file("\(P)/web/.svelte-kit/x"); file("\(P)/web/.angular/cache/x")
        file("\(P)/swiftpkg/Package.swift"); file("\(P)/swiftpkg/.build/x", bytes: 5_000)
        file("\(P)/swiftpkg/DerivedData/x")
        file("\(P)/py/.venv/pyvenv.cfg"); file("\(P)/py/venv/pyvenv.cfg")
        file("\(P)/py/a/__pycache__/x.pyc"); file("\(P)/py/b/__pycache__/y.pyc")
        file("\(P)/rust/Cargo.toml"); file("\(P)/rust/target/x", bytes: 8_000)
        file("\(P)/ios/Podfile"); file("\(P)/ios/Pods/x")
        file("\(P)/site/.gitignore", "node_modules\ndist/\n/out\n"); file("\(P)/site/dist/x"); file("\(P)/site/out/x")
        file("\(P)/site/packages/ui/dist/x")                          // pattern "dist" matches at any depth
        // Traps
        file("\(P)/trap1/node_modules/x")                              // no package.json
        file("\(P)/trap2/target/x")                                    // no Cargo.toml
        file("\(P)/trap3/build/x"); file("\(P)/trap3/.gitignore", "*.log\n")
        file("\(P)/trap4/.git/node_modules/x"); file("\(P)/trap4/package.json")
        file("\(P)/trap5/venv/x")                                      // venv without pyvenv.cfg
        file("\(P)/trap6/.gitignore", "/build\n"); file("\(P)/trap6/sub/build/x")   // anchored: only top-level
        dir("big/inside"); file("big/inside/huge", bytes: 1_000_000)
        file("\(P)/trap7/package.json")
        try? fm.createSymbolicLink(at: root.appendingPathComponent("trap7/node_modules"), withDestinationURL: base.appendingPathComponent("big"))
        try? fm.createSymbolicLink(at: root.appendingPathComponent("trap8"), withDestinationURL: base.appendingPathComponent("big"))
        // Fresh manifest in a project with a 40-day-old install.
        file("\(P)/fresh/package.json"); file("\(P)/fresh/node_modules/x")
        // Global caches in fake home
        file("home/Library/Developer/Xcode/DerivedData/App-1/x", bytes: 3_000)
        file("home/Library/Developer/Xcode/iOS DeviceSupport/old/x"); file("home/Library/Developer/Xcode/iOS DeviceSupport/new/x")
        file("home/Library/Developer/Xcode/Archives/keep/x"); file("home/Library/Developer/CoreSimulator/Devices/keep/x")
        file("home/Library/Developer/CoreSimulator/Caches/x"); file("home/Library/Caches/Homebrew/x")
        let cachePaths = [".gradle/caches", ".cargo/registry/cache", "Library/Caches/go-build", "Library/Caches/pip", "Library/Caches/Homebrew/downloads"]
        file("home/go/pkg/mod/demo/x"); file("home/.cargo/registry/src/demo/x"); file("home/.gradle/wrapper/x")
        let globalConfig = ScanConfig(roots: [], home: home, xcrun: nil)
        check(Scanner.find(globalConfig).allSatisfy { !cachePaths.contains(String($0.display.dropFirst(2))) && $0.kind != "Homebrew cache" }, "missing tool caches produce no rows")
        for path in cachePaths { dir("home/\(path)") }
        file("home/.npm/_cacache/x"); file("home/Library/pnpm/store/x"); file("home/.cache/uv/x")
        file("home/Library/Caches/Other/x")
        // Age everything except "fresh" and the "new" DeviceSupport
        let keepFresh: Set<String> = ["fresh", "new"]
        if let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for case let u as URL in e where !u.pathComponents.contains(where: keepFresh.contains) {
                try? fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path)
            }
        }
        let installDate = Date().addingTimeInterval(-40 * 86400)
        for path in ["fresh/node_modules", "fresh"] {
            try? fm.setAttributes([.modificationDate: installDate], ofItemAtPath: root.appendingPathComponent(path).path)
        }

        let cfg = ScanConfig(roots: [root], home: home, now: Date(), includeGlobal: true, xcrun: nil)
        let found = Scanner.find(cfg)
        let got = Set(found.map { Scanner.tilde($0.urls[0].standardizedFileURL, base.standardizedFileURL).replacingOccurrences(of: "~/", with: "") })
        let expected: Set<String> = [
            "web/node_modules", "web/.next", "web/.nuxt", "web/.turbo", "web/.parcel-cache", "web/.svelte-kit", "web/.angular/cache",
            "swiftpkg/.build", "swiftpkg/DerivedData", "py/.venv", "py/venv", "rust/target", "ios/Pods",
            "site/dist", "site/out", "site/packages/ui/dist", "fresh/node_modules",
        ].reduce(into: Set<String>()) { $0.insert("\(P)/\($1)") }
        .union(["py/a/__pycache__"].map { "\(P)/\($0)" })   // group id = first __pycache__ found (either a or b)
        .union(["home/Library/Developer/Xcode/DerivedData/App-1", "home/Library/Developer/Xcode/iOS DeviceSupport/old",
                "home/Library/Developer/CoreSimulator/Caches", "home/.npm/_cacache", "home/Library/pnpm/store", "home/.cache/uv"])
        .union(cachePaths.map { "home/\($0)" })
        let cacheRows = found.filter { cachePaths.contains(String($0.display.dropFirst(2))) }
        check(cacheRows.count == 5 && cacheRows.allSatisfy { row in
            let expectedPath = home.appendingPathComponent(String(row.display.dropFirst(2))).path
            return row.project == Scanner.globalGroup && row.docker == nil && Scanner.validToolCache(row, home: home) && row.urls.map(\.path) == [expectedPath]
        }, "five tool caches are individual Trash rows; Go modules and cache siblings excluded")
        if var brew = cacheRows.first(where: { $0.kind == "Homebrew cache" }) {
            brew.urls = [home.appendingPathComponent("Library/Caches/Homebrew")]
            check(!Scanner.validToolCache(brew, home: home), "old Homebrew parent row cannot be restored or trashed")
        }
        dir("linked-home")
        try? fm.createSymbolicLink(at: base.appendingPathComponent("linked-home/.cargo"), withDestinationURL: home.appendingPathComponent(".cargo"))
        check(Scanner.find(ScanConfig(roots: [], home: base.appendingPathComponent("linked-home"))).isEmpty, "linked Cargo registry parent skipped")
        var gotAdj = got
        if gotAdj.contains("\(P)/py/b/__pycache__") { gotAdj.remove("\(P)/py/b/__pycache__"); gotAdj.insert("\(P)/py/a/__pycache__") }
        check(gotAdj == expected, "matcher returns exactly the expected set (\(found.count) items)")
        if gotAdj != expected {
            print("  missing: \(expected.subtracting(gotAdj).sorted())"); print("  extra: \(gotAdj.subtracting(expected).sorted())")
        }
        let py = found.first { $0.kind == "__pycache__" }
        check(py?.urls.count == 2 && py?.project == "py", "__pycache__ grouped per project (2 folders)")
        check(found.first { $0.display == "fresh/node_modules" }?.inUse() == true, "fresh node_modules flagged in use")
        check(found.first { $0.display == "web/node_modules" }?.inUse() == false, "old node_modules not in use")
        let model = SweepModel()
        model.setItemsForQA(found); model.selectOlder()
        let older = Set(model.selectedItems.map(\.display))
        check(Scanner.mtime(root.appendingPathComponent("fresh/node_modules")) < Date().addingTimeInterval(-30 * 86400)
              && older.contains("web/node_modules") && !older.contains("fresh/node_modules"),
              "fresh package.json keeps 40-day-old node_modules out of Select older")
        check(!found.contains { $0.display.contains("trap") }, "no trap folder matched")

        let nm = found.first { $0.display == "web/node_modules" }!
        let sz = Scanner.size(of: nm.urls)
        check(sz >= 200_000 && sz < 400_000, "node_modules size is allocated size (\(sz) bytes)")
        do { try xcodeChecks(home: base.appendingPathComponent("xcode-fixture")) }
        catch { check(false, "Xcode fixture: \(error)") }
        if ProcessInfo.processInfo.environment["SWEEP_SCANNER_TESTS_ONLY"] == "1" { return failed == 0 ? 0 : 1 }

        // Trash: only the selected items move.
        let pick = found.filter { ["web/.nuxt", "web/.turbo"].contains($0.display) || $0.kind == "__pycache__" }
        let trash = base.appendingPathComponent("Fake Trash")
        file("Fake Trash/__pycache__/keep")
        let r = Trasher.trash(pick, move: { url in
            let landed = trash.appendingPathComponent("\(url.lastPathComponent)-\(UUID())", isDirectory: true)
            try fm.moveItem(at: url, to: landed)
            return landed
        })
        check(r.failures.isEmpty && r.movedIDs.count == 3, "trashed 3 selected items, no failures")
        check(pick.allSatisfy { $0.urls.allSatisfy { !fm.fileExists(atPath: $0.path) } }, "selected folders are gone from the tree")
        check(["web/.next", "web/node_modules", "py/.venv"].allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }, "unselected folders untouched")
        check(r.trashed.count == 4 && r.trashed.allSatisfy { $0.url.deletingLastPathComponent().path == trash.path && Scanner.exists($0.url) }, "items landed in the fake Trash")
        if let restored = r.trashed.first {
            let putBack = base.appendingPathComponent("put-back")
            try? fm.moveItem(at: restored.url, to: putBack)
            try? fm.createDirectory(at: restored.url, withIntermediateDirectories: false)
            let deleted = Trasher.deleteTracked(r.trashed)
            check(deleted == 3 && r.trashed.dropFirst().allSatisfy { !Scanner.exists($0.url) }
                  && Scanner.exists(putBack) && Scanner.exists(restored.url) && Scanner.exists(trash.appendingPathComponent("__pycache__/keep")),
                  "free space deletes only tracked URLs in fake Trash; unrelated, restored and replacement items stay")
        }
        // A symlink must be refused.
        let sl = base.appendingPathComponent("link-test")
        try? fm.createSymbolicLink(at: sl, withDestinationURL: base.appendingPathComponent("big"))
        let r2 = Trasher.trash([Found(id: sl.path, kind: "x", urls: [sl], project: "x", display: "x", modified: old)])
        check(r2.movedIDs.isEmpty && fm.fileExists(atPath: base.appendingPathComponent("big/inside/huge").path), "symlink refused, target intact")

        // Docker: a fake `docker` shim on a private PATH, never the real CLI or daemon.
        let bin = base.appendingPathComponent("shim"), down = base.appendingPathComponent("shim-down")
        for d in [bin, down] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let fixture = #"""
        {"Images":[{"Repository":"<none>","Tag":"<none>","Size":"1.2GB","UniqueSize":"1.1GB"},{"Repository":"<none>","Tag":"<none>","Size":"300MB"},{"Repository":"node","Tag":"20","Size":"1.1GB"}],
         "Containers":[{"State":"exited","Status":"Exited (0) 2 days ago","Size":"10MB (virtual 1.2GB)"},{"State":"running","Status":"Up 3 hours","Size":"5MB (virtual 1GB)"}],
         "Volumes":[{"Name":"a","Links":"0","Size":"12MB"},{"Name":"b","Links":"1","Size":"900MB"}],
         "BuildCache":[{"InUse":false,"Size":"2.5GB"},{"InUse":true,"Size":"700MB"}]}
        """#
        try? fixture.write(to: bin.appendingPathComponent("fixture.json"), atomically: true, encoding: .utf8)
        let shim = bin.appendingPathComponent("docker")
        try? "#!/bin/sh\nD=$(dirname \"$0\")\necho \"$@\" >> \"$D/log\"\nif [ \"$1 $2\" = \"system df\" ]; then cat \"$D/fixture.json\"; else echo done; fi\n".write(to: shim, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 1\n".write(to: down.appendingPathComponent("docker"), atomically: true, encoding: .utf8)
        for u in [shim, down.appendingPathComponent("docker")] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        let u = Docker.parse(Data(fixture.utf8))
        check(u?.map(\.count) == [2, 1, 1, 1] && u?[0].bytes == 1_400_000_000 && u?[1].bytes == 2_500_000_000 && u?[2].bytes == 10_000_000 && u?[3].bytes == 12_000_000,
              "docker parse: dangling images, idle build cache, stopped containers, unused volumes only")
        check(Docker.bytes("1.5GB") == 1_500_000_000 && Docker.bytes("512kB") == 512_000 && Docker.bytes("0B (virtual 1GB)") == 0 && Docker.bytes("2MiB") == 2_097_152 && Docker.bytes("N/A") == nil, "docker sizes")
        check(Docker.parse(Data("not json".utf8)) == nil && Docker.parse(Data("{}".utf8)) == nil, "docker parse: garbage is not docker")
        let items = Docker.items(path: bin.path, extra: [])
        check(items?.count == 4 && items?.allSatisfy { $0.urls.isEmpty && $0.docker != nil && Category.of($0.kind) == .docker && !$0.inUse() } == true, "docker items: four rows, no paths, never in use")
        check(Docker.items(path: down.path, extra: []) == nil, "docker daemon not answering: no category")
        check(Docker.items(path: base.appendingPathComponent("nothing").path, extra: []) == nil, "docker not installed: no category")
        let ran = Docker.prune([.images, .volumes], path: bin.path, extra: [])
        let log = (try? String(contentsOf: bin.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        check(ran[.images] == true && ran[.volumes] == true && log.contains("image prune -f") && log.contains("volume prune -f")
              && !log.contains("builder") && !log.contains("container prune"), "docker prune runs only the selected kinds")
        check(DockerKind.volumes.command == "docker volume prune -f" && DockerKind.buildCache.command == "docker builder prune -f", "docker confirm shows the exact command")

        // Weekly check
        check(Weekly.shouldNotify(10_000_000_000, thresholdGB: 10) && !Weekly.shouldNotify(9_999_999_999, thresholdGB: 10) && !Weekly.shouldNotify(99, thresholdGB: 0), "weekly: dot only at or above the threshold")
        let wk = Weekly.reclaimable(ScanConfig(roots: [root], home: home, now: Date(), includeGlobal: false), dockerPath: bin.path, dockerExtra: [])
        let oldFolders = found.filter { !$0.inUse() && !$0.urls.isEmpty && !$0.display.hasPrefix("home") && $0.project != Scanner.globalGroup && Scanner.exists($0.urls[0]) }
        let dockerBytes: Int64 = 1_400_000_000 + 2_500_000_000 + 10_000_000 + 12_000_000
        check(wk >= dockerBytes && wk < dockerBytes + 2_000_000 && oldFolders.count > 0, "weekly: folder sizes plus docker, in-use and global caches left out (\(wk))")
        introFlowChecks { check($0, $1) }
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        return failed == 0 ? 0 : 1
    }

    @MainActor private static func xcodeChecks(home: URL) throws {
        let fm = FileManager.default, now = Date(timeIntervalSince1970: 1_600_000_000)
        let developer = home.appendingPathComponent("Library/Developer")
        func folder(_ path: String, days: Double) throws -> URL {
            let url = developer.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 42, count: 16_384).write(to: url.appendingPathComponent("payload"))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
            return url
        }
        let archive = try folder("Xcode/Archives/2026-01-01/Orbit.xcarchive", days: 91)
        _ = try folder("Xcode/Archives/2026-01-01/Keep.xcarchive", days: 90)
        _ = try folder("Xcode/Archives/2026-01-01/Notes", days: 120)
        try fm.createSymbolicLink(at: archive.deletingLastPathComponent().appendingPathComponent("Link.xcarchive"), withDestinationURL: archive)
        var expected = [archive]
        for platform in ["iOS", "watchOS", "tvOS", "xrOS"] {
            for (name, days) in [("older", 7.0), ("latest", 2), ("tie", 2)] {
                let support = try folder("Xcode/\(platform) DeviceSupport/\(name)", days: days)
                if name == "older" { expected.append(support) }
            }
        }
        let missing = home.appendingPathComponent("missing").path
        var cfg = ScanConfig(roots: [], home: home, now: now, xcrun: missing)
        let folders = Scanner.find(cfg)
        let fixture = developer.resolvingSymlinksInPath()
        func relative(_ url: URL) -> String { Scanner.relative(url.resolvingSymlinksInPath(), to: fixture) }
        var routed: [String] = []
        let result = Trasher.trash(folders, move: { routed.append(relative($0)); return nil })
        check(result.failures.isEmpty && routed.sorted() == expected.map(relative).sorted() && folders.allSatisfy { !$0.permanent && $0.project == "Xcode" }, "Xcode: only archives over 90 days and older support per platform go to Trash")
        if routed.sorted() != expected.map(relative).sorted() { print("  expected: \(expected.map(relative).sorted()); found: \(routed.sorted())") }
        check(!folders.contains(where: \.unavailableSimulators), "Xcode: missing xcrun omits simulators")
        let offline = UUID(), online = UUID()
        let device = try folder("CoreSimulator/Devices/\(offline.uuidString)", days: 5)
        _ = try folder("CoreSimulator/Devices/\(online.uuidString)", days: 5)
        let shim = home.appendingPathComponent("xcrun")
        try """
        #!/bin/sh
        case "$*" in
          'simctl list devices --json') echo '{"devices":{"runtime":[{"udid":"\(offline)","isAvailable":false},{"udid":"\(online)","isAvailable":true}]}}' ;;
          'simctl delete unavailable') exit 0 ;;
          *) exit 1 ;;
        esac
        """.write(to: shim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        cfg.xcrun = shim.path
        guard let sim = XcodeLeftovers.find(cfg).first(where: \.unavailableSimulators) else { check(false, "Xcode: unavailable simulator row"); return }
        check(sim.display == "1 unavailable device" && sim.size == Scanner.size(of: [device]) && sim.urls.isEmpty && sim.permanent, "Xcode: only unavailable devices count toward the permanent row size")
        let model = SweepModel(roots: []); model.setItemsForQA(folders + [sim]); model.selectOlder()
        check(!model.selectedSimulators, "Xcode: age selection never selects simulator deletion")
        let folder = Found(id: "archive", kind: "Archive", urls: [], project: "Xcode", display: "Orbit.xcarchive", modified: .distantPast, size: 1)
        model.setItemsForQA([folder, sim]); model.clearSelection(); model.toggle(folder); model.toggle(sim); model.confirming = true
        check(!model.authorizeCleanup() && model.confirmation == .permanentSimulatorDeletion && model.selectedCommands == ["xcrun simctl delete unavailable"], "Xcode: mixed cleanup requires the extra permanent confirmation")
        check(model.authorizeCleanup() && !model.authorizeCleanup() && XcodeLeftovers.deleteUnavailable(using: shim.path), "Xcode: one-time approval and exact delete command via fake xcrun")
    }
}
