#if os(macOS)
import Foundation
import Sparkle

/// The updater's user interface. Scheduled updates, and checks asked for from a window that
/// shows the sidebar, play out in the sidebar's control (`UpdatePrompt`); a check asked for
/// anywhere else (Settings, no window, sidebar hidden) gets the standard windows, so the answer
/// appears where it was asked. One session never switches between the two.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    private enum Route {
        case sidebar, standard
    }

    private let standard: SPUStandardUserDriver
    private let prompt: UpdatePrompt
    private let sidebarIsFrontmost: () -> Bool
    private var route: Route?

    init(prompt: UpdatePrompt, sidebarIsFrontmost: @escaping () -> Bool) {
        standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        self.prompt = prompt
        self.sidebarIsFrontmost = sidebarIsFrontmost
    }

    /// The session's route, the sidebar for one the updater started on its own.
    private var current: Route {
        if let route { return route }
        route = .sidebar
        return .sidebar
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        route = .standard
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        route = sidebarIsFrontmost() ? .sidebar : .standard
        switch current {
        case .sidebar: prompt.checkStarted(cancellation: cancellation)
        case .standard: standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        switch current {
        case .sidebar:
            prompt.found(UpdateOffer(appcastItem), stage: UpdateStage(state.stage), userInitiated: state.userInitiated) { choice in
                reply(SPUUserUpdateChoice(choice))
            }
        case .standard:
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        switch current {
        case .sidebar:
            if let notes = ReleaseNotes.text(data: downloadData.data, mimeType: downloadData.mimeType) { prompt.releaseNotesLoaded(notes) }
        case .standard:
            standard.showUpdateReleaseNotes(with: downloadData)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        if current == .standard { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        switch current {
        case .sidebar:
            let error = error as NSError
            let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
            let upToDate = reason == nil || reason == .onLatestVersion || reason == .onNewerThanLatestVersion || reason == .unknown
            prompt.notFound(upToDate: upToDate, message: error.localizedRecoverySuggestion ?? error.localizedDescription)
            acknowledgement()
        case .standard:
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        switch current {
        case .sidebar:
            prompt.failed(error.localizedDescription)
            acknowledgement()
        case .standard:
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        switch current {
        case .sidebar: prompt.downloadStarted(cancellation: cancellation)
        case .standard: standard.showDownloadInitiated(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        switch current {
        case .sidebar: prompt.downloadExpects(expectedContentLength)
        case .standard: standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        switch current {
        case .sidebar: prompt.downloadReceived(length)
        case .standard: standard.showDownloadDidReceiveData(ofLength: length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        switch current {
        case .sidebar: prompt.extractionStarted()
        case .standard: standard.showDownloadDidStartExtractingUpdate()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        switch current {
        case .sidebar: prompt.extractionProgressed(progress)
        case .standard: standard.showExtractionReceivedProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        switch current {
        case .sidebar: prompt.readyToInstall { reply(SPUUserUpdateChoice($0)) }
        case .standard: standard.showReady(toInstallAndRelaunch: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        switch current {
        case .sidebar:
            prompt.installing(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication)
            if !applicationTerminated {
                Task { [prompt] in
                    try? await Task.sleep(for: .seconds(3))
                    prompt.restartStalled()
                }
            }
        case .standard:
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        switch current {
        case .sidebar: acknowledgement()
        case .standard: standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
        }
    }

    func showUpdateInFocus() {
        switch current {
        case .sidebar: prompt.focus()
        case .standard: standard.showUpdateInFocus()
        }
    }

    func dismissUpdateInstallation() {
        switch route {
        case .standard: standard.dismissUpdateInstallation()
        case .sidebar, nil: prompt.finished()
        }
        route = nil
    }
}

extension UpdateOffer {
    init(_ item: SUAppcastItem) {
        self.init(
            version: item.versionString,
            displayVersion: item.displayVersionString,
            notes: item.itemDescription.flatMap { ReleaseNotes.text($0, format: item.itemDescriptionFormat) },
            notesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL,
            isInformationOnly: item.isInformationOnlyUpdate,
            infoURL: item.infoURL)
    }
}

extension UpdateStage {
    init(_ stage: SPUUserUpdateStage) {
        switch stage {
        case .downloaded: self = .downloaded
        case .installing: self = .installing
        default: self = .notDownloaded
        }
    }
}

extension SPUUserUpdateChoice {
    init(_ choice: UpdateChoice) {
        switch choice {
        case .install: self = .install
        case .dismiss: self = .dismiss
        case .skip: self = .skip
        }
    }
}
#endif
