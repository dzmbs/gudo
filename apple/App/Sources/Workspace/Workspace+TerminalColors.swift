import GudoCore
import HostKit
import TerminalCore
import TerminalRenderer

extension TerminalAppearance {
    /// The theme's colors as a host's panes answer programs that ask for them (OSC 4, 10, 11,
    /// 12): each `0xRRGGBB`, the palette all 256 colors or none for the default one.
    var daemonColors: TerminalColors {
        let hex = { (color: RGB) in UInt32(color.r) << 16 | UInt32(color.g) << 8 | UInt32(color.b) }
        return TerminalColors(
            foreground: hex(foreground), background: hex(background), cursor: cursorColor.map(hex),
            palette: (palette ?? []).map(hex))
    }
}

extension Workspace {
    /// Tells the host this device's theme, so the programs in panes used here draw for it.
    func announceTerminalColors() {
        (host as? DaemonConnection)?.terminalColors = appearance.daemonColors
    }
}
