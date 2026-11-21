import Foundation

@MainActor
func agentDiskChecks(in home: URL) throws {
    let fm = FileManager.default, project = home.appendingPathComponent("Projects/Moonrise")
    let common = project.appendingPathComponent(".git")
    let pushed = "a2fa97b0676188582b8a35e6330e99bf40ea2078", local = "b991a8c70ff740b4a15f29bd6801684b8c6f4317"
    func write(_ url: URL, _ data: Data) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func text(_ url: URL, _ value: String) throws { try write(url, Data((value + "\n").utf8)) }
    for (hash, payload) in [
        ("4b825dc642cb6eb9a060e54bf8d69288fbee4904", "eJwrKUpNVTBgAAAKLAIB"),
        (pushed, "eJxLzs/NzSxRMDS1YCgpSk1VMEmyMDJNSTYzMUpOMktNskw0MDNINTVJSrNIMbM0srBIS0pNNbE0MOFKLC3JyC9ScMusKCktSlWwSYMwHDLzyhJzMlPsFAwNYEBBG0RyJYOtKkklSRMXVC0XAE+uM34="),
        (local, "eJyVjjEOwjAQBKn9Cvc0F8e+nCUUUfGPO+csLJEEWQ7i+UDgA2yzU8xKm9Z5Ls06wEOrqtYLuTAl9C4JqkQGBA1eMk0YHVEWVR/BmztXXZpllzkOAjhgRxTICXEfFPseNEbJHpQdDGR4a9e12kt5tq2qPeUvnMvy4FuZRtvBnnfZ4wdM2q81/Wtkfq55AXQRQJs=")
    ] {
        try write(common.appendingPathComponent("objects/\(hash.prefix(2))/\(hash.dropFirst(2))"), Data(base64Encoded: payload)!)
    }
    try text(common.appendingPathComponent("HEAD"), "ref: refs/heads/main")
    try text(common.appendingPathComponent("refs/heads/main"), pushed)
    try text(common.appendingPathComponent("refs/remotes/origin/main"), pushed)
    let trees = [project.appendingPathComponent(".claude/worktrees/clean"), home.appendingPathComponent(".codex/worktrees/dirty"), home.appendingPathComponent("linked/unpushed")]
    for url in trees {
        let name = url.lastPathComponent, admin = common.appendingPathComponent("worktrees/" + name)
        try text(url.appendingPathComponent(".git"), "gitdir: " + admin.path)
        try text(admin.appendingPathComponent("gitdir"), url.path + "/.git")
        try text(admin.appendingPathComponent("commondir"), "../..")
        try text(admin.appendingPathComponent("HEAD"), "ref: refs/heads/" + name)
        try text(common.appendingPathComponent("refs/heads/" + name), name == "unpushed" ? local : pushed)
    }
    try text(trees[1].appendingPathComponent("notes"), "Local draft")
    for path in Scanner.historyPaths { try text(home.appendingPathComponent(path + "/session"), "Demo") }
    let listing = ([project] + trees).map { "worktree \($0.path)\0HEAD \($0 == trees[2] ? local : pushed)\0branch refs/heads/\($0.lastPathComponent)\0\0" }.joined()
    let fixtureQuery: AgentDisk.Query = { url, args in
        switch args {
        case AgentDisk.list: return listing
        case ["rev-parse", "--absolute-git-dir"]: return common.appendingPathComponent("worktrees/" + url.lastPathComponent).path + "\n"
        case ["config", "--name-only", "--list"], ["ls-files", "-v", "--stage", "-z"]: return ""
        case ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored", "--ignore-submodules=none"]: return Scanner.exists(url.appendingPathComponent("notes")) ? "?? notes\0" : ""
        case ["for-each-ref", "--contains=HEAD", "--format=%(refname)", "refs/remotes/"]: return url.path == trees[2].path ? "" : "refs/remotes/origin/main\n"
        default: return nil
        }
    }
    let query: AgentDisk.Query = ProcessInfo.processInfo.environment["SWEEP_TEST_NO_GIT"] == "1" ? fixtureQuery : AgentDisk.git
    let rows = Scanner.find(ScanConfig(roots: [project], home: home, git: query))
    guard let clean = rows.first(where: { $0.id == trees[0].path }) else { SelfTest.check(false, "agent worktree discovery"); return }
    let model = SweepModel(roots: []); model.setItemsForQA(rows)
    SelfTest.check(rows.count == 5 && rows.filter { $0.agent == .unsaved }.count == 2 && rows.filter { $0.agent == .history }.count == 2 && rows.filter(model.selectable).map(\.id) == [clean.id], "three worktrees: only clean pushed is offered; dirty, unpushed and both histories locked")
    model.includeInUse = true
    for row in rows { model.toggle(row) }
    SelfTest.check(model.selected == [clean.id] && model.reclaimable == clean.size, "agent locks and safe total survive Include in use")
    model.setItemsForQA(rows.map { var row = $0; row.modified = .distantPast; return row }); model.selectOlder()
    SelfTest.check(model.selected == [clean.id], "bulk selection excludes protected agent data")
    SelfTest.check(AgentDisk.canTrash(clean, query: query), "clean linked checkout passes fresh Trash check")
    try text(trees[0].appendingPathComponent("notes"), "New draft")
    var attempted = false
    let result = Trasher.trash(rows, git: query, move: { _ in attempted = true; return nil })
    SelfTest.check(!attempted && result.failures.count == rows.count, "Trash rechecks changed worktree and never moves protected rows")
    SelfTest.check(!AgentDisk.canTrash(clean, query: { _, _ in nil }), "unavailable Git fails closed")
}
