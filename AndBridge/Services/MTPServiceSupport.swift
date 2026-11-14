import Foundation
import ImageCaptureCore

struct MTPCommandResult {
    let data: Data
    let parameters: [UInt32]
}

struct PendingMTPCommand {
    let id = UUID()
    let operationCode: UInt16
    let command: Data
    let outData: Data?
    let camera: ICCameraDevice
    let cancellation: FileTransferCancellation?
    let completion: (Result<MTPCommandResult, Error>) -> Void
}

struct PendingExport {
    let item: MTPFileNode
    let destinationURL: URL
    let deviceID: String
    let cancellation: FileTransferCancellation
    let progress: (FileTransferProgress) -> Void
    let completion: (Result<Void, Error>) -> Void
}

final class TransferProgressTracker {

    private(set) var transferredBytes: UInt64 = 0
    private(set) var completedFiles = 0
    let totalBytes: UInt64
    let totalFiles: Int
    private let handler: (FileTransferProgress) -> Void

    init(totalBytes: UInt64, totalFiles: Int, handler: @escaping (FileTransferProgress) -> Void) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.handler = handler
        report()
    }

    func advance(bytes: UInt64 = 0, completesFile: Bool = false) {
        transferredBytes = min(totalBytes, transferredBytes.saturatingAdd(bytes))
        if completesFile { completedFiles = min(totalFiles, completedFiles + 1) }
        report()
    }

    private func report() {
        handler(FileTransferProgress(transferredBytes: transferredBytes,
                                     totalBytes: totalBytes,
                                     completedFiles: completedFiles,
                                     totalFiles: totalFiles))
    }

}

struct ExportPlan {
    var sizesByNodeID: [String: UInt64] = [:]
    var childrenByNodeID: [String: [MTPFileNode]] = [:]
    var totalBytes: UInt64 = 0
    var totalFiles = 0

    mutating func includeFile(_ node: MTPFileNode, size: UInt64) {
        sizesByNodeID[node.id] = size
        totalBytes = totalBytes.saturatingAdd(size)
        totalFiles += 1
    }

    mutating func merge(_ other: ExportPlan) {
        sizesByNodeID.merge(other.sizesByNodeID) { _, new in new }
        childrenByNodeID.merge(other.childrenByNodeID) { _, new in new }
        totalBytes = totalBytes.saturatingAdd(other.totalBytes)
        totalFiles += other.totalFiles
    }
}

extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

enum MTPServiceError: LocalizedError {
    case deviceUnavailable
    case moveUnsupported
    case storageRootMoveUnsupported
    case mutationUnsupported
    case invalidDestination
    case unknownFileSize(String)
    case destinationAlreadyExists(String)
    case cannotCreateDestination(String)
    case incompleteTransfer(String, expected: UInt64, actual: UInt64)
    case chunkedDownloadUnsupported(String)
    case chunkedUploadUnsupported(String)
    case commandTimedOut
    case invalidDeviceResponse
    case noStorage
    case response(UInt16, UInt16)

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "The Android device isn't available. Reconnect it and refresh."
        case .moveUnsupported:
            return "This Android device doesn't support MTP move commands."
        case .storageRootMoveUnsupported:
            return "The selected item can't be moved to that destination."
        case .mutationUnsupported:
            return "This Android device doesn't expose the MTP operations needed to change files."
        case .invalidDestination:
            return "The selected destination isn't a writable folder."
        case .unknownFileSize(let name):
            return "The Android device didn't report a reliable size for “\(name)”."
        case .destinationAlreadyExists(let name):
            return "“\(name)” conflicts with an item already in the destination. Nothing was overwritten."
        case .cannotCreateDestination(let name):
            return "Couldn't create “\(name)” in the selected destination."
        case .incompleteTransfer(let name, let expected, let actual):
            return "“\(name)” was incomplete (expected \(expected) bytes, received \(actual) bytes)."
        case .chunkedDownloadUnsupported(let name):
            return "The Android device can't safely export the large file “\(name)” in chunks."
        case .chunkedUploadUnsupported(let name):
            return "The Android device doesn't support the extended MTP operations needed to upload the large file “\(name)”."
        case .commandTimedOut:
            return "The Android device stopped responding during the file transfer. Its MTP session was reset; keep it unlocked and try again."
        case .invalidDeviceResponse:
            return "The Android device returned an invalid MTP response."
        case .noStorage:
            return "The Android device didn't report any accessible MTP storage."
        case .response(let operation, let code):
            return responseDescription(operation: operation, code: code)
        }
    }

    private func responseDescription(operation: UInt16, code: UInt16) -> String {
        guard operation == MTPOperation.moveObject else {
            switch code {
            case 0x2005: return "This Android device doesn't support the requested MTP operation."
            case 0x2008: return "The selected storage is not valid."
            case 0x2009: return "An item disappeared while its folder was being read. Refresh and try again."
            case 0x200C: return "The Android device doesn't have enough free space."
            case 0x200D: return "The selected item is write-protected."
            case 0x200E: return "The selected storage is read-only."
            case 0x200F: return "The Android device denied access to this operation."
            case 0x201A: return "The selected parent folder is not valid."
            case 0x2019: return "The Android device is busy. Keep it unlocked and try again."
            default: return String(format: "The MTP request failed (response 0x%04X).", code)
            }
        }

        switch code {
        case 0x2005: return "This Android device doesn't support moving items."
        case 0x2008: return "The destination storage is not valid."
        case 0x2009: return "The source item is no longer available."
        case 0x200D: return "The item is write-protected."
        case 0x200E: return "The destination storage is read-only."
        case 0x200F: return "The Android device denied access to move this item."
        case 0x2013: return "The destination storage is not available."
        case 0x2019: return "The Android device is busy. Try the move again."
        case 0x201A: return "The selected destination is not valid."
        default: return String(format: "The MTP move failed (response 0x%04X).", code)
        }
    }
}
