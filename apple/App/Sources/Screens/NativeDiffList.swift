import SwiftUI

struct NativeDiffList<Content: View>: View {
    let document: DiffRenderDocument
    @ViewBuilder var content: (DiffRenderRow) -> Content

    var body: some View {
        NativeVirtualList(document: document.layout) { index in
            content(document.rows[index])
        }
    }
}
