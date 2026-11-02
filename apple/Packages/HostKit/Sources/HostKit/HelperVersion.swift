import Foundation
import GudoCore

// What the app bundles (`cargo xtask build-hostd-linux` → `hostd-manifest.json` and the
// gzipped daemons) against what a host runs (`DaemonInfo`, sent before `Welcome`), and the
// machine's name for new hosts. Pure values, so the rules are unit tested
// (docs/APP-ARCHITECTURE.md §14).

/// One daemon build the app bundles.
nonisolated public struct BundledDaemon: Codable, Equatable, Sendable {
    /// Resource file name (`gudo-hostd-x86_64-linux.gz`).
    public var file: String
    /// `linux`.
    public var os: String
    /// `x86_64`, `aarch64`.
    public var arch: String
    /// Commit id (with `-dirty`), as the daemon reports it.
    public var build: String
    /// When its source was made, Unix seconds.
    public var builtUnix: UInt64
    /// Protocol level.
    public var `protocol`: UInt32

    enum CodingKeys: String, CodingKey {
        case file, os, arch, build
        case builtUnix = "built_unix"
        case `protocol`
    }

    public init(file: String, os: String, arch: String, build: String, builtUnix: UInt64, protocol: UInt32) {
        self.file = file
        self.os = os
        self.arch = arch
        self.build = build
        self.builtUnix = builtUnix
        self.protocol = `protocol`
    }
}

/// The daemons the app bundles, from `hostd-manifest.json` next to them.
nonisolated public struct BundledDaemons: Equatable, Sendable {
    public var builds: [BundledDaemon]
    /// Where the files are (the app's resources).
    public var directory: URL

    public init(builds: [BundledDaemon], directory: URL) {
        self.builds = builds
        self.directory = directory
    }

    /// Reads a manifest; nil when there is none (a build without bundled daemons).
    public static func load(manifest url: URL) -> BundledDaemons? {
        struct Manifest: Decodable { var builds: [BundledDaemon] }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return BundledDaemons(builds: manifest.builds, directory: url.deletingLastPathComponent())
    }

    /// The build for a host's OS and CPU.
    public func build(os: String, arch: String) -> BundledDaemon? {
        builds.first { $0.os == os && $0.arch == arch }
    }

    public func path(of build: BundledDaemon) -> String {
        directory.appending(path: build.file).path
    }
}

/// What to tell the user about a host's helper, and how it can be updated.
nonisolated public struct HelperAdvice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Works, but the app has a newer build: offer it quietly.
        case update
        /// This app cannot work with the helper until it is updated.
        case required
        /// The helper is newer than this app: update the app (nothing to do on the host).
        case appTooOld
    }

    /// How an update would reach the host.
    public enum Method: Equatable, Sendable {
        /// Over the host's saved SSH login (hosts set up from SSH): upload and restart, as
        /// "Install Helper" does.
        case ssh
        /// Streamed over the daemon connection; the daemon swaps and restarts itself.
        case connection
        /// No way from here (a helper that cannot replace itself, no SSH login).
        case none
    }

    public var kind: Kind
    public var method: Method
    /// The bundled build to install (nil for SSH updates of helpers that do not say what they
    /// run: bootstrap picks the build itself).
    public var bundled: BundledDaemon?
    /// One line for a notice or a host row.
    public var message: String

    public var canUpdate: Bool { kind != .appTooOld && method != .none }
}

/// The rules for offering a helper update (docs/APP-ARCHITECTURE.md §14).
nonisolated public enum HelperCheck {
    /// - Parameters:
    ///   - info: what the daemon reported (nil: it predates reporting, or nothing yet).
    ///   - reported: whether the connection got that far (a `daemonInfo` event arrived).
    ///   - incompatible: why the core cannot work with the daemon, if it said so.
    ///   - bundled: the app's daemons.
    ///   - canSSH: the host has a saved SSH login (it was set up from SSH).
    ///   - isGuest: joined with an invite (only the owner may update).
    ///   - appProtocol / minDaemonProtocol: this core's levels (`protocolLevel()`,
    ///     `minDaemonProtocol()`).
    public static func assess(
        info: DaemonInfo?, reported: Bool, incompatible: String?, bundled: BundledDaemons?,
        canSSH: Bool, isGuest: Bool, appProtocol: UInt32, minDaemonProtocol: UInt32
    ) -> HelperAdvice? {
        guard !isGuest else { return nil }
        if let info, info.minClientProtocol > appProtocol {
            return HelperAdvice(
                kind: .appTooOld, method: .none, bundled: nil,
                message: "This host's helper is newer than the app. Update the app to connect.")
        }
        let target = info.flatMap { bundled?.build(os: $0.os, arch: $0.arch) }
        func method(_ build: BundledDaemon?) -> HelperAdvice.Method {
            if canSSH, bundled != nil { return .ssh }
            if let info, info.selfUpgrade, build != nil { return .connection }
            return .none
        }
        let tooOld = incompatible != nil || (info.map { $0.protocol < minDaemonProtocol } ?? false)
        if tooOld {
            if let info, info.protocol > appProtocol {
                return HelperAdvice(
                    kind: .appTooOld, method: .none, bundled: nil,
                    message: "This host's helper is newer than the app. Update the app to connect.")
            }
            let how = method(target)
            return HelperAdvice(
                kind: .required, method: how, bundled: target,
                message: how == .none
                    ? "This host's helper is too old for this app. Reinstall it over SSH to connect."
                    : "This host's helper is too old for this app. Update it to connect.")
        }
        guard reported else { return nil }
        guard let info else {
            // A helper from before version reporting: older than anything bundled. Only SSH
            // can replace it.
            guard canSSH, bundled != nil else { return nil }
            return HelperAdvice(kind: .update, method: .ssh, bundled: nil, message: "A newer helper is available.")
        }
        guard let target, isOlder(info, than: target) else { return nil }
        let how = method(target)
        guard how != .none else { return nil }
        return HelperAdvice(kind: .update, method: how, bundled: target, message: "A newer helper is available.")
    }

    /// Whether the running helper is older than `bundled`: a lower protocol level, or the same
    /// level from an earlier source (a different build; developer builds report 0).
    public static func isOlder(_ info: DaemonInfo, than bundled: BundledDaemon) -> Bool {
        if info.protocol != bundled.protocol { return info.protocol < bundled.protocol }
        return info.build != bundled.build && info.builtUnix < bundled.builtUnix
    }
}

/// Host names from the machine.
nonisolated public enum MachineName {
    /// The name to give a host from its machine's host name: the first label, without the
    /// domain (`build-server-01.example.com` → `build-server-01`); nil when there is
    /// nothing useful (empty, `localhost`).
    public static func display(_ hostname: String) -> String? {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // An address is not a name to split on dots.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) || trimmed.contains(":") { return trimmed }
        let first = trimmed.split(separator: ".", omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        guard !first.isEmpty, first.lowercased() != "localhost" else { return nil }
        return first
    }

    /// Whether a saved host's name was given by the app rather than the user, for records
    /// from before names were tracked: the ticket's "Host 1a2b3c4d", the test hooks' "test
    /// daemon", or a "just ssh" host named after the address typed.
    public static func looksDefault(_ record: HostRecord) -> Bool {
        let name = record.name.trimmingCharacters(in: .whitespaces)
        if let daemonId = record.daemonId, name == "Host \(daemonId.prefix(8))" { return true }
        if name.lowercased().hasPrefix("test daemon") { return true }
        if let ssh = record.ssh, ssh.alias == nil, name == ssh.host { return true }
        return false
    }
}
