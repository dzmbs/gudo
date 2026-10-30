import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a window shows while the app is locked: the app's icon and Unlock, on the theme's
/// own background, with nothing of the window behind it. Without the lock (an iPhone or iPad
/// window leaving the screen) only the icon, so the app switcher shows no terminal.
struct AppLockScreen: View {
    let lock: AppLock
    /// The window is in front and may ask on its own (once per return).
    var prompts = true

    var body: some View {
        ThemedRoot { content }
    }

    private var content: some View {
        VStack(spacing: DS.Space.l) {
            AppIconImage()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            if lock.isLocked {
                VStack(spacing: DS.Space.xs) {
                    Text("\(Brand.name) Is Locked")
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.text)
                    Text(lock.failure ?? "Unlock with \((lock.method ?? .passcode).name) to continue.")
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock", systemImage: (lock.method ?? .passcode).systemImage)
                        .padding(.horizontal, DS.Space.s)
                }
                .buttonStyle(.primaryGlass)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)
                .padding(.top, DS.Space.xs)
                .accessibilityIdentifier("app-lock-unlock")
            }
        }
        .frame(maxWidth: 320)
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(DS.Palette.base).ignoresSafeArea() }
        .chromeContent()
        .animation(DS.Motion.overlay, value: lock.isLocked)
        .task(id: lock.isLocked) {
            guard prompts, lock.isLocked, Self.appIsActive else { return }
            await lock.promptIfNeeded()
        }
    }

    private static var appIsActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }
}

/// The app's own icon as the system shows it.
private struct AppIconImage: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
        #else
        if let icon = Self.icon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .clipShape(.rect(cornerRadius: 20, style: .continuous))
        } else {
            Image(systemName: "lock.fill")
                .resizable()
                .scaledToFit()
                .padding(DS.Space.xl)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        #endif
    }

    #if os(iOS)
    /// The largest of the icon files the bundle lists.
    private static let icon: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        return files.reversed().lazy.compactMap { UIImage(named: $0) }.first ?? UIImage(named: "AppIcon")
    }()
    #endif
}
