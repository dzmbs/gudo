import DesignSystem
import HostKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The Tailscale app on this device: whether it is installed, and opening it. A tailnet host
/// (`HostKit.Tailscale`) is reachable only while it is connected here.
enum TailscaleApp {
    #if os(macOS)
    /// The standalone build and the Mac App Store build.
    private static let bundleIds = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]

    private static var appURL: URL? {
        bundleIds.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var isInstalled: Bool { appURL != nil }

    static func open() {
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
    #else
    /// Listed in `LSApplicationQueriesSchemes` (project.yml).
    private static let url = URL(string: "tailscale://")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(url) }

    static func open() {
        UIApplication.shared.open(url)
    }
    #endif
}

/// "Tailscale": a quiet outlined tag next to a tailnet host's name (the PR badge's shape).
struct TailscaleTag: View {
    var body: some View {
        Text("Tailscale")
            .font(DS.Font.badge)
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Palette.textTertiary, lineWidth: 0.5))
            .fixedSize()
            .accessibilityLabel("On Tailscale")
            .accessibilityIdentifier("tailscale-tag")
    }
}

/// Why a tailnet host can't be reached, and the way out: connect Tailscale on this device.
/// `compact` is the one-line form for a host row; otherwise a footnote with the Open button.
struct TailscaleHint: View {
    var compact = false

    var body: some View {
        if compact {
            Label("Connect Tailscale on this device to reach it.", systemImage: "network")
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(2)
                .accessibilityIdentifier("tailscale-hint")
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label(Tailscale.connectHint, systemImage: "network")
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if TailscaleApp.isInstalled {
                    Button("Open Tailscale", systemImage: "arrow.up.forward.app", action: TailscaleApp.open)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityIdentifier("tailscale-open")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tailscale-hint")
        }
    }
}
