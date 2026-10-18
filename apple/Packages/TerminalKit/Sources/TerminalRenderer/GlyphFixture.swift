/// A test screen for the glyph pipeline: box drawing (joins, rounded corners, heavy and double
/// lines, dashes, diagonals), block elements and shades, Powerline segments, a braille graph,
/// legacy computing symbols, git branch drawing, Nerd Font icons, emoji and CJK. VT-ready
/// (CRLF line endings, SGR colours) and sized for an 80×24 grid.
public enum GlyphFixture {
    public static let text: String = {
        let esc = "\u{1b}["
        func sgr(_ codes: String) -> String { esc + codes + "m" }
        let reset = sgr("0")
        func fg(_ n: Int) -> String { sgr("38;5;\(n)") }
        func bg(_ n: Int) -> String { sgr("48;5;\(n)") }

        var lines: [String] = []
        lines.append(sgr("1") + "Glyph fixture" + reset + sgr("2") + "  box · blocks · powerline · braille · legacy · icons · emoji · CJK" + reset)
        lines.append("")

        // Four boxes, 17 columns each: light, rounded, double, heavy.
        let boxes = [
            ["┌───────┬───────┐", "│ light │ ├─┼─┤ │", "├───────┼───────┤", "│ ┄┄┄┄┄ │ ╌╌╌╌╌ │", "└───────┴───────┘"],
            ["╭───────────────╮", "│    rounded    │", "│ ╭─╮ ╭┬╮ ╱╲ ╳  │", "│ ╰─╯ ╰┴╯ ╲╱ ┆┇ │", "╰───────────────╯"],
            ["╔═══════╦═══════╗", "║ dbl   ║ ╠═╬═╣ ║", "╠═══════╬═══════╣", "║ ╒═╕   ║ ╓─╖   ║", "╚═══════╩═══════╝"],
            ["┏━━━━━━━┳━━━━━━━┓", "┃ heavy ┃ ┣━╋━┫ ┃", "┣━━━━━━━╋━━━━━━━┫", "┃ ┍━┑   ┃ ┎─┒ ┉ ┃", "┗━━━━━━━┻━━━━━━━┛"],
        ]
        let colors = [75, 114, 179, 204]
        for row in 0..<5 {
            lines.append(boxes.indices.map { fg(colors[$0]) + boxes[$0][row] }.joined(separator: " ") + reset)
        }
        lines.append("")

        // Blocks: eighths, shades, quadrants, and a 256-colour ramp of full blocks.
        lines.append("▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉█ ░▒▓█ ▖▗▘▙▚▛▜▝▞▟ ▀▄▐▌▔▕ " + fg(208) + "▓▓▒▒░░" + reset)
        lines.append((0..<36).map { fg(16 + $0 * 6 + 5) + "██" }.joined() + reset)
        lines.append("")

        // Powerline: a prompt with arrows, rounded caps, slants and thin separators.
        let pl = bg(31) + fg(231) + "  ~/src " + fg(31) + bg(71) + "\u{E0B0}" + fg(231) + " \u{E0A0} main " + fg(71) + bg(236)
            + "\u{E0B0}" + fg(250) + " \u{E0B1} 3 \u{E0B1} 2 " + reset + fg(236) + "\u{E0B0}" + reset
            + "  " + fg(97) + "\u{E0B6}" + bg(97) + fg(231) + " rounded " + reset + fg(97) + "\u{E0B4}" + reset
            + " " + fg(166) + "\u{E0BA}" + bg(166) + fg(231) + " slant " + reset + fg(166) + "\u{E0BC}" + reset
            + " \u{E0B2}\u{E0B3}\u{E0B5}\u{E0B7}\u{E0B8}\u{E0B9}\u{E0BB}\u{E0BE}\u{E0BF}\u{E0D2}\u{E0D4}"
        lines.append(pl)
        lines.append("")

        // Braille: two rows of a sine wave, then the dot patterns' corners.
        lines.append(fg(114) + brailleWave(columns: 60, phase: 0) + reset + " ⠁⠂⠄⡀⠈⠐⠠⢀")
        lines.append(fg(75) + brailleWave(columns: 60, phase: 1.5) + reset + " ⣿⣶⣤⣀⡇⢸⠿⠛")
        lines.append("")

        // Legacy computing: sextants, smooth mosaics, wedges, eighths, checkers, octants, circles.
        lines.append("🬀🬁🬂🬃🬄🬅🬆🬇🬈🬉🬊🬋🬌🬍🬎🬏 🬼🬽🬾🬿🭀🭁🭂🭃🭄🭅🭆🭇🭈🭉🭊🭋 🭨🭩🭪🭫🭬🭭🭮🭯 🭰🭱🭲🭳🭴🭵 🭶🭷🭸🭹🭺🭻 🮕🮖🮘🮙")
        lines.append("𜴀𜴁𜴂𜴃𜴄𜴅𜴆𜴇𜴈𜴉 🯠🯡🯢🯣🯨🯩🯪🯫 🮠🮡🮢🮣🮮 🯐🯑🯒🯓🯘🯙🯚🯛 𜺐𜺓𜺜𜺟 𜰰𜰱𜰲𜰳 ◢◣◤◥ ◸◹◺◿")
        lines.append("")

        // Git branch drawing (kitty's branch characters).
        lines.append(fg(179) + "\u{F5EE}\u{F5D0}\u{F5D0}\u{F5F2}" + reset + " merge   " + fg(179) + "\u{F5FA}\u{F5D0}\u{F5D7}" + reset + " "
            + fg(204) + "\u{F5EF}\u{F5D2}\u{F5D3}\u{F5D4}\u{F5D5}\u{F5DA}\u{F5DB}\u{F5E6}\u{F5E7}\u{F60C}\u{F60D}" + reset)
        lines.append("")

        // Nerd Font icons (each followed by a space, so it may grow into two cells), then emoji
        // and CJK (wide).
        let icons = ["\u{F121}", "\u{E0A0}", "\u{F07B}", "\u{F17C}", "\u{F179}", "\u{F0E7}", "\u{EA61}", "\u{F1D3}", "\u{F013}", "\u{F0F3}"]
        lines.append(fg(75) + icons.joined(separator: " ") + reset + "  " + fg(204) + icons.joined() + reset)
        lines.append("😀 👍🏽 🇯🇵 👨‍👩‍👧 ✅ 🚀  日本語のテキスト 中文字体 한국어")
        return lines.joined(separator: "\r\n")
    }()

    /// A sine wave drawn with braille dots, two dots per column horizontally and four rows.
    private static func brailleWave(columns: Int, phase: Double) -> String {
        // Dot bits by (column 0/1, row 0...3).
        let bits: [[UInt32]] = [[0x01, 0x02, 0x04, 0x40], [0x08, 0x10, 0x20, 0x80]]
        var out = ""
        for column in 0..<columns {
            var pattern: UInt32 = 0
            for sub in 0..<2 {
                let x = Double(column * 2 + sub)
                let y = Int(((sin(x / 6 + phase) + 1) / 2 * 3.99).rounded(.down))
                pattern |= bits[sub][3 - y]
            }
            out.unicodeScalars.append(Unicode.Scalar(0x2800 + pattern)!)
        }
        return out
    }
}

import Foundation
