import Foundation

/// A standalone drawing's `.excalidraw` file on the host, as plain data: its default name, the
/// scene read from it, and the bytes written back. The daemon's scene remembers the file in its
/// app state under `pathKey`, which never reaches the file itself.
nonisolated enum DrawingFile {
    static let fileExtension = "excalidraw"
    static let pathKey = "filePath"

    /// `drawing-2026-11-03-1412.excalidraw`, `-2` and on when that name is taken.
    static func name(at date: Date, attempt: Int = 1, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d-%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        let suffix = attempt > 1 ? "-\(attempt)" : ""
        return "drawing-\(stamp)\(suffix).\(fileExtension)"
    }

    /// A typed name with the extension added when it is missing; nil for one that is empty or
    /// names a folder.
    static func renamed(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return (trimmed as NSString).pathExtension.lowercased() == fileExtension ? trimmed : "\(trimmed).\(fileExtension)"
    }

    static func isDrawing(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == fileExtension
    }

    /// The file as written: the daemon's export without the host's own app-state keys.
    static func contents(fromExport data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if var appState = object["appState"] as? [String: Any] {
            appState[pathKey] = nil
            object["appState"] = appState
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? data
    }

    struct Scene {
        /// Each element as JSON.
        var elements: [String]
        var appState: [String: Any]
        var files: [Embedded]
    }

    struct Embedded: Equatable {
        var id: String
        var mimeType: String
        var data: Data
    }

    enum ReadError: Error, Equatable {
        case notAScene
    }

    /// Reads a scene Excalidraw wrote (or this app): its elements, the app state worth keeping
    /// (background and grid) and its embedded images.
    static func scene(from data: Data) throws -> Scene {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "excalidraw" || object["elements"] != nil,
              let elements = object["elements"] as? [[String: Any]]
        else { throw ReadError.notAScene }
        let encoded = elements.compactMap { element -> String? in
            guard element["isDeleted"] as? Bool != true,
                  let data = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let appState = (object["appState"] as? [String: Any] ?? [:]).filter { ["viewBackgroundColor", "gridSize"].contains($0.key) }
        var files: [Embedded] = []
        for case let (id, value as [String: Any]) in object["files"] as? [String: Any] ?? [:] {
            guard let url = value["dataURL"] as? String, let comma = url.firstIndex(of: ","),
                  let bytes = Data(base64Encoded: String(url[url.index(after: comma)...]))
            else { continue }
            files.append(Embedded(id: id, mimeType: value["mimeType"] as? String ?? "image/png", data: bytes))
        }
        return Scene(elements: encoded, appState: appState, files: files.sorted { $0.id < $1.id })
    }

    /// Where a new drawing goes: the repository's top level, else the pane's folder, else home.
    static func folder(directory: String?, repositoryRoot: String?) -> String {
        [repositoryRoot, directory].compactMap { $0 }.first { !$0.isEmpty } ?? "~"
    }
}
