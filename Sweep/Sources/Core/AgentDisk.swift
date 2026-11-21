import Foundation

enum AgentState: String, Codable, Sendable {
    case pushed, unsaved, unverified, history

    var label: String {
        switch self {
        case .pushed: "Clean and pushed"
        case .unsaved: "Has unsaved work"
        case .unverified: "Protected worktree"
        case .history: "Session history"
        }
    }
}

enum AgentDisk {
    static let group = "Agent worktrees & history"
    static let list = ["worktree", "list", "--porcelain", "-z"]
    typealias Query = @Sendable (URL, [String]) -> String?

    static func overlapsHistory(_ url: URL, home: URL) -> Bool {
        Scanner.historyPaths.contains { path in
            let history = home.appendingPathComponent(path).path, tree = url.path
            return history == tree || history.hasPrefix(tree + "/") || tree.hasPrefix(history + "/")
        }
    }

    static func git(_ directory: URL, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.fileMode=true", "-c", "core.hooksPath=/dev/null", "-C", directory.path, "--work-tree=\(directory.path)"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    struct Tree {
        let url: URL
        let protected: Bool
    }

    static func trees(_ directory: URL, query: Query) -> (String, [Tree])? {
        guard let text = query(directory, list), text.hasSuffix("\0\0") else { return nil }
        let records = text.components(separatedBy: "\0\0").dropLast().map { $0.components(separatedBy: "\0") }
        guard let first = records.first?.first, first.hasPrefix("worktree /") else { return nil }
        let project = URL(fileURLWithPath: String(first.dropFirst(9))).lastPathComponent
        return (project, records.dropFirst().compactMap { fields in
            guard let path = fields.first, path.hasPrefix("worktree /") else { return nil }
            let url = URL(fileURLWithPath: String(path.dropFirst(9)), isDirectory: true)
            guard url.path == url.resolvingSymlinksInPath().path, Scanner.isRealDirectory(url) else { return nil }
            let protected = fields.dropFirst().contains { !$0.hasPrefix("HEAD ") && !$0.hasPrefix("branch refs/heads/") && $0 != "detached" }
            return Tree(url: url, protected: protected)
        })
    }

    static func state(_ tree: Tree, query: Query) -> AgentState {
        let url = tree.url, marker = url.appendingPathComponent(".git")
        guard !tree.protected, let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let path = query(url, ["rev-parse", "--absolute-git-dir"])?.trimmingCharacters(in: .newlines), path.hasPrefix("/"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: path),
              Set(files).isDisjoint(with: ["locked", "MERGE_HEAD", "REBASE_HEAD", "rebase-apply", "rebase-merge", "sequencer", "CHERRY_PICK_HEAD", "BISECT_START", "index.lock"]),
              let backlink = try? String(contentsOfFile: path + "/gitdir", encoding: .utf8), backlink.hasSuffix("\n"),
              URL(fileURLWithPath: String(backlink.dropLast()), relativeTo: URL(fileURLWithPath: path, isDirectory: true)).standardizedFileURL.path == marker.path,
              let config = query(url, ["config", "--name-only", "--list"]), !config.components(separatedBy: "\n").contains(where: { $0.hasPrefix("filter.") }) else { return .unverified }
        guard let index = query(url, ["ls-files", "-v", "--stage", "-z"]), index.split(separator: "\0").allSatisfy({ entry in
            ["H 100644 ", "H 100755 ", "H 120000 "].contains(where: { entry.hasPrefix($0) })
        }) else { return .unverified }
        guard let changes = query(url, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored", "--ignore-submodules=none"]) else { return .unverified }
        guard changes.isEmpty else { return .unsaved }
        guard let refs = query(url, ["for-each-ref", "--contains=HEAD", "--format=%(refname)", "refs/remotes/"]) else { return .unverified }
        return refs.split(separator: "\n").contains(where: { $0.hasPrefix("refs/remotes/") }) ? .pushed : .unsaved
    }

    static func canTrash(_ item: Found, query: Query = git) -> Bool {
        guard item.agent != nil else { return true }
        guard item.agent == .pushed, item.urls.count == 1, let url = item.urls.first, !overlapsHistory(url, home: FileManager.default.homeDirectoryForCurrentUser),
              item.id == url.path, let tree = trees(url, query: query)?.1.first(where: { $0.url.path == url.path }) else { return false }
        return state(tree, query: query) == .pushed
    }
}
