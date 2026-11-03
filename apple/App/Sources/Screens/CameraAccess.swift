import AVFoundation
import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The camera permission the QR scanner needs. Read again whenever the app comes back to the
/// foreground, so allowing it in Settings turns the viewfinder live.
@MainActor @Observable
final class CameraAccess {
    enum Status { case undetermined, allowed, denied, restricted }

    private(set) var status = CameraAccess.current

    var isOff: Bool { status == .denied || status == .restricted }

    func refresh() {
        status = Self.current
    }

    func requestIfUndetermined() async {
        guard status == .undetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
    }

    static var current: Status {
        if let simulated { return simulated }
        return switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    /// `-simulateCameraAccess denied|restricted|allowed` on a debug build's command line, for the
    /// simulator, which has no camera.
    static var simulated: Status? {
        #if DEBUG
        switch UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["simulateCameraAccess"] as? String {
        case "denied": .denied
        case "restricted": .restricted
        case "allowed": .allowed
        default: nil
        }
        #else
        nil
        #endif
    }
}

#if os(iOS)
/// What the viewfinder shows while the camera is off for this app: why, and the way to Settings.
struct CameraAccessOffView: View {
    let restricted: Bool

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text(restricted ? "Camera access is restricted" : "Camera access is off")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(restricted ? "This device doesn’t allow the camera here." : "Allow it in Settings to scan the host’s code.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            if !restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("camera-open-settings")
            }
        }
        .padding(.horizontal, DS.Space.xl)
    }
}
#endif
