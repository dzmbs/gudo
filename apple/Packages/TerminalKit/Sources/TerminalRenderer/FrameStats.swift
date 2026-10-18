import Synchronization

/// Frame timing and dirty-row counters, collected from the render loop (CPU side) and Metal's
/// completion handlers (GPU side).
public final class FrameStats: Sendable {
    public struct Summary: Sendable, CustomStringConvertible {
        public var frames: Int
        /// RenderState update + row rebuild + instance assembly, per frame (ms).
        public var buildAvg: Double, buildP99: Double, buildMax: Double
        /// Drawable acquisition + encoding + commit, per frame (ms).
        public var encodeAvg: Double, encodeMax: Double
        /// GPU execution time per frame (ms).
        public var gpuAvg: Double, gpuMax: Double
        /// Time between presented frames (ms); idle gaps over 100 ms are excluded.
        public var intervalAvg: Double, intervalMax: Double
        public var rowsRebuilt: Int, rowsReused: Int
        public var instancesMax: Int

        public var description: String {
            func f(_ v: Double) -> String { String(format: "%.2f", v) }
            return "frames=\(frames) build avg/p99/max=\(f(buildAvg))/\(f(buildP99))/\(f(buildMax))ms "
                + "encode avg/max=\(f(encodeAvg))/\(f(encodeMax))ms gpu avg/max=\(f(gpuAvg))/\(f(gpuMax))ms "
                + "interval avg/max=\(f(intervalAvg))/\(f(intervalMax))ms "
                + "rows rebuilt/reused=\(rowsRebuilt)/\(rowsReused) instances<=\(instancesMax)"
        }
    }

    private struct Window {
        var build: [Double] = []
        var encode: [Double] = []
        var gpu: [Double] = []
        var intervals: [Double] = []
        var rowsRebuilt = 0
        var rowsReused = 0
        var instancesMax = 0
        var lastPresent: Double?
    }

    private let window = Mutex(Window())

    public init() {}

    func recordFrame(at time: Double, build: Double, encode: Double, rows: BuildStats, instances: Int) {
        window.withLock { w in
            if let last = w.lastPresent, time - last < 0.1 { w.intervals.append((time - last) * 1000) }
            w.lastPresent = time
            w.build.append(build * 1000)
            w.encode.append(encode * 1000)
            w.rowsRebuilt += rows.rowsRebuilt
            w.rowsReused += rows.rowsReused
            w.instancesMax = max(w.instancesMax, instances)
        }
    }

    func recordGPU(seconds: Double) {
        window.withLock { $0.gpu.append(seconds * 1000) }
    }

    /// Returns the stats since the previous call, or nil if nothing was rendered.
    public func drain() -> Summary? {
        let w = window.withLock { w in
            defer { w = Window(lastPresent: w.lastPresent) }
            return w
        }
        guard !w.build.isEmpty else { return nil }
        func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let sortedBuild = w.build.sorted()
        return Summary(
            frames: w.build.count,
            buildAvg: avg(w.build),
            buildP99: sortedBuild[min(sortedBuild.count - 1, Int(Double(sortedBuild.count) * 0.99))],
            buildMax: sortedBuild.last!,
            encodeAvg: avg(w.encode), encodeMax: w.encode.max()!,
            gpuAvg: avg(w.gpu), gpuMax: w.gpu.max() ?? 0,
            intervalAvg: avg(w.intervals), intervalMax: w.intervals.max() ?? 0,
            rowsRebuilt: w.rowsRebuilt, rowsReused: w.rowsReused,
            instancesMax: w.instancesMax
        )
    }
}
