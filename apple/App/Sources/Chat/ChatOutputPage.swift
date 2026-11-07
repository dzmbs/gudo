import Foundation
import HostKit

nonisolated enum ChatOutputLimits {
    static let pageBytes: UInt32 = 64 * 1_024
    static let pageLines = 4_096
    static let jsonBytes = Int(pageBytes) * 6 + 1_024
    static let previousPages = 64
}

nonisolated struct ChatOutputPage: Sendable {
    let text: String
    let offset: UInt64
    let nextOffset: UInt64?
    let totalBytes: UInt64

    init(_ response: TimelineToolOutput, offset: UInt64) throws {
        let bytes = response.text.utf8.count
        let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes))
        guard bytes <= ChatOutputLimits.pageBytes, !overflow, end <= response.totalBytes else {
            throw ChatOutputError.invalidPage
        }
        if let next = response.nextOffset {
            guard next == end, next > offset, next < response.totalBytes else { throw ChatOutputError.invalidPage }
        } else if end != response.totalBytes {
            throw ChatOutputError.invalidPage
        }
        text = Self.visiblePrefix(response.text)
        self.offset = offset
        totalBytes = response.totalBytes
        let visibleEnd = offset + UInt64(text.utf8.count)
        nextOffset = visibleEnd < totalBytes ? visibleEnd : nil
    }

    private static func visiblePrefix(_ text: String) -> String {
        var newlines = 0
        for index in text.utf8.indices where text.utf8[index] == 10 {
            newlines += 1
            if newlines == ChatOutputLimits.pageLines { return String(text[..<index]) }
        }
        return text
    }
}

nonisolated enum ChatOutputError: Error, LocalizedError {
    case invalidPage, changed

    var errorDescription: String? {
        switch self {
        case .invalidPage: "This output page is not supported. Open Terminal."
        case .changed: "This output changed. Reopen it or use Terminal."
        }
    }
}
