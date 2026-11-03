import Foundation
import GhosttyVt

/// What a remote pane needs from the client VT beyond raw bytes (docs/DAEMON.md "Output" and
/// "Scrollback history paging"): replace the terminal with a daemon snapshot's READY section,
/// prepend history records as they arrive, and read text and scroll position.
///
/// This is the Swift twin of `ghostty_vt::StreamingRestore` (crates/ghostty-vt/src/history.rs).
extension Terminal {
    public enum SnapshotError: Error, Equatable {
        /// libghostty-vt rejected the bytes (`GhosttyResult` code).
        case invalid(Int32)
    }

    /// Replaces the whole terminal state (screens, modes, cursor, unfinished parser input) with
    /// a Ghostty snapshot's READY section, and the pixels of the images in view that the daemon
    /// sends after it. Scrollback older than READY (and other images' pixels) can then be added
    /// with `appendHistory(_:)`. Callbacks and colors of this `Terminal` carry over; the size is the
    /// snapshot's (the remote PTY's).
    public func restore(snapshot ready: UnsafeRawBufferPointer) throws(SnapshotError) {
        let restore = SnapshotRestore(ready: ready, imageStorageLimit: kittyImageStorageLimit)
        let result = restore.ready()
        guard result.code == GHOSTTY_SUCCESS, let handle = result.terminal else {
            restore.free()
            throw .invalid(Int32(result.code.rawValue))
        }
        Self.configure(handle, effects: effects, configuration: lock.withLock { _ in configuration })
        lock.withLock { _ in
            restoreState?.free()
            let old = terminal
            terminal = handle
            restoreState = restore
            ghostty_terminal_free(old)
            synchronizedOutput.restart(inUpdate: Self.mode(handle, 2026), now: .now)
            // Image pixels that came with the screen; a bad record ends the restore, not the screen.
            if restore.push(Data()).code != GHOSTTY_SUCCESS {
                restore.free()
                restoreState = nil
            }
        }
    }

    public func restore(snapshot ready: Data) throws(SnapshotError) {
        var failure: SnapshotError?
        ready.withUnsafeBytes { bytes in
            do throws(SnapshotError) { try restore(snapshot: bytes) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Prepends scrollback from history records of the last restored snapshot, cut anywhere (a
    /// partial record waits for the rest). Returns the number of pages applied; 0 if nothing is
    /// being restored.
    @discardableResult
    public func appendHistory(_ records: Data) throws(SnapshotError) -> Int {
        let (code, pages): (GhosttyResult, Int) = lock.withLock { _ in
            guard let restoreState else { return (GHOSTTY_SUCCESS, 0) }
            let result = restoreState.push(records)
            if result.code != GHOSTTY_SUCCESS || restoreState.finished {
                restoreState.free()
                self.restoreState = nil
            }
            return result
        }
        guard code == GHOSTTY_SUCCESS else { throw .invalid(Int32(code.rawValue)) }
        return pages
    }

    /// Plain text of the whole screen, scrollback included, soft wraps joined and trailing
    /// blanks trimmed (diagnostics, accessibility, tests).
    public func plainText() -> String {
        withHandle { handle in
            var options = GhosttyFormatterTerminalOptions()
            options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = true
            options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
            options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
            var formatter: GhosttyFormatter?
            guard ghostty_formatter_terminal_new(nil, &formatter, handle, options) == GHOSTTY_SUCCESS,
                  let formatter
            else { return "" }
            defer { ghostty_formatter_free(formatter) }
            var pointer: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard ghostty_formatter_format_alloc(formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS,
                  let pointer
            else { return "" }
            defer { ghostty_free(nil, pointer, length) }
            return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
        }
    }

    /// A complete snapshot of this terminal, a held synchronized update included (another
    /// window's copy of a pane starts from it; tests and diagnostics).
    public func encodeSnapshot() -> Data? {
        withHandle { handle in
            if synchronizedOutput.isHolding { synchronizedOutput.release(parseLocked) }
            var pointer: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard ghostty_snapshot_encode_alloc(handle, nil, &pointer, &length) == GHOSTTY_SUCCESS,
                  let pointer
            else { return nil }
            defer { ghostty_free(nil, pointer, length) }
            return Data(bytes: pointer, count: length)
        }
    }
}

/// A snapshot decoder kept after READY so history pages can be prepended later. Owned by its
/// `Terminal` and only used under the terminal's lock.
final class SnapshotRestore {
    private static let headerLength = 10
    private static let tagReady: UInt16 = 5
    private static let tagPage: UInt16 = 3
    private static let tagFinish: UInt16 = 6
    private static let tagImagePayload: UInt16 = 9
    private static let tagPagePlacements: UInt16 = 10

    /// Bytes the decoder reads, with its read cursor; the reader callback's userdata.
    final class Source {
        var data: [UInt8]
        var position = 0

        init(_ data: [UInt8]) {
            self.data = data
        }
    }

    private var decoder: GhosttySnapshotDecoder?
    private let source: Source
    private var scanned = 0
    /// Tags of the scanned records not yet decoded, oldest first.
    private var pending: [UInt16] = []
    private(set) var finished = false

    init(ready: UnsafeRawBufferPointer, imageStorageLimit: UInt64) {
        source = Source(Array(ready))
        let reader = GhosttyReader(
            read: { userdata, buffer, capacity, read in
                guard let userdata, let buffer, let read else { return false }
                let source = Unmanaged<Source>.fromOpaque(userdata).takeUnretainedValue()
                let count = min(capacity, source.data.count - source.position)
                source.data.withUnsafeBufferPointer {
                    buffer.update(from: $0.baseAddress! + source.position, count: count)
                }
                source.position += count
                read.pointee = count
                return true
            },
            userdata: Unmanaged.passUnretained(source).toOpaque())
        var decoder: GhosttySnapshotDecoder?
        guard ghostty_snapshot_decoder_new(nil, &decoder, reader) == GHOSTTY_SUCCESS else { return }
        var yes = true
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &yes)
        _ = KittyGraphics.installPNGDecoder
        var images = imageStorageLimit
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT, &images)
        self.decoder = decoder
    }

    /// Decodes READY into a new terminal handle, owned by the caller.
    func ready() -> (code: GhosttyResult, terminal: GhosttyTerminal?) {
        guard let decoder else { return (GHOSTTY_OUT_OF_MEMORY, nil) }
        var terminal: GhosttyTerminal?
        let code = ghostty_snapshot_decoder_ready(decoder, &terminal)
        scanned = source.position
        return (code, terminal)
    }

    /// Adds records and decodes every page they complete (see `StreamingRestore::push`). A page
    /// is decoded once the record after it is here: the decoder reads on to see whether
    /// placements follow, and running out of bytes there ends the snapshot. Image pixels are
    /// attached as soon as their record is complete.
    func push(_ records: Data) -> (code: GhosttyResult, pages: Int) {
        guard let decoder, !finished else { return (GHOSTTY_SUCCESS, 0) }
        let consumed = source.position
        source.data.removeFirst(consumed)
        source.position = 0
        scanned -= consumed
        source.data.append(contentsOf: records)

        let data = source.data
        while scanned + Self.headerLength <= data.count {
            let tag = UInt16(data[scanned]) | UInt16(data[scanned + 1]) << 8
            let length = (0..<4).reduce(0) { $0 | Int(data[scanned + 2 + $1]) << (8 * $1) }
            let end = scanned + Self.headerLength + length
            guard end <= data.count else { break }
            scanned = end
            pending.append(tag)
        }
        var pages = 0
        while let tag = pending.first {
            switch tag {
            case Self.tagFinish:
                let code = ghostty_snapshot_decoder_next(decoder)
                guard code == GHOSTTY_NO_VALUE else { return (code == GHOSTTY_SUCCESS ? GHOSTTY_INVALID_VALUE : code, pages) }
                pending.removeAll()
                finished = true
                return (GHOSTTY_SUCCESS, pages)
            case Self.tagPage, Self.tagImagePayload:
                let records = tag == Self.tagPage && pending.dropFirst().first == Self.tagPagePlacements ? 2 : 1
                guard tag == Self.tagImagePayload || pending.count > records else { return (GHOSTTY_SUCCESS, pages) }
                let code = ghostty_snapshot_decoder_next(decoder)
                guard code == GHOSTTY_SUCCESS else { return (code == GHOSTTY_NO_VALUE ? GHOSTTY_INVALID_VALUE : code, pages) }
                if tag == Self.tagPage { pages += 1 }
                pending.removeFirst(records)
            default:
                // Skipped by the decoder, or read along with the next step.
                pending.removeFirst()
            }
        }
        return (GHOSTTY_SUCCESS, pages)
    }

    /// Frees the decoder (before the terminal it refers to).
    func free() {
        if let decoder { ghostty_snapshot_decoder_free(decoder) }
        decoder = nil
    }

    /// Length of the prefix the daemon sends to show the screen: through the READY record, plus
    /// the image pixel records right after it unless `withImages` is false (tests).
    static func readyLength(of snapshot: Data, withImages: Bool = true) -> Int? {
        let bytes = [UInt8](snapshot)
        // "GHOSTSNP", format version u16, then records.
        guard bytes.starts(with: Array("GHOSTSNP".utf8)) else { return nil }
        var offset = 10
        while offset + headerLength <= bytes.count {
            let tag = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            let length = (0..<4).reduce(0) { $0 | Int(bytes[offset + 2 + $1]) << (8 * $1) }
            offset += headerLength + length
            guard tag == tagReady else { continue }
            while withImages, offset + headerLength <= bytes.count {
                let tag = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let length = (0..<4).reduce(0) { $0 | Int(bytes[offset + 2 + $1]) << (8 * $1) }
                guard tag == tagImagePayload, offset + headerLength + length <= bytes.count else { break }
                offset += headerLength + length
            }
            return offset
        }
        return nil
    }
}

extension Terminal {
    /// Splits a complete snapshot into the prefix that shows the screen and the records after
    /// it, the way the daemon sends them; without `images`, the pixels of the images in view
    /// stay with the history (tests and diagnostics).
    public static func splitSnapshot(_ snapshot: Data, images: Bool = true) -> (ready: Data, history: Data)? {
        guard let length = SnapshotRestore.readyLength(of: snapshot, withImages: images) else { return nil }
        return (snapshot.prefix(length), snapshot.dropFirst(length))
    }
}
