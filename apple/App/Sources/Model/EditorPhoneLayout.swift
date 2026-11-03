import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// VS Code on a phone: the workbench laid out as in a small desktop window and scaled to fit,
/// with defaults that suit a narrow screen.
///
/// The page's viewport is set to that window's width and scale, as a desktop site is shown on a
/// phone: VS Code lays out for the wider window (`innerWidth` is its width), text is drawn at the
/// final scale so it stays sharp. The pane's More menu zooms in and out from there.
// `WKWebView.pageZoom` on iOS shrinks the drawing without widening the layout viewport, and
// VS Code's `window.zoomLevel` does nothing in a browser.
enum EditorPhoneLayout {
    /// The smallest window the workbench is laid out in: an editor of about 80 columns once the
    /// sidebar is closed, and enough rows for the editor between title bar, tabs and status bar.
    static let layoutWidth: CGFloat = 600
    static let layoutHeight: CGFloat = 400
    /// Below this, text gets too small to read without zooming in.
    static let minimumScale: CGFloat = 0.6

    @MainActor static var isPhone: Bool {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// The user's zoom over the fitted scale (More ▸ Zoom In / Zoom Out), for every editor.
    static let zoomKey = "editorPhoneZoom"
    static let zoomSteps: [CGFloat] = [0.8, 0.9, 1, 1.15, 1.3, 1.5]

    static var zoom: CGFloat {
        let stored = UserDefaults.standard.double(forKey: zoomKey)
        return zoomSteps.contains(CGFloat(stored)) ? CGFloat(stored) : 1
    }

    /// The next zoom step in `direction` (+1 in, -1 out), nil past the last.
    static func zoom(from current: CGFloat, by direction: Int) -> CGFloat? {
        guard let index = zoomSteps.firstIndex(of: current) else { return 1 }
        let next = index + direction
        return zoomSteps.indices.contains(next) ? zoomSteps[next] : nil
    }

    /// The scale for an editor pane of this size, in steps of 0.05 so a small change in the pane
    /// (a bar coming or going) does not reflow the workbench.
    static func scale(for size: CGSize, zoom: CGFloat = 1) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let fit = max(minimumScale, min(size.width / layoutWidth, size.height / layoutHeight, 1))
        let stepped = (fit * zoom * 20).rounded(.down) / 20
        return min(max(stepped, 0.5), 1.5)
    }

    /// The viewport for an editor pane of this size: as wide as the pane at `scale(for:zoom:)`.
    /// The scale is fixed: iOS would otherwise zoom into every field VS Code focuses, its text
    /// being smaller than 16 px.
    static func viewport(for size: CGSize, zoom: CGFloat = 1) -> String? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = scale(for: size, zoom: zoom)
        let width = Int((size.width / scale).rounded())
        let fixed = String(format: "%.2f", Double(scale))
        return "width=\(width), initial-scale=\(fixed), minimum-scale=\(fixed), maximum-scale=\(fixed), user-scalable=no, viewport-fit=cover"
    }

    /// Sets the page's viewport to `content`, now or as soon as the page declares its own, and
    /// keeps it there if the page changes it back. Text autosizing, which a wide viewport turns
    /// on, would enlarge some of VS Code's text and not its measured line heights.
    static func viewportScript(_ content: String, createsMissing: Bool = false) -> String {
        """
        (() => {
          const content = \(javaScriptString(content));
          const apply = () => {
            let meta = document.querySelector('meta[name="viewport"]');
            if (!meta && \(createsMissing) && document.head) {
              meta = document.createElement('meta');
              meta.name = 'viewport';
              document.head.append(meta);
            }
            if (!meta) return false;
            if (!document.getElementById('gudo-text-size')) {
              const style = document.createElement('style');
              style.id = 'gudo-text-size';
              style.textContent = 'html { -webkit-text-size-adjust: 100% !important; }';
              meta.after(style);
            }
            const kept = meta.dataset.gudoViewport !== undefined;
            meta.dataset.gudoViewport = content;
            if (meta.content !== content) meta.content = content;
            if (!kept) {
              new MutationObserver(() => {
                if (meta.content !== meta.dataset.gudoViewport) meta.content = meta.dataset.gudoViewport;
              }).observe(meta, { attributes: true, attributeFilter: ['content'] });
            }
            return true;
          };
          if (!apply()) {
            const observer = new MutationObserver(() => { if (apply()) observer.disconnect(); });
            observer.observe(document, { childList: true, subtree: true });
          }
        })();
        """
    }

    static func viewportUserScript(_ content: String) -> WKUserScript {
        WKUserScript(source: viewportScript(content), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static func javaScriptString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// Defaults under the user's own settings: anything they set themselves still wins, and
    /// nothing is written to their settings files.
    static let settings: [String: Any] = [
        "editor.wordWrap": "on",
        "editor.minimap.enabled": false,
        "editor.stickyScroll.enabled": false,
        "editor.fontSize": 13,
        "workbench.activityBar.location": "top",
        "workbench.secondarySideBar.defaultVisibility": "hidden",
    ]

    enum Command: String, CaseIterable {
        case explorer, search, quickOpen, commandPalette

        var title: String {
            switch self {
            case .explorer: "Explorer"
            case .search: "Search"
            case .quickOpen: "Go to File"
            case .commandPalette: "Command Palette"
            }
        }

        var systemImage: String {
            switch self {
            case .explorer: "sidebar.left"
            case .search: "magnifyingglass"
            case .quickOpen: "doc.text.magnifyingglass"
            case .commandPalette: "command"
            }
        }

        /// The sidebar view it shows, which a second tap hides.
        var sidebarView: String? {
            switch self {
            case .explorer: "workbench.view.explorer"
            case .search: "workbench.view.search"
            case .quickOpen, .commandPalette: nil
            }
        }

        /// VS Code's default key for it.
        var key: Key {
            switch self {
            case .explorer: Key(code: "KeyE", key: "e", keyCode: 69, meta: true, shift: true)
            case .search: Key(code: "KeyF", key: "f", keyCode: 70, meta: true, shift: true)
            case .quickOpen: Key(code: "KeyP", key: "p", keyCode: 80, meta: true)
            case .commandPalette: Key(code: "KeyP", key: "p", keyCode: 80, meta: true, shift: true)
            }
        }
    }

    struct Key: Equatable {
        let code: String
        let key: String
        let keyCode: Int
        var meta = false
        var shift = false
        var control = false
        var option = false

        static let toggleSidebar = Key(code: "KeyB", key: "b", keyCode: 66, meta: true)
        static let escape = Key(code: "Escape", key: "Escape", keyCode: 27)
        static let tab = Key(code: "Tab", key: "Tab", keyCode: 9)
        static let left = Key(code: "ArrowLeft", key: "ArrowLeft", keyCode: 37)
        static let up = Key(code: "ArrowUp", key: "ArrowUp", keyCode: 38)
        static let right = Key(code: "ArrowRight", key: "ArrowRight", keyCode: 39)
        static let down = Key(code: "ArrowDown", key: "ArrowDown", keyCode: 40)

        /// Above the software keyboard (`EditorKeyRow`).
        static let row: [Key] = [.escape, .tab, .left, .down, .up, .right]

        var label: String? {
            switch code {
            case "Escape": "esc"
            case "Tab": "tab"
            default: nil
            }
        }

        var symbol: String? {
            switch code {
            case "ArrowLeft": "arrow.left"
            case "ArrowUp": "arrow.up"
            case "ArrowRight": "arrow.right"
            case "ArrowDown": "arrow.down"
            default: nil
            }
        }

        var accessibilityLabel: String {
            code.hasPrefix("Arrow") ? String(code.dropFirst("Arrow".count)) : key
        }

        var json: String {
            "{code:'\(code)',key:'\(key)',keyCode:\(keyCode),metaKey:\(meta),shiftKey:\(shift),ctrlKey:\(control),altKey:\(option)}"
        }
    }

    /// Presses `key` in the page as VS Code's keybinding service reads it: by `code`, with the
    /// legacy `keyCode` too, which synthetic events otherwise leave at 0.
    static let pressFunction = """
        const press = (k) => {
          const target = document.activeElement || document.body;
          for (const type of ['keydown', 'keyup']) {
            const event = new KeyboardEvent(type, {
              key: k.key, code: k.code, metaKey: k.metaKey, shiftKey: k.shiftKey,
              ctrlKey: k.ctrlKey, altKey: k.altKey, bubbles: true, cancelable: true, composed: true });
            Object.defineProperty(event, 'keyCode', { get: () => k.keyCode });
            Object.defineProperty(event, 'which', { get: () => k.keyCode });
            target.dispatchEvent(event);
          }
        };
        const sidebarView = () => {
          const part = document.querySelector('.monaco-workbench .part.sidebar');
          if (!part || part.offsetWidth === 0 || part.offsetHeight === 0) return null;
          const view = part.querySelector('.content .composite[id]');
          return view ? view.id : '';
        };
        """

    static func script(for key: Key) -> String {
        "\(pressFunction)\npress(\(key.json));"
    }

    /// Runs `command`, or hides the sidebar when it already shows the command's view.
    static func script(for command: Command) -> String {
        let hide = command.sidebarView.map { "if (sidebarView() === '\($0)') { press(\(Key.toggleSidebar.json)); return; }" } ?? ""
        return """
            \(pressFunction)
            \(hide)
            press(\(command.key.json));
            """
    }

    /// Puts `settings` into the page's workbench configuration before VS Code reads it, and closes
    /// the sidebar the first time a folder opens on this phone (VS Code remembers it from then on).
    static var userScript: WKUserScript {
        WKUserScript(source: userScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static var userScriptSource: String {
        let defaults = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
            (() => {
              const defaults = \(defaults);
              const configure = () => {
                const meta = document.getElementById('vscode-workbench-web-configuration');
                if (!meta) return false;
                try {
                  const configuration = JSON.parse(meta.getAttribute('data-settings') || '{}');
                  configuration.configurationDefaults = Object.assign({}, defaults, configuration.configurationDefaults || {});
                  meta.setAttribute('data-settings', JSON.stringify(configuration));
                } catch (error) {}
                return true;
              };
              if (!configure()) {
                const observer = new MutationObserver(() => { if (configure()) observer.disconnect(); });
                observer.observe(document, { childList: true, subtree: true });
              }
              \(pressFunction)
              const seenKey = 'gudo.phoneLayout:' + location.pathname + location.search;
              let seen = false;
              try { seen = localStorage.getItem(seenKey) !== null; } catch (error) {}
              if (seen) return;
              let tries = 0;
              const closeSidebar = () => {
                if (++tries > 60) return;
                const view = sidebarView();
                if (!document.querySelector('.monaco-workbench .part.editor') || view === '') {
                  setTimeout(closeSidebar, 500);
                  return;
                }
                try { localStorage.setItem(seenKey, '1'); } catch (error) {}
                if (view !== null) press(\(Key.toggleSidebar.json));
              };
              addEventListener('load', () => setTimeout(closeSidebar, 1000));
            })();
            """
    }
}
