import Foundation
import HostKit
import Observation

@MainActor
@Observable
final class ChatOutputReader {
    typealias Source = @MainActor (UInt64, UInt32) async throws -> String
    private(set) var page: ChatOutputPage?
    private(set) var error: String?
    private(set) var isLoading = false
    private var previousOffsets: [UInt64] = []
    @ObservationIgnored private let source: Source
    @ObservationIgnored private var request = UUID()

    var previousOffset: UInt64? { previousOffsets.last }

    init(source: @escaping Source) { self.source = source }

    func cancel() {
        request = UUID()
        isLoading = false
    }

    func load(offset: UInt64 = 0) async {
        let ticket = UUID()
        request = ticket
        isLoading = true
        error = nil
        defer { if request == ticket { isLoading = false } }
        do {
            let json = try await source(offset, ChatOutputLimits.pageBytes)
            guard request == ticket, !Task.isCancelled else { return }
            let loaded = try await Task.detached(priority: .userInitiated) {
                guard json.utf8.count <= ChatOutputLimits.jsonBytes else {
                    throw ChatOutputError.invalidPage
                }
                return try ChatOutputPage(TimelineJSON.decode(TimelineToolOutput.self, from: json), offset: offset)
            }.value
            guard request == ticket, !Task.isCancelled else { return }
            if let page, offset != 0, loaded.totalBytes != page.totalBytes { throw ChatOutputError.changed }
            remember(offset)
            page = loaded
        } catch {
            guard request == ticket, !Task.isCancelled else { return }
            self.error = (error as? ChatOutputError)?.errorDescription
                ?? "Output could not load. Try again or open Terminal."
        }
    }

    private func remember(_ offset: UInt64) {
        if offset == 0 {
            previousOffsets.removeAll(keepingCapacity: false)
        } else if offset == previousOffsets.last {
            previousOffsets.removeLast()
        } else if let page, offset != page.offset {
            previousOffsets.append(page.offset)
            if previousOffsets.count > ChatOutputLimits.previousPages { previousOffsets.removeFirst() }
        }
    }
}
