#if os(macOS)
import CryptoKit
import Foundation
import Security

/// The helper copied out of the app bundle, so its launchd job never runs from inside the app:
/// moving, renaming, re-signing or updating the app leaves the running helper and its job alone.
///
/// `<state>/Helper/Versions/<build>-<code hash>/` holds each build, checked by running it;
/// `Versions/Current/` is a copy of the newest that the helper runs from. It is replaced by
/// swapping a staged copy into its place, never written over, so a running helper's file stays
/// as it was until it restarts into the new one. Builds other than the current one and the one
/// before it are removed.
nonisolated struct HelperInstall {
    static let currentName = "Current"
    static let stagingPrefix = ".staging-"
    /// A staging folder this old is left over from an install that stopped part way.
    static let staleStaging = Duration.seconds(600)

    let bundled: URL
    let versions: URL
    let bundleVersion: String

    init(bundled: URL, stateDirectory: URL, bundleVersion: String) {
        self.bundled = bundled
        self.versions = stateDirectory.appending(path: "Helper/Versions", directoryHint: .isDirectory)
        self.bundleVersion = bundleVersion
    }

    var current: URL { versions.appending(path: Self.currentName, directoryHint: .isDirectory).appending(path: bundled.lastPathComponent) }

    /// Puts the bundled build in `Versions/Current` unless it is there already, and returns the
    /// executable there.
    @concurrent func install() async throws -> URL {
        let files = FileManager.default
        let bundledCode = try Self.codeIdentity(of: bundled)
        try files.createDirectory(at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? Self.codeIdentity(of: current)) == bundledCode {
            prune(keeping: Self.versionName(bundleVersion: bundleVersion, codeIdentity: bundledCode))
            return current
        }
        let name = Self.versionName(bundleVersion: bundleVersion, codeIdentity: bundledCode)
        let version = versions.appending(path: name, directoryHint: .isDirectory)
        if (try? Self.codeIdentity(of: version.appending(path: bundled.lastPathComponent))) != bundledCode {
            let staged = try stage(from: bundled)
            try await Self.verify(staged.appending(path: bundled.lastPathComponent), matches: bundled)
            try? files.removeItem(at: version)
            try files.moveItem(at: staged, to: version)
        }
        let staged = try stage(from: version.appending(path: bundled.lastPathComponent))
        guard try Self.codeIdentity(of: staged.appending(path: bundled.lastPathComponent)) == bundledCode else {
            try? files.removeItem(at: staged)
            throw HelperInstallError.copyDiffers
        }
        try Self.swap(staged, into: versions.appending(path: Self.currentName, directoryHint: .isDirectory))
        prune(keeping: name)
        return current
    }

    /// A new staging folder holding a copy of `executable`, runnable and out of quarantine.
    private func stage(from executable: URL) throws -> URL {
        let files = FileManager.default
        let staging = versions.appending(path: Self.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let copy = staging.appending(path: bundled.lastPathComponent)
        do {
            try files.copyItem(at: executable, to: copy)
            try Self.clearQuarantine(copy)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Puts `staged` at `destination` in one step: an existing folder is swapped out (and then
    /// removed), so the path never names a half-written build and a running helper keeps the
    /// file it started from.
    static func swap(_ staged: URL, into destination: URL) throws {
        let failure: Int32 = staged.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            }
        }
        switch failure {
        case 0:
            try? FileManager.default.removeItem(at: staged)
        case ENOENT:
            try FileManager.default.moveItem(at: staged, to: destination)
        default:
            throw HelperInstallError.system("swapping in the new build", failure)
        }
    }

    /// Removes builds other than `keeping` and the newest one before it, and staging folders
    /// left over from an install that stopped.
    func prune(keeping name: String, now: Date = .now) {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(
            at: versions, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        else { return }
        let versions = entries.map { url in
            Entry(name: url.lastPathComponent,
                  modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for stale in Self.prunable(versions, keeping: name, now: now) {
            try? files.removeItem(at: self.versions.appending(path: stale, directoryHint: .isDirectory))
        }
    }

    nonisolated struct Entry: Equatable {
        var name: String
        var modified: Date
    }

    /// What `prune` removes: every build but `keeping` and the newest other one, and staging
    /// folders older than `staleStaging`. Never `Current`.
    static func prunable(_ entries: [Entry], keeping name: String, now: Date) -> [String] {
        let staging = entries.filter { $0.name.hasPrefix(stagingPrefix) }
        let stale = staging.filter { now.timeIntervalSince($0.modified) > Double(staleStaging.components.seconds) }
        let builds = entries
            .filter { $0.name != currentName && $0.name != name && !$0.name.hasPrefix(stagingPrefix) && !$0.name.hasPrefix(".") }
            .sorted { $0.modified > $1.modified }
        return (stale + builds.dropFirst()).map(\.name)
    }

    /// `<CFBundleVersion>-<first 12 hex digits of the code hash>`: one folder per build, even
    /// for local builds that all share a bundle version.
    static func versionName(bundleVersion: String, codeIdentity: String) -> String {
        let version = String(bundleVersion.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }.drop { $0 == "." })
        return "\(version.isEmpty ? "0" : version)-\(codeIdentity.prefix(12))"
    }

    // MARK: Checks

    /// The code directory hash of a signed executable, else the SHA-256 of its bytes.
    static func codeIdentity(of executable: URL) throws -> String {
        if let hash = codeHash(of: executable) { return hash }
        return try sha256(of: executable)
    }

    static func codeHash(of executable: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of file: URL) throws -> String {
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The copy runs here (signature, hardened runtime, no quarantine prompt) and is the build
    /// in the bundle: the same bytes, and, when the bundle's build is signed, a valid signature
    /// with the same code hash and team.
    static func verify(_ copy: URL, matches bundled: URL) async throws {
        if let bundledHash = codeHash(of: bundled) {
            guard isValidlySigned(copy), codeHash(of: copy) == bundledHash, teamIdentifier(of: copy) == teamIdentifier(of: bundled)
            else { throw HelperInstallError.signatureDiffers }
        }
        let expected = try sha256(of: bundled)
        let output = try await LocalHelper.output(copy, ["build-info", "--json"])
        guard let info = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              info["exe_sha256"] as? String == expected
        else { throw HelperInstallError.copyDiffers }
    }

    private static func isValidlySigned(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    private static func teamIdentifier(of executable: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A copy of a file from a downloaded app keeps its quarantine mark, and the system would
    /// then check it again as a separate download. It is the bundle's own file, already
    /// accepted with the app, and `verify` checks it is the same build before it ever runs as
    /// the helper.
    static func clearQuarantine(_ file: URL) throws {
        let failure: Int32 = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 ? 0 : errno
        }
        guard failure == 0 || failure == ENOATTR else { throw HelperInstallError.system("clearing quarantine", failure) }
    }
}

nonisolated enum HelperInstallError: Error, Equatable, LocalizedError {
    case copyDiffers
    case signatureDiffers
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .copyDiffers: "The copied helper isn't the build in the app."
        case .signatureDiffers: "The copied helper's signature doesn't match the app's."
        case .system(let step, let code): "\(step): \(String(cString: strerror(code)))"
        }
    }
}
#endif
