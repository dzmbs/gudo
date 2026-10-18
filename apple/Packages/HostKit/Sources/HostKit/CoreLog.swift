import os
import UnnamedCore

/// Routes the Rust core's `tracing` output to os_log (category `core`), so connection and SSH
/// diagnostics show up in Console.app and `log stream --predicate 'subsystem == "<bundle id>"'`.
nonisolated public enum CoreLog {
    /// Installs the bridge once. `filter` is an `EnvFilter` directive (`info`,
    /// `client_core=debug,iroh=warn`).
    @discardableResult
    public static func install(filter: String = "info,iroh=warn,iroh_quinn=warn,noq=warn") -> Bool {
        installLogSink(sink: Sink(), filter: filter)
    }

    private final class Sink: LogSink {
        private let logger = Logger(subsystem: Log.subsystem, category: "core")

        func log(level: LogLevel, target: String, message: String) {
            switch level {
            case .error: logger.error("\(target, privacy: .public): \(message, privacy: .public)")
            case .warn: logger.warning("\(target, privacy: .public): \(message, privacy: .public)")
            case .info: logger.info("\(target, privacy: .public): \(message, privacy: .public)")
            case .debug, .trace: logger.debug("\(target, privacy: .public): \(message, privacy: .public)")
            }
        }
    }
}
