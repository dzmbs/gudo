#if os(macOS)
import AppKit
import Carbon
import OSLog
import SwiftUI

/// Secure Keyboard Entry while a focused terminal reads a password, so other apps' keyboard
/// monitors cannot see it (ported from Ghostty's `SecureInput`).
///
/// It is global to the system and reference-counted: every `EnableSecureEventInput` is balanced
/// by one `DisableSecureEventInput`, and it is given up while the app is not active, where it
/// would hold back the keyboard of the app in front.
@MainActor
@Observable
final class SecureKeyboardEntry {
    struct System {
        var enable: @MainActor () -> OSStatus
        var disable: @MainActor () -> OSStatus
        var isAppActive: @MainActor () -> Bool
    }

    static let shared = SecureKeyboardEntry(system: System(
        enable: { EnableSecureEventInput() }, disable: { DisableSecureEventInput() }, isAppActive: { NSApp.isActive }))

    private(set) var isEnabled = false
    /// Each pane view that asked, and whether it wants it now (focused, at a password prompt).
    @ObservationIgnored private var scopes: [UUID: Bool] = [:]
    @ObservationIgnored private let system: System
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "secure-input")

    init(system: System, notifications: NotificationCenter = .default) {
        self.system = system
        let changes: [(Notification.Name, @MainActor (SecureKeyboardEntry) -> Void)] = [
            (NSApplication.didBecomeActiveNotification, { $0.apply() }),
            (NSApplication.didResignActiveNotification, { $0.resign() }),
        ]
        observers = changes.map { name, change in
            notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self)
                }
            }
        }
    }

    private var isWanted: Bool { scopes.values.contains(true) }

    func set(_ scope: UUID, wanted: Bool) {
        scopes[scope] = wanted
        apply()
    }

    func remove(_ scope: UUID) {
        scopes[scope] = nil
        apply()
    }

    private func apply() {
        guard system.isAppActive(), isEnabled != isWanted else { return }
        turn(on: isWanted)
    }

    private func resign() {
        guard isEnabled else { return }
        turn(on: false)
    }

    private func turn(on: Bool) {
        let status = on ? system.enable() : system.disable()
        guard status == noErr else {
            Self.log.error("secure input \(on ? "enable" : "disable", privacy: .public) failed: \(status)")
            return
        }
        isEnabled = on
    }
}

/// Asks for Secure Keyboard Entry while `atPasswordPrompt` holds and the pane's window is key;
/// gives it back when that ends or the pane goes away.
private struct SecureKeyboardEntryScope: ViewModifier {
    let atPasswordPrompt: Bool
    @State private var scope = UUID()
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let wanted = atPasswordPrompt && appearsActive
        content
            .onAppear { SecureKeyboardEntry.shared.set(scope, wanted: wanted) }
            .onChange(of: wanted) { _, wanted in SecureKeyboardEntry.shared.set(scope, wanted: wanted) }
            .onDisappear { SecureKeyboardEntry.shared.remove(scope) }
    }
}

extension View {
    func secureKeyboardEntry(atPasswordPrompt: Bool) -> some View {
        modifier(SecureKeyboardEntryScope(atPasswordPrompt: atPasswordPrompt))
    }
}
#endif
