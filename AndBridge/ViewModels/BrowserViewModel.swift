import Combine
import Foundation

final class BrowserViewModel: ObservableObject {

    @Published private(set) var devices: [MTPDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var roots: [MTPFileNode] = []
    @Published private(set) var state: BrowserState = .noDevice
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingFiles = false
    @Published private(set) var activeFileOperation: String?
    @Published private(set) var activeTransferProgress: FileTransferProgress?
    @Published private(set) var isCancellingFileOperation = false
    @Published private(set) var transferErrorMessage: String?

    private let service: MTPDeviceService
    private var copiedNodes: [MTPFileNode] = []
    private var copiedDeviceID: String?
    private var activeFileOperationID: UUID?
    private var activeTransferCancellation: FileTransferCancellation?
    private var childLoadTokens: [String: UUID] = [:]

    var canCancelActiveFileOperation: Bool { activeTransferCancellation != nil }
    var selectedDevice: MTPDevice? { selectedDeviceID.flatMap { id in devices.first { $0.id == id } } }
    var canRefreshFiles: Bool {
        guard selectedDevice != nil,
            !isRefreshingFiles,
            activeFileOperation == nil
        else { return false }
        if case .loading = state { return false }
        return true
    }

    init(service: MTPDeviceService = MTPDeviceService()) {
        self.service = service
        bindService()
    }

    func start() {
        isRefreshing = true
        service.start()
    }

    func stop() {
        service.stop()
    }

    func refreshDevices() {
        isRefreshing = true
        service.refreshDevices()
    }

    func select(_ device: MTPDevice) {
        guard selectedDeviceID != device.id else { return }
        isRefreshingFiles = false
        childLoadTokens.removeAll()
        selectedDeviceID = device.id
        roots = []
        state = .loading("Opening device...")
        service.selectDevice(withID: device.id)
    }

    func refreshFiles() {
        guard let deviceID = selectedDeviceID, canRefreshFiles else { return }
        isRefreshingFiles = true
        copiedNodes = []
        copiedDeviceID = nil
        childLoadTokens.removeAll()
        state = .loading("Refreshing files...")
        service.refreshFiles(on: deviceID)
    }

    func canMove(_ sources: [MTPFileNode], into destination: MTPFileNode) -> Bool {
        let sources = topLevelNodes(in: sources)
        guard !sources.isEmpty else { return false }
        return sources.allSatisfy { canMove($0, into: destination) }
    }

    private func canMove(_ source: MTPFileNode, into destination: MTPFileNode) -> Bool {
        guard source.handle != 0,
            destination.handle != 0,
            !source.isStorageRoot,
            destination.isFolder,
            !source.isLocked,
            !destination.isLocked,
            source.id != destination.id,
            source.parentID != destination.id
        else { return false }
        return !source.containsDescendant(withID: destination.id)
    }

    func loadChildren(of node: MTPFileNode) {
        guard let deviceID = selectedDeviceID,
            node.isFolder,
            !node.childrenLoaded,
            !node.isLoadingChildren
        else { return }
        readChildren(of: node, on: deviceID, message: "Reading “\(node.name)”...")
    }

    func move(_ selectedNodes: [MTPFileNode], into destination: MTPFileNode) {
        let sources = topLevelNodes(in: selectedNodes)
        guard let deviceID = selectedDeviceID, canMove(sources, into: destination) else { return }
        let sourceParents = parentFolders(of: sources)
        let message = operationMessage("Moving", nodes: sources)
        performBatch(
            message,
            items: sources,
            on: deviceID,
            operation: { source, _, completion in
                self.service.move(item: source, into: destination, on: deviceID, completion: completion)
            },
            itemSucceeded: { [weak self] source in
                self?.applyMove(source, into: destination)
            },
            finished: { [weak self] error in
                self?.reloadFolders(sourceParents + [destination],
                                    on: deviceID,
                                    preserving: error)
            }
        )
    }

    func createFolder(named name: String, in destination: MTPFileNode) {
        guard let deviceID = selectedDeviceID,
            destination.isFolder,
            !destination.isLocked
        else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
            !trimmedName.contains("/"),
            !trimmedName.contains(":")
        else {
            state = .failed("Folder names cannot be empty or contain “/” or “:”.")
            return
        }
        perform(
            "Creating “\(trimmedName)”...",
            on: deviceID,
            showsProgress: false,
            operation: { completion in
                self.service.createFolder(named: trimmedName, in: destination, on: deviceID, completion: completion)
            },
            finished: { [weak self] error in
                self?.reloadFolders([destination], on: deviceID, preserving: error)
            }
        )
    }

    func copy(_ selectedNodes: [MTPFileNode]) {
        let nodes = topLevelNodes(in: selectedNodes)
        guard let deviceID = selectedDeviceID,
            !nodes.isEmpty,
            nodes.allSatisfy({ !$0.isStorageRoot })
        else { return }
        copiedNodes = nodes
        copiedDeviceID = deviceID
    }

    func canPaste(into destination: MTPFileNode) -> Bool {
        guard copiedDeviceID == selectedDeviceID,
            !copiedNodes.isEmpty,
            destination.isFolder,
            !destination.isLocked
        else { return false }
        return copiedNodes.allSatisfy { source in
            !source.isStorageRoot && source.id != destination.id && !source.containsDescendant(withID: destination.id)
        }
    }

    func paste(into destination: MTPFileNode) {
        guard let deviceID = selectedDeviceID,
            canPaste(into: destination)
        else { return }
        let sources = copiedNodes
        let message = operationMessage("Copying", nodes: sources)
        performBatch(
            message,
            items: sources,
            on: deviceID,
            allowsCancellation: true,
            operation: { source, cancellation, completion in
                self.service.copy(item: source,
                                  into: destination,
                                  on: deviceID,
                                  cancellation: cancellation,
                                  completion: completion)
            },
            finished: { [weak self] error in
                guard let self = self else { return }
                let reportedError = error.flatMap { self.isTransferCancellation($0) ? nil : $0 }
                self.reloadFolders([destination], on: deviceID, preserving: reportedError)
            }
        )
    }

    func delete(_ selectedNodes: [MTPFileNode]) {
        let nodes = topLevelNodes(in: selectedNodes)
        guard let deviceID = selectedDeviceID,
            !nodes.isEmpty,
            nodes.allSatisfy({ !$0.isStorageRoot && !$0.isLocked })
        else { return }
        let parents = parentFolders(of: nodes)
        let message = operationMessage("Deleting", nodes: nodes)
        performBatch(
            message,
            items: nodes,
            on: deviceID,
            operation: { node, _, completion in
                self.service.delete(item: node, on: deviceID, completion: completion)
            },
            itemSucceeded: { [weak self] node in
                guard let self = self else { return }
                self.roots.removeNode(withID: node.id)
                self.copiedNodes.removeAll { copiedNode in
                    copiedNode.id == node.id || node.containsDescendant(withID: copiedNode.id)
                }
                if self.copiedNodes.isEmpty { self.copiedDeviceID = nil }
            },
            finished: { [weak self] error in
                self?.reloadFolders(parents, on: deviceID, preserving: error)
            }
        )
    }

    func importFiles(_ urls: [URL], into destination: MTPFileNode, completion: @escaping () -> Void) {
        guard let deviceID = selectedDeviceID,
            !urls.isEmpty,
            destination.isFolder,
            !destination.isLocked
        else {
            completion()
            return
        }
        let description = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        let cancellation = FileTransferCancellation()
        let operationID = beginFileOperation("Copying \(description) to the device...",
                                             transferProgress: .preparing,
                                             cancellation: cancellation)
        state = .loading("Copying \(description) to the device...")
        service.importFiles(
            at: urls,
            into: destination,
            on: deviceID,
            cancellation: cancellation,
            progress: { [weak self] progress in
                self?.updateFileOperation(operationID, progress: progress)
            },
            completion: { [weak self] result in
                completion()
                guard let self = self else { return }
                self.endFileOperation(operationID)
                guard self.selectedDeviceID == deviceID else { return }
                switch result {
                case .success:
                    self.reloadFolders([destination], on: deviceID)
                case .failure(let error):
                    let reportedError = self.isTransferCancellation(error) ? nil : error
                    self.reloadFolders([destination], on: deviceID, preserving: reportedError)
                }
            }
        )
    }

    func export(_ node: MTPFileNode, to destinationURL: URL, completion: @escaping (Error?) -> Void) {
        guard let deviceID = selectedDeviceID, !node.isStorageRoot else {
            completion(BrowserTransferError.deviceUnavailable)
            return
        }
        let cancellation = FileTransferCancellation()
        let operationID = beginFileOperation("Copying “\(node.name)” to this Mac...",
                                             transferProgress: .preparing,
                                             cancellation: cancellation)
        service.export(
            item: node,
            to: destinationURL,
            on: deviceID,
            cancellation: cancellation,
            progress: { [weak self] progress in
                self?.updateFileOperation(operationID, progress: progress)
            },
            completion: { [weak self] result in
                self?.endFileOperation(operationID)
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    if self?.isTransferCancellation(error) == false { self?.transferErrorMessage = error.localizedDescription }
                    completion(error)
                }
            }
        )
    }

    func cancelActiveFileOperation() {
        guard let cancellation = activeTransferCancellation,
            !isCancellingFileOperation
        else { return }
        isCancellingFileOperation = true
        activeFileOperation = "Cancelling file copy..."
        cancellation.cancel()
    }

    func dismissTransferError() {
        transferErrorMessage = nil
    }

    private func bindService() {
        service.onDevicesChanged = { [weak self] devices in
            guard let self = self else { return }
            self.devices = devices
            self.isRefreshing = false

            if let selectedID = self.selectedDeviceID,
                !devices.contains(where: { $0.id == selectedID }) {
                self.clearSelection()
            }
            if self.selectedDeviceID == nil {
                self.state = .noDevice
                if devices.count == 1, let device = devices.first {
                    DispatchQueue.main.async { [weak self] in
                        guard self?.selectedDeviceID == nil else { return }
                        self?.select(device)
                    }
                }
            }
        }

        service.onLoadingChanged = { [weak self] id, message in
            guard let self = self, self.selectedDeviceID == id else { return }
            self.state = .loading(message)
        }

        service.onContentsChanged = { [weak self] id, roots in
            guard let self = self, self.selectedDeviceID == id else { return }
            self.isRefreshingFiles = false
            self.childLoadTokens.removeAll()
            self.roots = roots
            self.state = .ready
        }

        service.onError = { [weak self] id, message in
            guard let self = self else { return }
            if id == nil || self.selectedDeviceID == id {
                self.isRefreshingFiles = false
                self.state = .failed(message)
            }
        }
    }

    private func applyMove(_ source: MTPFileNode, into destination: MTPFileNode) {
        guard roots.removeNode(withID: source.id) else { return }
        source.parentID = destination.id
        source.updateStorageIDRecursively(to: destination.storageID)
        destination.children.append(source)
        destination.children.sort(by: MTPFileNode.displayOrder)
        roots = Array(roots)
    }

    private func parentFolders(of nodes: [MTPFileNode]) -> [MTPFileNode] {
        nodes.compactMap(\.parentID).compactMap { roots.node(withID: $0) }
    }

    private func reloadFolders(_ folders: [MTPFileNode],
                               on deviceID: String,
                               preserving operationError: Error? = nil) {
        var uniqueFolders: [MTPFileNode] = []
        for folder in folders where !uniqueFolders.contains(where: { $0.id == folder.id }) {
            uniqueFolders.append(folder)
        }
        reloadFolders(uniqueFolders,
                      at: 0,
                      on: deviceID,
                      preserving: operationError,
                      firstRefreshError: nil)
    }

    private func reloadFolders(_ folders: [MTPFileNode],
                               at index: Int,
                               on deviceID: String,
                               preserving operationError: Error?,
                               firstRefreshError: Error?) {
        guard selectedDeviceID == deviceID else { return }
        guard index < folders.count else {
            state = (operationError ?? firstRefreshError).map { .failed($0.localizedDescription) } ?? .ready
            return
        }
        readChildren(of: folders[index], on: deviceID, message: nil) { [weak self] refreshError in
            self?.reloadFolders(folders,
                                at: index + 1,
                                on: deviceID,
                                preserving: operationError,
                                firstRefreshError: firstRefreshError ?? refreshError)
        }
    }

    private func readChildren(of node: MTPFileNode,
                              on deviceID: String,
                              message: String?,
                              completion: ((Error?) -> Void)? = nil) {
        let loadToken = UUID()
        childLoadTokens[node.id] = loadToken
        node.isLoadingChildren = true
        if let message = message { state = .loading(message) }
        roots = Array(roots)

        service.loadChildren(
            of: node,
            on: deviceID,
            progress: { [weak self] children in
                guard let self = self,
                    self.selectedDeviceID == deviceID,
                    self.childLoadTokens[node.id] == loadToken,
                    let currentNode = self.roots.node(withID: node.id)
                else { return }
                currentNode.children = children
                self.roots = Array(self.roots)
            },
            completion: { [weak self] result in
                guard let self = self,
                    self.selectedDeviceID == deviceID,
                    self.childLoadTokens[node.id] == loadToken
                else { return }
                self.childLoadTokens.removeValue(forKey: node.id)
                guard let currentNode = self.roots.node(withID: node.id) else {
                    completion?(BrowserTransferError.deviceUnavailable)
                    return
                }
                currentNode.isLoadingChildren = false
                switch result {
                case .success(let children):
                    currentNode.children = children
                    currentNode.childrenLoaded = true
                    self.roots = Array(self.roots)
                    self.state = .ready
                    completion?(nil)
                case .failure(let error):
                    self.roots = Array(self.roots)
                    self.state = .failed(error.localizedDescription)
                    completion?(error)
                }
            }
        )
    }

    private func performBatch(_ message: String,
                              items: [MTPFileNode],
                              on deviceID: String,
                              allowsCancellation: Bool = false,
                              operation: @escaping (MTPFileNode,
                                                    FileTransferCancellation?,
                                                    @escaping (Result<Void, Error>) -> Void) -> Void,
                              itemSucceeded: @escaping (MTPFileNode) -> Void = { _ in },
                              finished: @escaping (Error?) -> Void) {
        state = .loading(message)
        let cancellation = allowsCancellation ? FileTransferCancellation() : nil
        let operationID = beginFileOperation(message, cancellation: cancellation)
        performBatchItems(items,
                          index: 0,
                          firstError: nil,
                          cancellation: cancellation,
                          operation: operation,
                          itemSucceeded: itemSucceeded) { [weak self] error in
            guard let self = self else { return }
            self.endFileOperation(operationID)
            guard self.selectedDeviceID == deviceID else { return }
            finished(error)
        }
    }

    private func performBatchItems(_ items: [MTPFileNode],
                                   index: Int,
                                   firstError: Error?,
                                   cancellation: FileTransferCancellation?,
                                   operation: @escaping (MTPFileNode,
                                                         FileTransferCancellation?,
                                                         @escaping (Result<Void, Error>) -> Void) -> Void,
                                   itemSucceeded: @escaping (MTPFileNode) -> Void,
                                   completion: @escaping (Error?) -> Void) {
        guard cancellation?.isCancelled != true else {
            completion(FileTransferError.cancelled)
            return
        }
        guard index < items.count else {
            completion(firstError)
            return
        }
        let item = items[index]
        operation(item, cancellation) { [weak self] result in
            guard let self = self else { return }
            var error = firstError
            switch result {
            case .success:
                itemSucceeded(item)
            case .failure(let operationError):
                error = error ?? operationError
            }
            self.performBatchItems(items,
                                   index: index + 1,
                                   firstError: error,
                                   cancellation: cancellation,
                                   operation: operation,
                                   itemSucceeded: itemSucceeded,
                                   completion: completion)
        }
    }

    private func topLevelNodes(in nodes: [MTPFileNode]) -> [MTPFileNode] {
        var uniqueNodes: [MTPFileNode] = []
        for node in nodes where !uniqueNodes.contains(where: { $0.id == node.id }) { uniqueNodes.append(node) }
        return uniqueNodes.filter { candidate in
            !uniqueNodes.contains { possibleAncestor in
                possibleAncestor.id != candidate.id && possibleAncestor.containsDescendant(withID: candidate.id)
            }
        }
    }

    private func operationMessage(_ verb: String, nodes: [MTPFileNode]) -> String {
        nodes.count == 1 ? "\(verb) “\(nodes[0].name)”..." : "\(verb) \(nodes.count) items..."
    }

    private func perform(_ message: String,
                         on deviceID: String,
                         showsProgress: Bool = true,
                         operation: (@escaping (Result<Void, Error>) -> Void) -> Void,
                         finished: @escaping (Error?) -> Void) {
        state = .loading(message)
        let operationID = showsProgress ? beginFileOperation(message) : nil
        operation { [weak self] result in
            guard let self = self else { return }
            if let operationID = operationID { self.endFileOperation(operationID) }
            guard self.selectedDeviceID == deviceID else { return }
            switch result {
            case .success:
                finished(nil)
            case .failure(let error):
                finished(error)
            }
        }
    }

    @discardableResult
    private func beginFileOperation(_ message: String,
                                    transferProgress: FileTransferProgress? = nil,
                                    cancellation: FileTransferCancellation? = nil) -> UUID {
        let operationID = UUID()
        activeFileOperationID = operationID
        activeFileOperation = message
        activeTransferProgress = transferProgress
        activeTransferCancellation = cancellation
        isCancellingFileOperation = false
        return operationID
    }

    private func updateFileOperation(_ operationID: UUID, progress: FileTransferProgress) {
        guard activeFileOperationID == operationID else { return }
        activeTransferProgress = progress
    }

    private func endFileOperation(_ operationID: UUID) {
        guard activeFileOperationID == operationID else { return }
        activeFileOperationID = nil
        activeFileOperation = nil
        activeTransferProgress = nil
        activeTransferCancellation = nil
        isCancellingFileOperation = false
    }

    private func isTransferCancellation(_ error: Error) -> Bool {
        error is FileTransferError
    }

    private func clearSelection() {
        isRefreshingFiles = false
        selectedDeviceID = nil
        roots = []
        copiedNodes = []
        copiedDeviceID = nil
        childLoadTokens.removeAll()
        activeFileOperationID = nil
        activeFileOperation = nil
        activeTransferProgress = nil
        activeTransferCancellation?.cancel()
        activeTransferCancellation = nil
        isCancellingFileOperation = false
    }

}

private enum BrowserTransferError: LocalizedError {
    case deviceUnavailable

    var errorDescription: String? { "The selected Android device is no longer available." }
}
