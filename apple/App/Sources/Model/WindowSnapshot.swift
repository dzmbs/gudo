#if os(macOS) && DEBUG
import AppKit
import TerminalRenderer

/// Design review on a Mac whose screen can't be captured (locked, or no Screen Recording
/// permission): `-snapshot <path.png>` draws the key window, titlebar included, into a PNG a few
/// seconds after launch. AppKit's cached display skips Metal layers, so each terminal's own
/// `snapshot()` is drawn into its frame on top. Debug builds only.
enum WindowSnapshot {
    static func scheduleIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "snapshot") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "snapshotDelay").nonZero ?? 4))
            NSApp.activate()
            // A locked screen can defer window creation; File > New Window makes one.
            if NSApp.windows.isEmpty {
                for item in NSApp.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }) ?? [] where item.title == "New Window" {
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                }
                try? await Task.sleep(for: .seconds(4))
            }
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 300 }),
                  let frameView = window.contentView?.superview
            else {
                FileHandle.standardError.write(Data("snapshot: no window among \(NSApp.windows)\n".utf8))
                return
            }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            frameView.cacheDisplay(in: bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for view in terminalViews(in: frameView) {
                _ = view.surface.renderIfDirty(offscreen: true)
                guard let image = view.surface.snapshot() else { continue }
                let rect = view.convert(view.bounds, to: frameView)
                NSGraphicsContext.current?.cgContext.draw(image, in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // Vibrant (sidebar) content does not draw into `cacheDisplay`; list what is there instead.
            var lines: [String] = []
            func visit(_ view: NSView, depth: Int) {
                if let table = view as? NSTableView {
                    let frame = table.convert(table.bounds, to: nil)
                    lines.append("\(type(of: table)) rows=\(table.numberOfRows) frame=\(frame) visible=\(!table.isHiddenOrHasHiddenAncestor)")
                }
                view.subviews.forEach { visit($0, depth: depth + 1) }
            }
            visit(frameView, depth: 0)
            try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            if UserDefaults.standard.bool(forKey: "snapshotQuit") { NSApp.terminate(nil) }
        }
    }

    private static func terminalViews(in view: NSView) -> [TerminalView] {
        view.subviews.flatMap { subview -> [TerminalView] in
            (subview as? TerminalView).map { [$0] } ?? terminalViews(in: subview)
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif
