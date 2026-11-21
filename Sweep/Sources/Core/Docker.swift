import Foundation

/// What Docker can remove with a prune command. These never go to the Trash.
enum DockerKind: String, Codable, Sendable, CaseIterable {
    case images, buildCache, containers, volumes

    var label: String {
        switch self {
        case .images: "Docker images"
        case .buildCache: "Docker build cache"
        case .containers: "Docker containers"
        case .volumes: "Docker volumes"
        }
    }
    var args: [String] {
        switch self {
        case .images: ["image", "prune", "-f"]
        case .buildCache: ["builder", "prune", "-f"]
        case .containers: ["container", "prune", "-f"]
        case .volumes: ["volume", "prune", "-f"]
        }
    }
    /// Shown word for word in the confirm bar.
    var command: String { "docker " + args.joined(separator: " ") }
    func describe(_ n: Int) -> String {
        switch self {
        case .images: "\(n) dangling \(n == 1 ? "image" : "images")"
        case .buildCache: "\(n) build cache \(n == 1 ? "entry" : "entries")"
        case .containers: "\(n) stopped \(n == 1 ? "container" : "containers")"
        case .volumes: "\(n) unused \(n == 1 ? "volume" : "volumes")"
        }
    }
}

struct DockerUsage: Equatable, Sendable {
    var kind: DockerKind
    var bytes: Int64
    var count: Int
}

/// Talks to the `docker` command line only (never the socket). If the CLI is missing or the daemon does not answer,
/// everything returns nil and the Docker category does not appear.
enum Docker {
    static let extraDirs = ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin"]

    static func find(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", extra: [String] = extraDirs) -> String? {
        for dir in path.split(separator: ":").map(String.init) + extra {
            let p = dir + "/docker"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// "1.2GB", "512kB", "0B", "0B (virtual 1.2GB)" to bytes (decimal like docker, KiB/MiB/GiB binary).
    static func bytes(_ text: String) -> Int64? {
        let first = text.split(separator: " ").first.map(String.init) ?? ""
        guard let i = first.firstIndex(where: { !($0.isNumber || $0 == ".") }), let n = Double(first[..<i]) else { return nil }
        let unit = first[i...].lowercased()
        let mult: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "kib": 1024, "mib": 1048576, "gib": 1073741824, "tib": 1099511627776]
        return mult[unit].map { Int64(n * $0) }
    }

    /// `docker system df -v --format json`: one object with Images, Containers, Volumes and BuildCache lists.
    static func parse(_ data: Data) -> [DockerUsage]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func list(_ k: String) -> [[String: Any]] { (o[k] as? [[String: Any]]) ?? [] }
        func str(_ d: [String: Any], _ k: String) -> String { "\(d[k] ?? "")" }
        func size(_ d: [String: Any], _ keys: String...) -> Int64 { keys.lazy.compactMap { bytes(str(d, $0)) }.first ?? 0 }
        guard o["Images"] != nil || o["Containers"] != nil || o["Volumes"] != nil || o["BuildCache"] != nil else { return nil }
        let dangling = list("Images").filter { str($0, "Repository") == "<none>" && str($0, "Tag") == "<none>" }
        let stopped = list("Containers").filter { ["exited", "created", "dead"].contains(str($0, "State").lowercased()) || str($0, "Status").hasPrefix("Exited") || str($0, "Status").hasPrefix("Created") }
        let unused = list("Volumes").filter { str($0, "Links") == "0" }
        let cache = list("BuildCache").filter { !["true", "1"].contains(str($0, "InUse").lowercased()) }
        return [
            DockerUsage(kind: .images, bytes: dangling.reduce(0) { $0 + size($1, "UniqueSize", "Size") }, count: dangling.count),
            DockerUsage(kind: .buildCache, bytes: cache.reduce(0) { $0 + size($1, "Size") }, count: cache.count),
            DockerUsage(kind: .containers, bytes: stopped.reduce(0) { $0 + size($1, "Size") }, count: stopped.count),
            DockerUsage(kind: .volumes, bytes: unused.reduce(0) { $0 + size($1, "Size") }, count: unused.count),
        ]
    }

    /// Runs the CLI with a time limit; nil on failure or timeout.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 20) -> Data? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        nonisolated(unsafe) var out = Data()
        let reader = DispatchGroup()
        DispatchQueue.global().async(group: reader) { out = pipe.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); reader.wait(); return nil }
        reader.wait()
        return p.terminationStatus == 0 ? out : nil
    }

    static func usage(docker: String) -> [DockerUsage]? {
        run(docker, ["system", "df", "-v", "--format", "json"]).flatMap(parse)
    }

    /// Rows for the list: one per kind that has something to remove. nil when Docker is not there or not running.
    static func items(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", extra: [String] = extraDirs) -> [Found]? {
        guard let docker = find(path: path, extra: extra), let u = usage(docker: docker) else { return nil }
        return u.filter { $0.count > 0 }.map {
            Found(id: "docker:" + $0.kind.rawValue, kind: $0.kind.label, urls: [], project: "Docker", display: $0.kind.describe($0.count),
                  modified: .distantPast, size: $0.bytes, docker: $0.kind)
        }
    }

    /// Runs the prune command of each selected kind, and only those. Returns which ones succeeded.
    static func prune(_ kinds: [DockerKind], path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", extra: [String] = extraDirs) -> [DockerKind: Bool] {
        guard let docker = find(path: path, extra: extra) else { return Dictionary(uniqueKeysWithValues: kinds.map { ($0, false) }) }
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0, run(docker, $0.args, timeout: 300) != nil) })
    }
}
