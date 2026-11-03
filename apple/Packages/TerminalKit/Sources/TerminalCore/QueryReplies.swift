import Foundation
import GhosttyVt

/// What the terminal tells programs about itself when it answers their queries (panes whose
/// program runs on this device; a host's daemon answers for its own panes the same way):
/// device attributes, XTVERSION, the terminfo name, pixel sizes, the color scheme and whether
/// program status reports are understood, as Ghostty answers them.
extension Terminal {
    /// `TERM` of the programs this terminal runs.
    public static let terminfoName = "xterm-256color"

    /// The XTVERSION reply: Ghostty's, since the terminal is libghostty-vt and programs pick
    /// features by that name, with the app's name after it.
    public static let xtversion: String = {
        let product = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return "ghostty \(ghosttyVersion)" + (product.map { " (\($0))" } ?? "")
    }()

    /// The Ghostty release libghostty-vt is built from ("1.4.0").
    public static let ghosttyVersion: String = {
        var version = GhosttyString(ptr: nil, len: 0)
        guard ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &version) == GHOSTTY_SUCCESS,
              let bytes = version.ptr
        else { return "" }
        let full = String(decoding: UnsafeBufferPointer(start: bytes, count: version.len), as: UTF8.self)
        return String(full.prefix { $0 != "+" && $0 != "-" })
    }()

    /// Written once, then only read: what the XTVERSION callback returns points into it.
    nonisolated(unsafe) private static let xtversionBytes: UnsafeMutableBufferPointer<UInt8> = {
        let bytes = Array(xtversion.utf8)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        _ = buffer.initialize(from: bytes)
        return buffer
    }()

    static func installQueryReplies(_ terminal: GhosttyTerminal) {
        Self.terminfoName.withCString { name in
            var terminfo = GhosttyString(ptr: UnsafeRawPointer(name).assumingMemoryBound(to: UInt8.self), len: Self.terminfoName.utf8.count)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &terminfo)
        }
        let xtversion: GhosttyTerminalXtversionFn = { _, _ in
            GhosttyString(ptr: UnsafePointer(Terminal.xtversionBytes.baseAddress), len: Terminal.xtversionBytes.count)
        }
        let attributes: GhosttyTerminalDeviceAttributesFn = { _, _, out in
            guard let out else { return false }
            var answer = GhosttyDeviceAttributes()
            // A VT220 with color text and clipboard access.
            answer.primary.conformance_level = 62
            withUnsafeMutableBytes(of: &answer.primary.features) { features in
                let codes = features.bindMemory(to: UInt16.self)
                codes[0] = 22
                codes[1] = 52
            }
            answer.primary.num_features = 2
            answer.secondary = GhosttyDeviceAttributesSecondary(device_type: 1, firmware_version: 10, rom_cartridge: 0)
            out.pointee = answer
            return true
        }
        let size: GhosttyTerminalSizeFn = { terminal, _, out in
            guard let terminal, let out else { return false }
            var cols: UInt16 = 0, rows: UInt16 = 0, width: UInt32 = 0, height: UInt32 = 0
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols) == GHOSTTY_SUCCESS,
                  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows) == GHOSTTY_SUCCESS,
                  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_WIDTH_PX, &width) == GHOSTTY_SUCCESS,
                  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_HEIGHT_PX, &height) == GHOSTTY_SUCCESS,
                  cols > 0, rows > 0
            else { return false }
            out.pointee = GhosttySizeReportSize(rows: rows, columns: cols, cell_width: width / UInt32(cols), cell_height: height / UInt32(rows))
            return true
        }
        let scheme: GhosttyTerminalColorSchemeFn = { _, userdata, out in
            guard let out, let effects = Effects.from(userdata) else { return false }
            out.pointee = effects.darkScheme.load(ordering: .relaxed) ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            return true
        }
        // Reports themselves are read from the byte stream by whoever shows them; installing a
        // handler makes `OSC 7501 ; ?` answered, so programs send them.
        let status: GhosttyTerminalProgramStatusFn = { _, _, _ in }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(attributes, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(scheme, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(status, to: UnsafeRawPointer.self))
    }

    /// Whether a theme with this background is dark (`CSI ? 996 n`, mode 2031).
    static func isDark(_ background: RGB) -> Bool {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(background.r) + 0.7152 * linear(background.g) + 0.0722 * linear(background.b) <= 0.5
    }
}
