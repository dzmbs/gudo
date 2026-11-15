import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// The chrome derivation run over every theme Ghostty ships upstream (reference/ghostty's theme
/// package, MIT; read here, never bundled), in the theme's scheme and forced to the other, with and
/// without Increase Contrast: every text-on-surface pairing reads at 4.5:1 and every glyph or
/// control edge at 3:1. Skipped where reference/ is not checked out.
struct ThemeStressTests {
    static let themes = ThemeFiles.load()
    static let schemes: [ColorScheme?] = [nil, .light, .dark]

    @Test(arguments: [false, true])
    func everyPairingReadsOnEveryTheme(increasedContrast: Bool) throws {
        try #require(!Self.themes.isEmpty || ThemeFiles.directory == nil, "theme files found but none parsed")
        guard !Self.themes.isEmpty else { return }
        var worst: [String: (contrast: Double, theme: String)] = [:]
        var failures: [String: [String]] = [:]
        for theme in Self.themes {
            for scheme in Self.schemes {
                let chrome = ChromePalette(theme: theme, scheme: scheme)
                let ink = ChromeInk(chrome: chrome, increasedContrast: increasedContrast)
                for pairing in ChromePairing.all(ink) {
                    let contrast = pairing.foreground.contrast(with: pairing.background)
                    let label = "\(theme.name) (\(scheme.map { "\($0)" } ?? "own"))"
                    if contrast < worst[pairing.name]?.contrast ?? .infinity { worst[pairing.name] = (contrast, label) }
                    if contrast < pairing.minimum - 0.005 {
                        failures[pairing.name, default: []].append("\(label) \(String(format: "%.2f", contrast))")
                    }
                }
            }
        }
        let report = worst.keys.sorted().map { name in
            "\(name),\(String(format: "%.2f", worst[name]?.contrast ?? 0)),\(worst[name]?.theme ?? ""),\(failures[name]?.count ?? 0)"
        }
        ThemeFiles.writeReport(["pairing,worst contrast,worst theme,failing theme-schemes"] + report, increasedContrast: increasedContrast)
        let summary = failures.keys.sorted().map { "\($0): \(failures[$0]?.count ?? 0), e.g. \(failures[$0]?.prefix(3) ?? [])" }
        #expect(failures.isEmpty, "\(summary.joined(separator: "\n"))")
    }
}

extension ThemeStressTests {
    /// Why containers are 12 %: the weakest tint at which a chip stands apart from the surface
    /// under it (1.2:1 on average over every theme). The stronger the tint, the further each
    /// signal must move from the theme's hue to keep 4.5:1 on it; at 12 % that stays under 0.05
    /// of OKLab lightness.
    @Test func containerStrength() throws {
        guard !Self.themes.isEmpty else { return }
        let levels = [0.06, 0.08, 0.10, 0.12, 0.14, 0.16, 0.20]
        var lines = ["level,states moved,share moved,mean lightness shift of moved,mean chip-on-base contrast"]
        var visibilities: [Double] = [], shifts: [Double] = []
        for level in levels {
            var moved = 0, total = 0
            var shift = 0.0, visibility = 0.0
            for theme in Self.themes {
                for scheme in Self.schemes {
                    let chrome = ChromePalette(theme: theme, scheme: scheme)
                    let surfaces = [chrome.base, chrome.sidebar, chrome.raised, chrome.overlay]
                    for signal in ChromePalette.StateSignal.allCases {
                        let plain = ChromePalette.state(signal, of: theme, ink: chrome.foreground, on: surfaces, tint: nil)
                        let held = ChromePalette.state(signal, of: theme, ink: chrome.foreground, on: surfaces, tint: level)
                        total += 1
                        if plain != held {
                            moved += 1
                            shift += abs(held.oklab.l - plain.oklab.l)
                        }
                        visibility += chrome.base.blended(with: held, level).contrast(with: chrome.base)
                    }
                }
            }
            visibilities.append(visibility / Double(total))
            shifts.append(moved == 0 ? 0 : shift / Double(moved))
            lines.append(String(format: "%.2f,%d,%.3f,%.3f,%.3f", level, moved, Double(moved) / Double(total), shifts.last ?? 0, visibilities.last ?? 0))
        }
        ThemeFiles.write(lines, to: "container-strength.csv")
        let chosen = try #require(levels.firstIndex(of: ChromePalette.containerLevel))
        let report = lines.joined(separator: "\n")
        #expect(visibilities[chosen] >= 1.2, "\(report)")
        #expect(chosen == 0 || visibilities[chosen - 1] < 1.2, "\(report)")
        #expect(shifts[chosen] <= 0.05, "\(report)")
    }
}

/// The colours a view draws for each token, composited as it would be, under the contrast mode.
struct ChromeInk {
    let chrome: ChromePalette
    let increasedContrast: Bool

    func layer(_ token: ChromeStyle.Token) -> ChromeLayer {
        chrome.layer(increasedContrast ? token.increasedContrast : token)
    }

    /// `token` drawn over `surface`, itself over `ground` when it is translucent.
    func composite(_ token: ChromeStyle.Token, over surface: ThemeColor) -> ThemeColor {
        layer(token).composited(over: surface)
    }

    func opaque(_ token: ChromeStyle.Token) -> ThemeColor { composite(token, over: chrome.base) }
}

struct ChromePairing {
    let name: String
    let foreground: ThemeColor
    let background: ThemeColor
    let minimum: Double

    static let text = ChromePalette.minimumTextContrast
    static let glyph = ChromePalette.minimumGlyphContrast

    static func all(_ ink: ChromeInk) -> [ChromePairing] {
        let surfaces: [(String, ChromeStyle.Token)] = [
            ("base", .base), ("sidebar", .sidebar), ("raised", .raised), ("overlay", .overlay),
            ("groupedPage", .groupedPage), ("groupedRow", .groupedRow),
        ]
        let fills: [(String, ChromeStyle.Token?)] = [("", nil), (" hovered", .hoverFill), (" selected", .selectedFill), (" pressed", .pressedFill)]
        var pairings: [ChromePairing] = []
        func add(_ name: String, _ foreground: ChromeStyle.Token, on background: ThemeColor, _ minimum: Double) {
            pairings.append(ChromePairing(name: name, foreground: ink.composite(foreground, over: background), background: background, minimum: minimum))
        }
        for (surfaceName, surface) in surfaces {
            let ground = ink.opaque(surface)
            // Menus (overlay) are the system's: no hand-drawn control states on them.
            for (fillName, fill) in fills where surface != .overlay || fill == nil {
                let background = fill.map { ink.composite($0, over: ground) } ?? ground
                add("text on \(surfaceName)\(fillName)", .text, on: background, text)
                add("textSecondary on \(surfaceName)\(fillName)", .textSecondary, on: background, text)
                add("textTertiary on \(surfaceName)\(fillName)", .textTertiary, on: background, glyph)
            }
            for state in [ChromeStyle.Token.done, .error, .attention, .working, .info] {
                add("\(state) on \(surfaceName)", state, on: ground, text)
            }
            add("accent on \(surfaceName)", .accent, on: ground, glyph)
            let selection = ink.composite(.selection, over: ground)
            add("onSelection on selection over \(surfaceName)", .onSelection, on: selection, text)
            for state in [ChromeStyle.Token.done, .error, .attention, .working, .info] {
                let container = ink.composite(.container(state), over: ground)
                add("\(state) on its container over \(surfaceName)", state, on: container, text)
                add("text on \(state) container over \(surfaceName)", .text, on: container, text)
            }
            guard surface != .overlay else { continue }
            let accentDim = ink.composite(.accentDim, over: ground)
            add("accent on accentDim over \(surfaceName)", .accent, on: accentDim, glyph)
            add("text on accentDim over \(surfaceName)", .text, on: accentDim, text)
            add("textSecondary on accentDim over \(surfaceName)", .textSecondary, on: accentDim, text)
            add("scrollbarActive on \(surfaceName)", .scrollbarActive, on: ground, glyph)
        }
        add("onProminent on prominent", .onProminent, on: ink.opaque(.prominent), text)
        add("onAccent on accent", .onAccent, on: ink.opaque(.accent), text)
        for state in [ChromeStyle.Token.done, .error, .attention, .working, .info] {
            add("on \(state) on \(state)", .on(state), on: ink.opaque(state), text)
        }
        return pairings
    }
}

/// Ghostty theme files: `key = value` lines, `palette = N=#rrggbb`.
enum ThemeFiles {
    static let relativeDirectory = "reference/ghostty/zig-pkg/N-V-__8AAI2WBQDrsjfyEiqnmYZ4VfGdJaZhN2mKsaTaIVWq"

    static var directory: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static func load() -> [TerminalTheme] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard let contents = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return parse(contents, name: name)
        }
    }

    static func parse(_ contents: String, name: String) -> TerminalTheme? {
        var values: [String: String] = [:]
        var palette = TerminalTheme.ghosttyDefault.palette
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "palette" {
                let entry = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), palette.indices.contains(index) { palette[index] = hex(entry[1]) }
            } else {
                values[parts[0]] = hex(parts[1])
            }
        }
        guard let background = values["background"], let foreground = values["foreground"] else { return nil }
        return TerminalTheme(
            name: name, bg: background, fg: foreground, cursor: values["cursor-color"], cursorText: values["cursor-text"],
            selBg: values["selection-background"], selFg: values["selection-foreground"], palette: palette)
    }

    private static func hex(_ value: String) -> String { value.hasPrefix("#") ? value.lowercased() : "#" + value.lowercased() }

    /// The worst pairings as CSV, beside the gallery when `GUDO_DESIGN_GALLERY_DIR` is set.
    static func writeReport(_ lines: [String], increasedContrast: Bool) {
        write(lines, to: increasedContrast ? "contrast-increased.csv" : "contrast-standard.csv")
    }

    static func write(_ lines: [String], to name: String) {
        guard let path = ProcessInfo.processInfo.environment["GUDO_DESIGN_GALLERY_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
