import Foundation

extension TerminalView {
    static func shellQuoted(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+,:@%".contains($0) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
