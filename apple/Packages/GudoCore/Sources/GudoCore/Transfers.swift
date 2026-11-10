// Transfers that stop when the task awaiting them is cancelled. A Rust future does not hear
// Swift task cancellation, so each one is handed a `TransferCancellation` to cancel instead.

import Foundation

extension DaemonClient {
    /// Uploads a local file to the host; cancelling the calling task stops it.
    public func uploadFile(localPath: String, target: WriteTarget, progress: TransferProgress?) async throws -> FileStat {
        try await cancellable { cancellation in
            try await self.uploadFile(localPath: localPath, target: target, progress: progress, cancellation: cancellation)
        }
    }

    /// Uploads bytes held in memory; cancelling the calling task stops it.
    public func uploadBytes(data: Data, target: WriteTarget) async throws -> FileStat {
        try await cancellable { cancellation in
            try await self.uploadBytes(data: data, target: target, cancellation: cancellation)
        }
    }

    /// Downloads a remote file to `localPath`; cancelling the calling task stops it.
    public func downloadFile(
        remotePath: String, localPath: String, offset: UInt64, len: UInt64?, progress: TransferProgress?
    ) async throws -> FileStat {
        try await cancellable { cancellation in
            try await self.downloadFile(
                remotePath: remotePath, localPath: localPath, offset: offset, len: len,
                progress: progress, cancellation: cancellation)
        }
    }
}

private func cancellable<Result>(
    _ transfer: (TransferCancellation) async throws -> Result
) async throws -> Result {
    let cancellation = TransferCancellation()
    return try await withTaskCancellationHandler {
        do {
            return try await transfer(cancellation)
        } catch {
            if cancellation.isCancelled() { throw CancellationError() }
            throw error
        }
    } onCancel: {
        cancellation.cancel()
    }
}
