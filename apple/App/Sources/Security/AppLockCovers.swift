import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Puts `AppLockScreen` over every window while the app is locked: a window of its own above
/// each scene's windows (iOS) or each app window (Mac), so sheets, popovers, alerts and tool
/// windows are covered too, and the keyboard goes to the cover, never to a terminal behind it.
/// On iPhone and iPad a window also gets the cover while it is off the front, so the app
/// switcher's snapshot shows no terminal.
@MainActor
final class AppLockCovers {
    static let shared = AppLockCovers()

    private let lock: AppLock
    private var observers: [NSObjectProtocol] = []

    init(lock: AppLock = .shared) {
        self.lock = lock
    }

    #if os(iOS)
    private var covers: [ObjectIdentifier: UIWindow] = [:]

    func install() {
        guard observers.isEmpty else { return }
        lock.onChange = { [weak self] in self?.syncAll() }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (UIWindowScene) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let scene = note.object as? UIWindowScene else { return }
                MainActor.assumeIsolated { handler(scene) }
            })
        }
        // The app's phase, before any scene comes back on screen.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.lock.didEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.lock.willEnterForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Task { await self.lock.promptIfNeeded() } }
        })
        observe(UIScene.willConnectNotification) { [weak self] in self?.sync($0, active: false) }
        observe(UIScene.willDeactivateNotification) { [weak self] in self?.sync($0, active: false) }
        observe(UIScene.didEnterBackgroundNotification) { [weak self] in self?.sync($0, active: false) }
        observe(UIScene.didActivateNotification) { [weak self] in self?.sync($0, active: true) }
        observe(UIScene.didDisconnectNotification) { [weak self] in self?.covers[ObjectIdentifier($0)] = nil }
        // A window of the app taking the keyboard while locked gives it back to the cover.
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { self.keepKeyboard(from: window) }
        })
        syncAll()
    }

    private func syncAll() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            sync(scene, active: scene.activationState == .foregroundActive)
        }
    }

    private func sync(_ scene: UIWindowScene, active: Bool) {
        let shows = lock.isEnabled && (lock.isLocked || !active)
        let key = ObjectIdentifier(scene)
        if shows {
            let cover = covers[key] ?? makeCover(in: scene)
            covers[key] = cover
            cover.isHidden = false
            if lock.isLocked { cover.makeKey() }
        } else if let cover = covers[key], !cover.isHidden {
            cover.isHidden = true
            // The scene's own window takes the keyboard back.
            scene.windows.first { $0 !== cover && !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
        }
    }

    private func makeCover(in scene: UIWindowScene) -> UIWindow {
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        let controller = UIHostingController(rootView: AppLockScreen(lock: lock))
        controller.view.backgroundColor = .clear
        // VoiceOver reads the lock, not the windows under it.
        controller.view.accessibilityViewIsModal = true
        cover.rootViewController = controller
        return cover
    }

    private func keepKeyboard(from window: UIWindow) {
        guard lock.isLocked, let scene = window.windowScene, let cover = covers[ObjectIdentifier(scene)],
              cover !== window, !cover.isHidden
        else { return }
        cover.makeKey()
    }
    #else
    /// The cover over each app window, by the window it covers.
    private var covers: [ObjectIdentifier: (window: NSWindow, cover: CoverWindow)] = [:]

    /// Borderless, above its window, and able to take the keyboard.
    private final class CoverWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    func install() {
        guard observers.isEmpty else { return }
        lock.onChange = { [weak self] in self?.sync() }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
        // The Mac's "background": another app in front.
        observe(NSApplication.didResignActiveNotification) { [weak self] in self?.lock.didEnterBackground() }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            guard let self else { return }
            lock.willEnterForeground()
            if lock.isLocked { Task { await self.lock.promptIfNeeded() } }
        }
        // Windows that appear, move to the front or resize while locked.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResizeNotification, NSApplication.didUpdateNotification] {
            observe(name) { [weak self] in
                guard let self, lock.isLocked || !covers.isEmpty else { return }
                sync()
            }
        }
        sync()
    }

    private func sync() {
        guard lock.isEnabled, lock.isLocked else {
            removeCovers()
            return
        }
        for window in NSApp.windows where shouldCover(window) {
            let key = ObjectIdentifier(window)
            if let entry = covers[key] {
                if entry.cover.frame != window.frame { entry.cover.setFrame(window.frame, display: true) }
            } else {
                covers[key] = (window, makeCover(over: window))
            }
        }
        // Covers of windows that closed or hid.
        for (key, entry) in covers where !entry.window.isVisible {
            entry.window.removeChildWindow(entry.cover)
            entry.cover.orderOut(nil)
            covers[key] = nil
        }
        // The keyboard never reaches a window behind a cover.
        if let keyWindow = NSApp.keyWindow, !(keyWindow is CoverWindow), let entry = covers[ObjectIdentifier(keyWindow)] {
            entry.cover.makeKeyAndOrderFront(nil)
        }
    }

    private func shouldCover(_ window: NSWindow) -> Bool {
        !(window is CoverWindow) && window.isVisible && window.level < .popUpMenu
            && window.frame.width > 1 && window.frame.height > 1
    }

    private func makeCover(over window: NSWindow) -> CoverWindow {
        let cover = CoverWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.isOpaque = false
        cover.backgroundColor = .clear
        cover.hasShadow = false
        cover.level = window.level
        cover.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let host = NSHostingView(rootView: AppLockScreen(lock: lock, prompts: window.isKeyWindow))
        host.wantsLayer = true
        // The window's own corners (a borderless window has square ones).
        let radius = window.contentView?.superview?.layer?.cornerRadius ?? 0
        host.layer?.cornerRadius = radius > 0 ? radius : 16
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        cover.contentView = host
        cover.setFrame(window.frame, display: false)
        window.addChildWindow(cover, ordered: .above)
        if window.isKeyWindow { cover.makeKeyAndOrderFront(nil) }
        return cover
    }

    private func removeCovers() {
        guard !covers.isEmpty else { return }
        let keyed = covers.values.first { $0.cover.isKeyWindow }?.window
        for entry in covers.values {
            entry.window.removeChildWindow(entry.cover)
            entry.cover.orderOut(nil)
        }
        covers = [:]
        keyed?.makeKey()
    }
    #endif
}
