import Foundation
import UniformTypeIdentifiers

/// What a link from terminal output may do. Any program, file or remote host can print one, so
/// only a web page whose address the user could see opens straight away (GHSA-cw69-wm67-5pv8).
public enum LinkSafety {
    public enum Action: Equatable, Sendable {
        case open
        /// Ask first, showing the real address.
        case confirm
        case refuse
    }

    /// Schemes that run code or smuggle content rather than name a place.
    private static let refused: Set<String> = ["javascript", "vbscript", "data", "blob", "about", "file"]

    /// - Parameter shown: the address the user could see before choosing the link (the text
    ///   printed, or a hover preview of an OSC 8 target); nil when it was hidden behind a label.
    public static func action(for url: URL, shown: String?) -> Action {
        guard let scheme = url.scheme?.lowercased(), !refused.contains(scheme) else { return .refuse }
        guard scheme == "http" || scheme == "https" else { return .confirm }
        // `https://github.com@evil.example` reads as GitHub.
        if url.user != nil || url.password != nil { return .confirm }
        return shown == url.absoluteString || shown == url.relativeString ? .open : .confirm
    }

    /// The address to show before opening: every character visible, so bidi controls and
    /// zero-width characters cannot dress it up as another.
    public static func display(_ url: URL) -> String {
        String(String.UnicodeScalarView(url.absoluteString.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .control)
        }))
    }

    /// Whether a local file may open in its default app. Apps, scripts, executables, packages,
    /// disk images and any declared type that is not plainly a document (`.webloc`,
    /// `.terminal`, `.mobileconfig`) are shown in the Finder instead: opening them could run
    /// something.
    public static func opensInDefaultApp(_ url: URL) -> Bool {
        let url = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isExecutableKey, .contentTypeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isPackage != true else { return false }
        if values.isDirectory == true { return true }
        guard values.isRegularFile == true, values.isExecutable != true, let type = values.contentType else { return false }
        let active: [UTType] = [.executable, .script, .application, .bundle, .package, .diskImage, .archive, .aliasFile, .symbolicLink]
        if active.contains(where: type.conforms) { return false }
        // A type no app declared (`.rs` on most Macs) has no handler that could run it.
        let documents: [UTType] = [.text, .image, .pdf, .audiovisualContent]
        return type.isDynamic || documents.contains(where: type.conforms)
    }
}
