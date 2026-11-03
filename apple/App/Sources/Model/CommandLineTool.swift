#if os(macOS)
import AppKit
import Foundation

/// The helper's short command in every terminal (`gudo pair`, `gudo devices`): a link in
/// `~/.local/bin` to the helper in the app bundle, made without administrator rights. Gudo's own
/// terminals have it already (the helper puts it on their `PATH`).
enum CommandLineTool {
    enum Status: Equatable {
        /// This build has no helper.
        case unavailable
        case notInstalled
        case installed
        /// Something else has the name: a file, or a link elsewhere. Left alone.
        case taken(String)
    }

    static var helper: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(Brand.daemonBinary)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    static func link(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appending(path: Brand.commandLineTool)
    }

    static func status(helper: URL? = helper, link: URL = link()) -> Status {
        guard let helper else { return .unavailable }
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) else {
            return manager.fileExists(atPath: link.path) ? .taken(link.path) : .notInstalled
        }
        if destination == helper.path { return .installed }
        // A link to an earlier copy of the app (moved or renamed) is ours to replace.
        return destination.hasSuffix("/Contents/MacOS/\(Brand.daemonBinary)") ? .notInstalled : .taken(destination)
    }

    /// Links the command to this app's helper, replacing a link to an earlier copy of the app.
    static func install(helper: URL? = helper, link: URL = link()) throws {
        guard let helper else { throw InstallError.noHelper }
        switch status(helper: helper, link: link) {
        case .installed: return
        case .taken(let path): throw InstallError.taken(path)
        case .unavailable: throw InstallError.noHelper
        case .notInstalled: break
        }
        let manager = FileManager.default
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try manager.removeItem(at: link)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    enum InstallError: LocalizedError {
        case noHelper
        case taken(String)

        var errorDescription: String? {
            switch self {
            case .noHelper: "This build of the app has no helper."
            case .taken(let path): "\(Brand.commandLineTool) already exists at \(path). Remove it to install the app's command."
            }
        }
    }

    /// Whether the user's login shell finds the command (its `PATH` includes `~/.local/bin`).
    static func shellFindsIt() async -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(Brand.commandLineTool)"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        let found = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && found.contains(link().path)
    }

    /// The line that puts `~/.local/bin` on a shell's `PATH`.
    static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    /// Installs and says how it went in an alert, with the `PATH` line when the shell needs it.
    @MainActor static func installAndReport() {
        do {
            try install()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Install the Command"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        Task { @MainActor in
            let found = await shellFindsIt()
            let alert = NSAlert()
            alert.messageText = "\(Brand.commandLineTool) Is Installed"
            if found {
                alert.informativeText = "In any terminal, run \(Brand.commandLineTool) pair to pair a phone or iPad, or \(Brand.commandLineTool) devices to rename or remove devices."
                alert.runModal()
            } else {
                alert.informativeText = "It is in ~/.local/bin, which your shell doesn't search yet. Add this line to ~/.zshrc, then open a new terminal:\n\n\(pathLine)"
                alert.addButton(withTitle: "Copy Line")
                alert.addButton(withTitle: "Done")
                if alert.runModal() == .alertFirstButtonReturn { Pasteboard.copy(pathLine) }
            }
        }
    }
}
#endif
