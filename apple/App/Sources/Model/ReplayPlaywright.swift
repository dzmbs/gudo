import Foundation

/// A recorded session as a Playwright test (TypeScript): `page.goto` for navigations and a
/// locator action for each step, in order. The same session always gives the same text.
/// Steps recorded without a locator fall back to the element's role and name, then to
/// coordinates, and say so; steps with neither are left as comments.
nonisolated enum ReplayPlaywright {
    static func test(for session: ReplaySession) -> String {
        var lines = [
            "import { test, expect } from '@playwright/test';",
            "",
            "// Recorded \(stamp(session.started)) by Session Replay.",
            "test(\(quote(session.displayTitle)), async ({ page }) => {",
        ]
        var visited = false
        for action in session.actions {
            let steps = statements(for: action)
            if action.kind == "navigate" { visited = true }
            if !visited, action.kind != "navigate", let start = action.urlBefore, start.hasPrefix("http") {
                lines.append("  await page.goto(\(quote(start)));")
                visited = true
            }
            if !action.succeeded { lines.append("  // The agent saw: \(oneLine(action.verdict))") }
            lines += steps.map { "  " + $0 }
        }
        lines += ["});", ""]
        return lines.joined(separator: "\n")
    }

    /// A file name for the test (`checkout-flow.spec.ts`).
    static func fileName(for session: ReplaySession) -> String {
        let words = String(session.displayTitle.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        let slug = words.split(separator: " ").prefix(6).joined(separator: "-")
        return (slug.isEmpty ? "session" : slug) + ".spec.ts"
    }

    static func statements(for action: ReplayAction) -> [String] {
        let input = action.arguments
        switch action.kind {
        case "navigate":
            switch (input["url"] as? String ?? "").lowercased() {
            case "back": return ["await page.goBack();"]
            case "forward": return ["await page.goForward();"]
            case "reload": return ["await page.reload();"]
            default:
                guard let url = action.urlAfter ?? (input["url"] as? String) else { return [] }
                return ["await page.goto(\(quote(url)));"]
            }
        case "press":
            let keys = (input["keys"] as? String ?? "").split(separator: " ").map { key(String($0)) }
            let times = max(1, (input["repeat"] as? NSNumber)?.intValue ?? 1)
            return Array(repeating: keys.map { "await page.keyboard.press(\(quote($0)));" }, count: times).flatMap { $0 }
        case "scroll":
            let amount = 100 * max(1, (input["amount"] as? NSNumber)?.intValue ?? 3)
            let (dx, dy) = switch input["direction"] as? String {
            case "up": (0, -amount)
            case "left": (-amount, 0)
            case "right": (amount, 0)
            default: (0, amount)
            }
            var out: [String] = []
            if input["target"] != nil, let target = target(action) { out += pointAt(target) }
            return out + ["await page.mouse.wheel(\(dx), \(dy));"]
        case "type":
            let text = input["text"] as? String ?? ""
            let submit = input["submit"] as? Bool ?? false
            var out: [String]
            if input["target"] != nil, let target = target(action) {
                out = switch target {
                case .locator(let locator, let note): ["await \(locator).pressSequentially(\(quote(text)));" + note]
                case .point(let x, let y, let note): ["await page.mouse.click(\(x), \(y));" + note, "await page.keyboard.type(\(quote(text)));"]
                case .missing(let note): [note, "await page.keyboard.type(\(quote(text)));"]
                }
            } else {
                out = ["await page.keyboard.type(\(quote(text)));"]
            }
            if submit { out.append("await page.keyboard.press('Enter');") }
            return out
        case "drag":
            guard let from = target(action) else { return ["// browser_drag: nothing to act on was recorded."] }
            var out = pointAt(from)
            if let to = input["to"] as? [String: Any], to["type"] as? String == "coordinate" {
                let x = (to["x"] as? NSNumber)?.intValue ?? 0, y = (to["y"] as? NSNumber)?.intValue ?? 0
                out += ["await page.mouse.down();", "await page.mouse.move(\(x), \(y), { steps: 8 }); // the agent's screenshot coordinates", "await page.mouse.up();"]
            } else {
                out += ["await page.mouse.down();", "// browser_drag to \((input["to"] as? [String: Any])?["ref"] as? String ?? "?"): no locator was recorded for the drop target.", "await page.mouse.up();"]
            }
            return out
        default:
            guard let target = target(action) else { return ["// \(action.tool): nothing to act on was recorded."] }
            switch target {
            case .missing(let note):
                return [note]
            case .point(let x, let y, let note):
                return switch action.kind {
                case "double_click": ["await page.mouse.dblclick(\(x), \(y));" + note]
                case "hover", "scroll_to": ["await page.mouse.move(\(x), \(y));" + note]
                default: ["await page.mouse.click(\(x), \(y));" + note]
                }
            case .locator(let locator, let note):
                switch action.kind {
                case "double_click": return ["await \(locator).dblclick();" + note]
                case "hover": return ["await \(locator).hover();" + note]
                case "scroll_to": return ["await \(locator).scrollIntoViewIfNeeded();" + note]
                case "fill":
                    let value = input["value"]
                    if let flag = value as? Bool, CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID() {
                        return ["await \(locator).\(flag ? "check" : "uncheck")();" + note]
                    }
                    let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
                    if ["combobox", "listbox"].contains(action.role ?? "") {
                        return ["await \(locator).selectOption(\(quote(text)));" + note]
                    }
                    return ["await \(locator).fill(\(quote(text)));" + note]
                default:
                    let modifiers = (input["modifiers"] as? String).map { $0.split(separator: "+").map { key(String($0)) } } ?? []
                    let options = modifiers.isEmpty ? "" : "{ modifiers: [\(modifiers.map(quote).joined(separator: ", "))] }"
                    return ["await \(locator).click(\(options));" + note]
                }
            }
        }
    }

    private enum Target {
        case locator(String, note: String)
        case point(Int, Int, note: String)
        case missing(String)
    }

    /// The element: its recorded locator, else its role and name, else the point, else the ref.
    private static func target(_ action: ReplayAction) -> Target? {
        if let locator = action.locator, !locator.isEmpty {
            return .locator("page." + locator, note: "")
        }
        if let role = action.role {
            var locator = "page.getByRole(\(quote(role))" + (action.name.map { ", { name: \(quote($0)), exact: true }" } ?? "") + ")"
            if let nth = action.nth, nth > 0 { locator += ".nth(\(nth))" }
            return .locator(locator, note: " // from the element's role and name (no locator was recorded)")
        }
        if let point = action.arguments["target"] as? [String: Any], point["type"] as? String == "coordinate" {
            let x = (point["x"] as? NSNumber)?.intValue ?? 0, y = (point["y"] as? NSNumber)?.intValue ?? 0
            return .point(x, y, note: " // the agent's screenshot coordinates (no element was recorded)")
        }
        if let ref = action.ref {
            return .missing("// \(action.tool) on \(ref): no locator was recorded for this element.")
        }
        return nil
    }

    private static func pointAt(_ target: Target) -> [String] {
        switch target {
        case .locator(let locator, let note): ["await \(locator).hover();" + note]
        case .point(let x, let y, let note): ["await page.mouse.move(\(x), \(y));" + note]
        case .missing(let note): [note]
        }
    }

    /// The agent's key names (`cmd+a`, `enter`) as Playwright's (`Meta+a`, `Enter`).
    static func key(_ chord: String) -> String {
        let names = [
            "cmd": "Meta", "command": "Meta", "meta": "Meta", "ctrl": "Control", "control": "Control",
            "alt": "Alt", "option": "Alt", "opt": "Alt", "shift": "Shift", "enter": "Enter", "return": "Enter",
            "esc": "Escape", "escape": "Escape", "tab": "Tab", "backspace": "Backspace", "delete": "Delete",
            "space": "Space", "up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft", "right": "ArrowRight",
            "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown",
        ]
        return chord.split(separator: "+").map { part in
            let word = String(part)
            return names[word.lowercased()] ?? word
        }.joined(separator: "+")
    }

    static func quote(_ text: String) -> String {
        var out = "'"
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "'"
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
