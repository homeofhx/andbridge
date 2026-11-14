import Foundation

struct FileTransferProgress: Equatable {
    let transferredBytes: UInt64
    let totalBytes: UInt64
    let completedFiles: Int
    let totalFiles: Int

    static let preparing = FileTransferProgress(
        transferredBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0
    )

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }
        if totalFiles > 0 {
            return min(1, Double(completedFiles) / Double(totalFiles))
        }

        return 0
    }
}

final class FileTransferCancellation {

    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    @discardableResult
    func registerCancellationHandler(_ handler: @escaping () -> Void) -> UUID? {
        let id = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return nil
        }
        handlers[id] = handler
        lock.unlock()
        return id
    }

    func removeCancellationHandler(_ id: UUID?) {
        guard let id = id else { return }
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

}

enum FileTransferError: LocalizedError {
    case cancelled

    var errorDescription: String? { "The file copy operation was cancelled." }
}
