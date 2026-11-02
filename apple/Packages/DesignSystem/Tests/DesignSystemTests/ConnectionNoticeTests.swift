#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The reconnecting notice fits an iPhone-wide pane: it drops "last contact", then shortens the
/// host's name, and keeps the time.
@MainActor
@Suite struct ConnectionNoticeTests {
    @Test func theCopyGivesWayInOrder() {
        let copy = NoticeCopy.reconnecting(to: "studio-MacBook-Pro.local", ago: "12s ago")
        #expect(copy.text == "Reconnecting to studio-MacBook-Pro.local… · last contact 12s ago")
        #expect(copy.compactAfter == "… · 12s ago", "the time survives the short line")
        #expect(NoticeCopy.shortHost("studio-MacBook-Pro.local") == "studio-MacBook-Pro")
        #expect(NoticeCopy.shortHost("box.tail1234.ts.net") == "box")
        #expect(NoticeCopy.shortHost("studio") == "studio")
        // An address is a name of its own: never cut at its dots.
        #expect(NoticeCopy.shortHost("192.168.1.20") == "192.168.1.20")
    }

    /// Rendered at an iPhone pane's width, the whole notice stays inside it.
    @Test func theNoticeFitsAPhoneWidePane() throws {
        let width: CGFloat = 320
        let notice = ConnectionNotice(
            state: .reconnecting(attempt: 2, since: .now), copy: .reconnecting(to: "studio-MacBook-Pro.local", ago: "12s ago"))
        let hosting = NSHostingView(rootView: notice.frame(maxWidth: width, alignment: .trailing))
        let size = hosting.fittingSize
        #expect(size.width <= width + 0.5, "\(size)")
        if let path = ProcessInfo.processInfo.environment["NOTICE_PNG"] {
            let renderer = ImageRenderer(content: notice.frame(width: width, alignment: .trailing).padding(8).background(.black))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            try NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
