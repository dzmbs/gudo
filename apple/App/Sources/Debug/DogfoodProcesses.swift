#if DEBUG && os(macOS)
import Darwin
import Foundation

/// The process table through `sysctl(KERN_PROC_ALL)`: no entitlement or permission needed to see
/// our own children.
nonisolated enum DogfoodProcesses {
    struct Process: Sendable, Codable {
        var pid: Int32
        var ppid: Int32
        var name: String
        /// SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5.
        var stat: Int8

        var isStopped: Bool { stat == 4 }
        var isZombie: Bool { stat == 5 }
        var state: String {
            switch stat {
            case 4: "stopped"
            case 5: "zombie"
            default: "running"
            }
        }
    }

    static func all() -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.prefix(size / stride).map { info in
            var comm = info.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return Process(pid: info.kp_proc.p_pid, ppid: info.kp_eproc.e_ppid, name: name, stat: Int8(info.kp_proc.p_stat))
        }
    }

    /// `root` (if alive) and all its descendants, zombies excluded.
    static func tree(of root: Int32) -> [Process] {
        let table = all()
        var result = table.filter { $0.pid == root && !$0.isZombie }
        var frontier: Set<Int32> = [root]
        while !frontier.isEmpty {
            let children = table.filter { frontier.contains($0.ppid) && !$0.isZombie }
            result += children
            frontier = Set(children.map(\.pid))
        }
        return result
    }

    static func alive(_ pids: [Int32]) -> [Process] {
        let wanted = Set(pids)
        return all().filter { wanted.contains($0.pid) && !$0.isZombie }
    }
}
#endif
