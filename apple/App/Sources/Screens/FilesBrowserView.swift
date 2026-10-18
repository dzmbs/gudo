import DesignSystem
import SwiftUI

/// Browse a host's files (stub).
struct FilesBrowserView: View {
    let source: any FileSource
    var onOpen: (FileEntry) -> Void = { _ in }

    var body: some View { Text("Files") }
}
