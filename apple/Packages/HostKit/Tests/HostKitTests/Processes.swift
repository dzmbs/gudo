import Foundation

/// Whether a process whose whole command line is `pattern` runs on this Mac.
nonisolated func pgrep(_ pattern: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "^\(pattern)$"]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}
