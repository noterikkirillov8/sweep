import Foundation

enum XcodeLeftovers {
    static let group = "Xcode"
    static let simulatorID = "xcode:unavailable-simulators"
    static let deleteArgs = ["simctl", "delete", "unavailable"]
    static let command = (["xcrun"] + deleteArgs).joined(separator: " ")
    static let xcrun = "/usr/bin/xcrun"

    static func find(_ cfg: ScanConfig) -> [Found] {
        let library = cfg.home.appendingPathComponent("Library"), developer = library.appendingPathComponent("Developer")
        guard Scanner.isRealDirectory(library), Scanner.isRealDirectory(developer) else { return [] }
        let xcode = developer.appendingPathComponent("Xcode")
        func directories(_ parent: URL) -> [URL] {
            guard Scanner.isRealDirectory(parent) else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: .skipsHiddenFiles)) ?? []).filter(Scanner.isRealDirectory)
        }
        func row(_ url: URL, _ kind: String) -> Found {
            Found(id: url.path, kind: kind, urls: [url], project: group, display: Scanner.relative(url, to: xcode), modified: Scanner.mtime(url))
        }
        var rows: [Found] = []
        if Scanner.isRealDirectory(xcode) {
            for entry in directories(xcode.appendingPathComponent("Archives")) {
                let archives = entry.pathExtension == "xcarchive" ? [entry] : directories(entry)
                for archive in archives where archive.pathExtension == "xcarchive" {
                    let item = row(archive, "Archive")
                    if item.modified != .distantPast, cfg.now.timeIntervalSince(item.modified) > 90 * 86400 { rows.append(item) }
                }
            }
            for platform in ["iOS", "watchOS", "tvOS", "xrOS"] {
                let support = directories(xcode.appendingPathComponent("\(platform) DeviceSupport")).map { row($0, "DeviceSupport") }
                if let newest = support.map(\.modified).max() {
                    rows += support.filter { $0.modified != .distantPast && $0.modified < newest }
                }
            }
        }
        if let exe = cfg.xcrun, FileManager.default.isExecutableFile(atPath: exe),
           let data = Docker.run(exe, ["simctl", "list", "devices", "--json"]),
           let inventory = try? JSONDecoder().decode(Inventory.self, from: data) {
            let ids = Set(inventory.devices.values.joined().filter { $0.isAvailable == false }.compactMap(\.udid))
            if !ids.isEmpty {
                let simulator = developer.appendingPathComponent("CoreSimulator"), devices = simulator.appendingPathComponent("Devices")
                let paths = Scanner.isRealDirectory(simulator) && Scanner.isRealDirectory(devices)
                    ? ids.map { devices.appendingPathComponent($0.uuidString) }.filter(Scanner.isRealDirectory) : []
                rows.append(Found(id: simulatorID, kind: "Simulators", urls: [], project: group, display: "\(ids.count) unavailable \(ids.count == 1 ? "device" : "devices")", modified: .distantPast, size: Scanner.size(of: paths)))
            }
        }
        return rows
    }

    private struct Inventory: Decodable {
        struct Device: Decodable { var isAvailable: Bool?; var udid: UUID? }
        var devices: [String: [Device]]
    }

    static func deleteUnavailable(using exe: String = xcrun) -> Bool {
        FileManager.default.isExecutableFile(atPath: exe) && Docker.run(exe, deleteArgs, timeout: 300) != nil
    }
}
