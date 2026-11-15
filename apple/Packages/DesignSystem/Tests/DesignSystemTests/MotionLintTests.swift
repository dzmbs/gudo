import Foundation
import Testing

/// Every animation in the apps comes from `DS.Motion`: no literal curve, spring, duration or
/// delay anywhere else, and transitions only through `motionTransition`. A line may opt out with
/// `motion-lint-allow:` and a reason, on it or on the line above.
enum MotionLint {
    struct Rule {
        let name: String
        let pattern: NSRegularExpression
        /// A line holding this is the vocabulary itself, not a literal.
        let exempt: String?

        init(_ name: String, _ pattern: String, exempt: String? = nil) {
            self.name = name
            self.pattern = try! NSRegularExpression(pattern: pattern)
            self.exempt = exempt
        }

        func matches(_ line: String) -> Bool {
            if let exempt, line.contains(exempt) { return false }
            return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    static let curves = "easeIn|easeOut|easeInOut|linear|spring|interpolatingSpring|interactiveSpring|smooth|snappy|bouncy|timingCurve"

    static let rules = [
        Rule("literal animation", #"(withAnimation|\.animation)\(\s*\."#),
        Rule("default animation", #"withAnimation\s*(\{|\(\s*\))"#),
        Rule("literal curve", #"[?:(,=]\s*\.("# + curves + #")\s*\("#),
        Rule("literal curve", #"Animation\.("# + curves + #"|default)\b"#),
        Rule("literal spring", #"\b(Spring|UISpringTimingParameters|CASpringAnimation)\("#),
        Rule("literal spring", #"springDuration:\s*[0-9]"#),
        Rule("literal duration", #"withDuration:\s*[0-9]"#),
        Rule("literal duration", #"\.duration\s*=\s*[0-9]"#),
        Rule("literal duration", #"Keyframe\([^)]*duration:\s*[0-9]"#),
        Rule("literal duration", #"(UIView\.transition|UIViewPropertyAnimator)\([^)]*duration:\s*[0-9]*\.?[0-9]*[1-9]"#),
        Rule("literal delay", #"\.delay\(\s*[0-9]"#),
        Rule("loop", #"\.repeatForever\("#, exempt: "DS.Motion.Loop."),
        Rule("raw transition", #"(?<!UIView)\.transition\((?!\.identity\))"#),
    ]

    /// The vocabulary: the only files that may spell out curves.
    static let vocabulary: Set<String> = ["Tokens.swift", "Motion.swift"]

    static func violations(in source: String, file: String) -> [String] {
        var found: [String] = []
        var previous = ""
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            defer { previous = line }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if allows(line) || allows(previous) { continue }
            for rule in rules where rule.matches(line) {
                found.append("\(file):\(index + 1): \(rule.name): \(trimmed)")
            }
        }
        return found
    }

    private static func allows(_ line: String) -> Bool {
        guard let range = line.range(of: "motion-lint-allow:") else { return false }
        return !line[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `apple/`, from this file's place in the tree.
    static var appleRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func sourceFiles() -> [URL] {
        let root = appleRoot
        let packages = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Packages").path)) ?? []
        let directories = [root.appendingPathComponent("App/Sources")]
            + packages.sorted().map { root.appendingPathComponent("Packages/\($0)/Sources") }
        return directories.flatMap { directory -> [URL] in
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
            return walker.compactMap { $0 as? URL }.filter { url in
                url.pathExtension == "swift" && !url.path.contains("/.build/")
                    && !(url.path.contains("/DesignSystem/Tokens/") && vocabulary.contains(url.lastPathComponent))
            }
        }
    }
}

@Test func motionLintFindsNoLiteralAnimations() throws {
    let files = MotionLint.sourceFiles()
    #expect(files.count > 100, "the lint must see the app's sources")
    let root = MotionLint.appleRoot.path + "/"
    var violations: [String] = []
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        violations += MotionLint.violations(in: source, file: file.path.replacingOccurrences(of: root, with: ""))
    }
    #expect(violations.isEmpty, "\(violations.count) animation(s) outside DS.Motion:\n\(violations.joined(separator: "\n"))")
}

@Test func motionLintCatchesEachKindOfLiteral() {
    let literals = [
        "withAnimation(.easeOut(duration: 0.2)) { shown = true }",
        "withAnimation { shown = true }",
        ".animation(.spring(response: 0.3, dampingFraction: 0.8), value: shown)",
        ".animation(shown ? .easeIn(duration: 0.1) : nil, value: shown)",
        "let curve = Animation.snappy",
        "let spring = Spring(duration: 0.3, bounce: 0)",
        "UIView.animate(withDuration: 0.2) { view.alpha = 1 }",
        "UIView.animate(springDuration: 0.2, bounce: 0) { view.alpha = 1 }",
        "fade.duration = 0.25",
        "SpringKeyframe(1, duration: 0.36, spring: .smooth)",
        "UIView.transition(with: strip, duration: 0.18, options: .transitionCrossDissolve) {}",
        "UIViewPropertyAnimator(duration: 0.7, dampingRatio: 1)",
        ".animation(DS.Motion.micro.delay(0.2), value: shown)",
        "withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {}",
        ".transition(.opacity)",
        ".transition(.move(edge: .bottom))",
    ]
    for literal in literals {
        #expect(!MotionLint.violations(in: literal, file: "Sample.swift").isEmpty, "\(literal)")
    }
    let vocabulary = [
        "withAnimation(DS.Motion.standard) { shown = true }",
        ".animation(DS.Motion.micro, value: shown)",
        ".animation(reduceMotion ? nil : DS.Motion.micro, value: shown)",
        ".animation(DS.Motion.micro.delay(DS.Motion.arrivalDelay), value: shown)",
        ".motionTransition(.toast(from: .bottom))",
        ".transition(.identity)",
        "withAnimation(DS.Motion.Loop.secureInput.repeatForever(autoreverses: false)) {}",
        "UIView.transition(with: strip, duration: reduce ? 0 : DS.Motion.Role.micro.budget, options: []) {}",
        "UIViewPropertyAnimator(duration: 0, timingParameters: DS.Motion.Role.structural.timingParameters)",
        ".progressViewStyle(.linear)",
        "// withAnimation(.easeOut(duration: 1)) in a comment",
        "withAnimation(.easeOut(duration: 1)) {}  // motion-lint-allow: follows the keyboard",
    ]
    for line in vocabulary {
        #expect(MotionLint.violations(in: line, file: "Sample.swift").isEmpty, "\(line)")
    }
    #expect(!MotionLint.violations(in: ".transition(.opacity)  // motion-lint-allow:", file: "Sample.swift").isEmpty,
            "an allowance needs a reason")
}
