#if os(macOS)
import Darwin
import Foundation

/// A helper build as `<name>-hostd build-info --json` reports it (every released build does).
nonisolated struct HelperBuild: Equatable, Sendable {
    var version: String
    /// A commit id (with `-dirty`), or `dev` for a build made without the release tooling.
    var build: String
    /// When its source was made, Unix seconds (0 for `dev` builds).
    var builtUnix: UInt64
    var protocolLevel: UInt32

    init(version: String, build: String, builtUnix: UInt64, protocolLevel: UInt32) {
        self.version = version
        self.build = build
        self.builtUnix = builtUnix
        self.protocolLevel = protocolLevel
    }

    init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let version = object["version"] as? String, let build = object["build"] as? String
        else { return nil }
        self.init(
            version: version, build: build,
            builtUnix: (object["built_unix"] as? NSNumber)?.uint64Value ?? 0,
            protocolLevel: (object["protocol"] as? NSNumber)?.uint32Value ?? 0)
    }

    /// Asks the build at `executable`; nil when it is gone, does not run or does not say.
    static func read(_ executable: URL) async -> HelperBuild? {
        guard let output = try? await LocalHelper.output(executable, ["build-info", "--json"]) else { return nil }
        return HelperBuild(json: output)
    }

    /// A lower protocol level, or the same level from an earlier source: the order of
    /// `HelperCheck.isOlder` and the daemon's `DaemonInfo::is_older_than`.
    func isOlder(than other: HelperBuild) -> Bool {
        if protocolLevel != other.protocolLevel { return protocolLevel < other.protocolLevel }
        return build != other.build && builtUnix < other.builtUnix
    }

    /// "0.1.7 (1a2b3c4)".
    var summary: String { Self.summary(version: version, build: build) }

    static func summary(version: String, build: String) -> String {
        let isCommit = build.prefix(while: \.isHexDigit).count >= 7
        return "\(version) (\(isCommit ? String(build.prefix(7)) : build))"
    }
}

/// A helper build against the one the app carries.
nonisolated enum BuildAge: Equatable, Sendable {
    case older
    case same
    case newer

    /// A build that cannot be told counts as older: nothing newer than the app's is lost by
    /// replacing it.
    init(_ build: HelperBuild?, against app: HelperBuild) {
        guard let build else {
            self = .older
            return
        }
        if build.isOlder(than: app) {
            self = .older
        } else if app.isOlder(than: build) {
            self = .newer
        } else {
            self = .same
        }
    }
}

/// The executable a process runs, and whether the file at that path is still the one it
/// started from (not replaced or removed since).
nonisolated struct RunningExecutable: Equatable, Sendable {
    var path: String
    var isOnDisk: Bool

    static func of(pid: Int32) -> RunningExecutable? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let mapped = mappedFile(pid: pid, path: path) else { return RunningExecutable(path: path, isOnDisk: false) }
        var onDisk = stat()
        let isOnDisk = stat(path, &onDisk) == 0 && UInt32(bitPattern: onDisk.st_dev) == mapped.device && onDisk.st_ino == mapped.inode
        return RunningExecutable(path: path, isOnDisk: isOnDisk)
    }

    /// The file behind the process's first memory region mapped from `path`: its text.
    private static func mappedFile(pid: Int32, path: String) -> (device: UInt32, inode: UInt64)? {
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        for _ in 0..<4096 {
            var region = proc_regionwithpathinfo()
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else { return nil }
            let regionPath = withUnsafeBytes(of: region.prp_vip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if regionPath == path {
                let file = region.prp_vip.vip_vi.vi_stat
                return (file.vst_dev, file.vst_ino)
            }
            let next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size
            guard next > address else { return nil }
            address = next
        }
        return nil
    }
}
#endif
