import AppKit
import Darwin
import Foundation
import ImageCaptureCore

final class MTPDeviceService: NSObject {

    var onDevicesChanged: (([MTPDevice]) -> Void)?
    var onContentsChanged: ((String, [MTPFileNode]) -> Void)?
    var onLoadingChanged: ((String, String) -> Void)?
    var onError: ((String?, String) -> Void)?

    private let browser = ICDeviceBrowser()
    var camerasByID: [String: ICCameraDevice] = [:]
    var rootsByDeviceID: [String: [MTPFileNode]] = [:]
    var mtpEnumerationTokens: [String: UUID] = [:]
    var rawMTPDeviceIDs = Set<String>()
    var selectedDeviceID: String?
    var nextTransactionID: UInt32 = 1
    var pendingMTPCommands: [PendingMTPCommand] = []
    var isMTPCommandInFlight = false
    var activeMTPCommand: PendingMTPCommand?
    var activeMTPCommandCancellationHandlerID: UUID?
    var activeMTPCommandTimeout: DispatchWorkItem?
    var activeMTPCommandCompletionDelivered = false
    var recoveringMTPDeviceIDs = Set<String>()
    private var pendingExports: [PendingExport] = []
    private var isExportInProgress = false
    private let fileIOQueue = DispatchQueue(label: "hx.AndBridge.file-io", qos: .userInitiated)
    private let transferChunkSize: UInt32 = 4 * 1024 * 1024
    private let maximumBufferedTransferSize: UInt64 = 64 * 1024 * 1024

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
    }

    // MARK: - Device lifecycle and browsing

    func start() {
        guard !browser.isBrowsing else { return }
        browser.start()
    }

    func stop() {
        browser.stop()
    }

    func refreshDevices() {
        guard browser.isBrowsing else {
            browser.start()
            return
        }

        for case let camera as ICCameraDevice in browser.devices ?? [] where isAndroidMTPCandidate(camera) {
            camera.delegate = self
            camerasByID[deviceID(for: camera)] = camera
        }
        publishDevices()
    }

    func selectDevice(withID id: String) {
        guard let camera = camerasByID[id] else {
            onError?(id, "The device is no longer connected.")
            return
        }

        if let oldID = selectedDeviceID,
            oldID != id,
            let oldCamera = camerasByID[oldID],
            oldCamera.hasOpenSession {
            oldCamera.requestCloseSession()
        }

        selectedDeviceID = id
        camera.delegate = self
        onLoadingChanged?(id, "Opening \(camera.name ?? "device")...")

        if let roots = rootsByDeviceID[id] { onContentsChanged?(id, roots) }

        if !camera.hasOpenSession {
            camera.requestOpenSession()
        } else if rootsByDeviceID[id] == nil {
            beginMTPFileEnumeration(on: camera)
        }
    }

    func refreshFiles(on deviceID: String) {
        guard selectedDeviceID == deviceID,
            let camera = camerasByID[deviceID]
        else {
            onError?(deviceID, "The device is no longer connected.")
            return
        }
        guard camera.hasOpenSession else {
            onError?(deviceID, MTPServiceError.deviceUnavailable.localizedDescription)
            return
        }

        // Invalidate both a completed catalog token and any in-flight enumeration.
        // Its callbacks check the token before publishing, so an older refresh can't replace the newer file tree.
        rootsByDeviceID.removeValue(forKey: deviceID)
        mtpEnumerationTokens.removeValue(forKey: deviceID)
        beginMTPFileEnumeration(on: camera)
    }

    func loadChildren(of parent: MTPFileNode,
                      on deviceID: String,
                      cancellation: FileTransferCancellation? = nil,
                      progress: (([MTPFileNode]) -> Void)? = nil,
                      completion: @escaping (Result<[MTPFileNode], Error>) -> Void) {
        guard let camera = camerasByID[deviceID], camera.hasOpenSession else {
            completion(.failure(MTPServiceError.deviceUnavailable))
            return
        }
        guard rawMTPDeviceIDs.contains(deviceID), parent.isFolder else {
            completion(.success(parent.children))
            return
        }

        let parentHandle = parent.isStorageRoot ? UInt32.max : parent.handle
        requestObjectHandles(storageID: parent.storageID,
                             parentHandle: parentHandle,
                             on: camera,
                             cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let handles):
                self.requestObjectInfos(handles: handles,
                                        index: 0,
                                        parentID: parent.id,
                                        fallbackStorageID: parent.storageID,
                                        nodes: [],
                                        firstError: nil,
                                        on: camera,
                                        cancellation: cancellation,
                                        progress: progress,
                                        completion: completion)
            }
        }
    }

    // MARK: - File operations

    func move(item source: MTPFileNode,
              into destination: MTPFileNode,
              on deviceID: String,
              completion: @escaping (Result<Void, Error>) -> Void) {
        guard let camera = camerasByID[deviceID], camera.hasOpenSession else {
            completion(.failure(MTPServiceError.deviceUnavailable))
            return
        }
        guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        else {
            completion(.failure(MTPServiceError.moveUnsupported))
            return
        }
        guard source.handle != 0,
            !source.isStorageRoot,
            destination.isFolder,
            !destination.isLocked
        else {
            completion(.failure(MTPServiceError.storageRootMoveUnsupported))
            return
        }

        let storageID = destination.storageID
        guard storageID != 0 else {
            completion(.failure(MTPServiceError.invalidDeviceResponse))
            return
        }
        sendCommand(operationCode: MTPOperation.moveObject,
                    parameters: [source.handle, storageID, moveOrCopyParentHandle(for: destination)],
                    on: camera) { result in
            completion(result.map { _ in () })
        }
    }

    func createFolder(named name: String,
                      in destination: MTPFileNode,
                      on deviceID: String,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        guard
            let camera = writableCamera(for: deviceID, destination: destination, completion: completion)
        else {
            return
        }
        createFolderHandle(named: name, in: destination, on: camera) { result in
            completion(result.map { _ in () })
        }
    }

    func copy(item source: MTPFileNode,
              into destination: MTPFileNode,
              on deviceID: String,
              cancellation: FileTransferCancellation? = nil,
              completion: @escaping (Result<Void, Error>) -> Void) {
        guard
            let camera = writableCamera(for: deviceID, destination: destination, completion: completion)
        else {
            return
        }
        guard source.handle != 0, !source.isStorageRoot else {
            completion(.failure(MTPServiceError.invalidDeviceResponse))
            return
        }
        sendCommand(operationCode: MTPOperation.copyObject,
                    parameters: [source.handle, destination.storageID, moveOrCopyParentHandle(for: destination)],
                    on: camera,
                    cancellation: cancellation) { result in
            completion(result.map { _ in () })
        }
    }

    func delete(item: MTPFileNode, on deviceID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let camera = camerasByID[deviceID], camera.hasOpenSession else {
            completion(.failure(MTPServiceError.deviceUnavailable))
            return
        }
        guard rawMTPDeviceIDs.contains(deviceID), item.handle != 0, !item.isStorageRoot else {
            completion(.failure(MTPServiceError.mutationUnsupported))
            return
        }
        sendCommand(operationCode: MTPOperation.deleteObject, parameters: [item.handle, 0], on: camera) { result in
            completion(result.map { _ in () })
        }
    }

    func importFiles(at urls: [URL],
                     into destination: MTPFileNode,
                     on deviceID: String,
                     cancellation: FileTransferCancellation,
                     progress: @escaping (FileTransferProgress) -> Void,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard
            let camera = writableCamera(for: deviceID, destination: destination, completion: completion)
        else {
            return
        }

        let securityScopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        fileIOQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let totals = try self.localTransferTotals(for: urls, cancellation: cancellation)
                DispatchQueue.main.async {
                    guard !cancellation.isCancelled else {
                        for url in securityScopedURLs { url.stopAccessingSecurityScopedResource() }
                        completion(.failure(FileTransferError.cancelled))
                        return
                    }
                    let tracker = TransferProgressTracker(totalBytes: totals.bytes, totalFiles: totals.files, handler: progress)
                    self.uploadItems(at: urls,
                                     index: 0,
                                     into: destination,
                                     on: camera,
                                     cancellation: cancellation,
                                     progress: tracker) { result in
                        for url in securityScopedURLs { url.stopAccessingSecurityScopedResource() }
                        completion(result)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    for url in securityScopedURLs { url.stopAccessingSecurityScopedResource() }
                    completion(.failure(error))
                }
            }
        }
    }

    func export(item: MTPFileNode,
                to destinationURL: URL,
                on deviceID: String,
                cancellation: FileTransferCancellation,
                progress: @escaping (FileTransferProgress) -> Void,
                completion: @escaping (Result<Void, Error>) -> Void) {
        let request = PendingExport(item: item,
                                    destinationURL: destinationURL,
                                    deviceID: deviceID,
                                    cancellation: cancellation,
                                    progress: progress,
                                    completion: completion)

        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.enqueueExport(request) }
            return
        }
        enqueueExport(request)
    }

    // MARK: - Transfer helpers

    private func enqueueExport(_ request: PendingExport) {
        pendingExports.append(request)
        startNextExportIfNeeded()
    }

    private func startNextExportIfNeeded() {
        guard !isExportInProgress, !pendingExports.isEmpty else { return }
        let request = pendingExports.removeFirst()
        guard !request.cancellation.isCancelled else {
            request.completion(.failure(FileTransferError.cancelled))
            startNextExportIfNeeded()
            return
        }
        guard let camera = camerasByID[request.deviceID],
              camera.hasOpenSession,
              rawMTPDeviceIDs.contains(request.deviceID),
              !request.item.isStorageRoot
        else {
            request.completion(.failure(MTPServiceError.deviceUnavailable))
            startNextExportIfNeeded()
            return
        }

        isExportInProgress = true
        let hasSecurityScope = request.destinationURL.startAccessingSecurityScopedResource()
        prepareExportPlan(for: request.item,
                          deviceID: request.deviceID,
                          on: camera,
                          cancellation: request.cancellation) { [weak self] planResult in
            guard let self = self else { return }
            switch planResult {
            case .failure(let error):
                self.finishExportRequest(request, result: .failure(error), hasSecurityScope: hasSecurityScope)
            case .success(let plan):
                let tracker = TransferProgressTracker(totalBytes: plan.totalBytes, totalFiles: plan.totalFiles, handler: request.progress)
                self.exportItem(request.item,
                                to: request.destinationURL,
                                on: camera,
                                plan: plan,
                                cancellation: request.cancellation,
                                progress: tracker) { result in
                    self.finishExportRequest(request, result: result, hasSecurityScope: hasSecurityScope)
                }
            }
        }
    }

    private func finishExportRequest(_ request: PendingExport, result: Result<Void, Error>, hasSecurityScope: Bool) {
        if hasSecurityScope { request.destinationURL.stopAccessingSecurityScopedResource() }
        isExportInProgress = false
        request.completion(result)
        startNextExportIfNeeded()
    }

    private func prepareExportPlan(for item: MTPFileNode,
                                   deviceID: String,
                                   on camera: ICCameraDevice,
                                   cancellation: FileTransferCancellation,
                                   completion: @escaping (Result<ExportPlan, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        guard item.isFolder else {
            if let size = item.size, size >= 0 {
                var plan = ExportPlan()
                plan.includeFile(item, size: UInt64(size))
                completion(.success(plan))
            } else {
                requestObjectSize(handle: item.handle,
                                  on: camera,
                                  cancellation: cancellation) { result in
                    guard !cancellation.isCancelled else {
                        completion(.failure(FileTransferError.cancelled))
                        return
                    }
                    completion(
                        result.map { size in
                            var plan = ExportPlan()
                            plan.includeFile(item, size: size)
                            return plan
                        }
                    )
                }
            }
            return
        }

        loadChildren(of: item, on: deviceID, cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            guard !cancellation.isCancelled else {
                completion(.failure(FileTransferError.cancelled))
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let children):
                self.prepareExportPlans(for: children,
                                        index: 0,
                                        plan: ExportPlan(),
                                        deviceID: deviceID,
                                        on: camera,
                                        cancellation: cancellation) { result in
                    completion(result.map { childPlan in
                        var plan = childPlan
                        plan.childrenByNodeID[item.id] = children
                        return plan
                    })
                }
            }
        }
    }

    private func prepareExportPlans(for items: [MTPFileNode],
                                    index: Int,
                                    plan: ExportPlan,
                                    deviceID: String,
                                    on camera: ICCameraDevice,
                                    cancellation: FileTransferCancellation,
                                    completion: @escaping (Result<ExportPlan, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        guard index < items.count else {
            completion(.success(plan))
            return
        }
        prepareExportPlan(for: items[index], deviceID: deviceID, on: camera, cancellation: cancellation) {
            [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let itemPlan):
                var updatedPlan = plan
                updatedPlan.merge(itemPlan)
                self.prepareExportPlans(for: items,
                                        index: index + 1,
                                        plan: updatedPlan,
                                        deviceID: deviceID,
                                        on: camera,
                                        cancellation: cancellation,
                                        completion: completion)
            }
        }
    }

    private func writableCamera(for deviceID: String,
                                destination: MTPFileNode,
                                completion: @escaping (Result<Void, Error>) -> Void) -> ICCameraDevice? {
        guard let camera = camerasByID[deviceID], camera.hasOpenSession else {
            completion(.failure(MTPServiceError.deviceUnavailable))
            return nil
        }
        guard rawMTPDeviceIDs.contains(deviceID),
            camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        else {
            completion(.failure(MTPServiceError.mutationUnsupported))
            return nil
        }
        guard destination.isFolder, !destination.isLocked, destination.storageID != 0 else {
            completion(.failure(MTPServiceError.invalidDestination))
            return nil
        }
        return camera
    }

    private func parentHandle(for destination: MTPFileNode) -> UInt32 {
        destination.isStorageRoot ? UInt32.max : destination.handle
    }

    private func moveOrCopyParentHandle(for destination: MTPFileNode) -> UInt32 {
        destination.isStorageRoot ? 0 : destination.handle
    }

    private func createFolderHandle(named name: String,
                                    in destination: MTPFileNode,
                                    on camera: ICCameraDevice,
                                    cancellation: FileTransferCancellation? = nil,
                                    completion: @escaping (Result<UInt32, Error>) -> Void) {
        let parent = parentHandle(for: destination)
        let dataset = MTPCodec.objectInfoDataset(storageID: destination.storageID,
                                                 parentHandle: parent,
                                                 name: name,
                                                 isFolder: true,
                                                 size: 0,
                                                 modifiedAt: Date())
        sendCommandWithResponse(operationCode: MTPOperation.sendObjectInfo,
                                parameters: [destination.storageID, parent],
                                outData: dataset,
                                on: camera,
                                cancellation: cancellation) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let handle = self.objectHandle(from: response) else {
                    completion(.failure(MTPServiceError.invalidDeviceResponse))
                    return
                }
                completion(.success(handle))
            }
        }
    }

    private func objectHandle(from response: MTPCommandResult) -> UInt32? {
        guard let handle = response.parameters.last, handle != 0, handle != UInt32.max else { return nil }
        return handle
    }

    private func localTransferTotals(for urls: [URL],
                                     cancellation: FileTransferCancellation) throws -> (bytes: UInt64, files: Int) {
        var totalBytes: UInt64 = 0
        var totalFiles = 0
        for url in urls {
            guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
            let totals = try localTransferTotals(at: url, cancellation: cancellation)
            totalBytes = totalBytes.saturatingAdd(totals.bytes)
            totalFiles += totals.files
        }
        return (totalBytes, totalFiles)
    }

    private func localTransferTotals(at url: URL,
                                     cancellation: FileTransferCancellation) throws -> (bytes: UInt64, files: Int) {
        guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory == true else { return (UInt64(max(0, values.fileSize ?? 0)), 1) }

        var totalBytes: UInt64 = 0
        var totalFiles = 0
        let children = try FileManager.default.contentsOfDirectory(at: url,
                                                                   includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                                   options: [])
        for child in children {
            guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
            let totals = try localTransferTotals(at: child, cancellation: cancellation)
            totalBytes = totalBytes.saturatingAdd(totals.bytes)
            totalFiles += totals.files
        }

        return (totalBytes, totalFiles)
    }

    private func uploadItems(at urls: [URL],
                             index: Int,
                             into destination: MTPFileNode,
                             on camera: ICCameraDevice,
                             cancellation: FileTransferCancellation,
                             progress: TransferProgressTracker,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        guard index < urls.count else {
            completion(.success(()))
            return
        }
        uploadItem(at: urls[index],
                   into: destination,
                   on: camera,
                   cancellation: cancellation,
                   progress: progress) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                completion(result)
            case .success:
                self.uploadItems(at: urls,
                                 index: index + 1,
                                 into: destination,
                                 on: camera,
                                 cancellation: cancellation,
                                 progress: progress,
                                 completion: completion)
            }
        }
    }

    private func uploadItem(at url: URL,
                            into destination: MTPFileNode,
                            on camera: ICCameraDevice,
                            cancellation: FileTransferCancellation,
                            progress: TransferProgressTracker,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        fileIOQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,])
                let isDirectory = values.isDirectory == true
                let size = UInt64(values.fileSize ?? 0)
                let data = !isDirectory && size <= self.maximumBufferedTransferSize
                        ? try Data(contentsOf: url, options: .mappedIfSafe) : nil
                DispatchQueue.main.async {
                    guard !cancellation.isCancelled else {
                        completion(.failure(FileTransferError.cancelled))
                        return
                    }
                    if isDirectory {
                        self.uploadFolder(at: url,
                                          named: url.lastPathComponent,
                                          modifiedAt: values.contentModificationDate,
                                          into: destination,
                                          on: camera,
                                          cancellation: cancellation,
                                          progress: progress,
                                          completion: completion)
                    } else if let data = data {
                        self.uploadBufferedFile(data,
                                                named: url.lastPathComponent,
                                                modifiedAt: values.contentModificationDate,
                                                into: destination,
                                                on: camera,
                                                cancellation: cancellation,
                                                progress: progress,
                                                completion: completion)
                    } else {
                        self.uploadLargeFile(at: url,
                                             size: size,
                                             modifiedAt: values.contentModificationDate,
                                             into: destination,
                                             on: camera,
                                             cancellation: cancellation,
                                             progress: progress,
                                             completion: completion)
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func uploadFolder(at url: URL,
                              named name: String,
                              modifiedAt: Date?,
                              into destination: MTPFileNode,
                              on camera: ICCameraDevice,
                              cancellation: FileTransferCancellation,
                              progress: TransferProgressTracker,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        createFolderHandle(named: name,
                           in: destination,
                           on: camera,
                           cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let handle):
                guard !cancellation.isCancelled else {
                    self.deleteRemoteObject(handle, on: camera) { completion(.failure(FileTransferError.cancelled)) }
                    return
                }
                self.fileIOQueue.async {
                    do {
                        guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                        let children = try FileManager.default
                            .contentsOfDirectory(at: url,
                                                 includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,],
                                                 options: [])
                        let remoteFolder = MTPFileNode(id: "upload:\(handle)",
                                                       handle: handle,
                                                       storageID: destination.storageID,
                                                       name: name,
                                                       isFolder: true,
                                                       size: nil,
                                                       modifiedAt: modifiedAt,
                                                       isLocked: false,
                                                       parentID: destination.id,
                                                       childrenLoaded: false)
                        DispatchQueue.main.async {
                            self.uploadItems(at: children,
                                             index: 0,
                                             into: remoteFolder,
                                             on: camera,
                                             cancellation: cancellation,
                                             progress: progress,
                                             completion: { childResult in
                                    switch childResult {
                                    case .success:
                                        completion(.success(()))
                                    case .failure(let error):
                                        self.deleteRemoteObject(handle, on: camera) { completion(.failure(error)) }
                                    }
                                }
                            )
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.deleteRemoteObject(handle, on: camera) { completion(.failure(error)) }
                        }
                    }
                }
            }
        }
    }

    private func uploadBufferedFile(_ data: Data,
                                    named name: String,
                                    modifiedAt: Date?,
                                    into destination: MTPFileNode,
                                    on camera: ICCameraDevice,
                                    cancellation: FileTransferCancellation,
                                    progress: TransferProgressTracker,
                                    completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        let parent = parentHandle(for: destination)
        let dataset = MTPCodec.objectInfoDataset(storageID: destination.storageID,
                                                 parentHandle: parent,
                                                 name: name,
                                                 isFolder: false,
                                                 size: UInt64(data.count),
                                                 modifiedAt: modifiedAt)
        sendCommandWithResponse(operationCode: MTPOperation.sendObjectInfo,
                                parameters: [destination.storageID, parent],
                                outData: dataset,
                                on: camera,
                                cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let handle = self.objectHandle(from: response) else {
                    completion(.failure(MTPServiceError.invalidDeviceResponse))
                    return
                }
                guard !cancellation.isCancelled else {
                    self.deleteRemoteObject(handle, on: camera) {
                        completion(.failure(FileTransferError.cancelled))
                    }
                    return
                }
                self.sendCommandWithResponse(operationCode: MTPOperation.sendObject,
                                             parameters: [],
                                             outData: data,
                                             on: camera,
                                             cancellation: cancellation) { result in
                    switch result {
                    case .success:
                        if cancellation.isCancelled {
                            self.deleteRemoteObject(handle, on: camera) { completion(.failure(FileTransferError.cancelled)) }
                        } else {
                            progress.advance(bytes: UInt64(data.count), completesFile: true)
                            completion(.success(()))
                        }
                    case .failure(let error):
                        if self.isTransferInterruption(error) {
                            completion(.failure(error))
                            self.deleteRemoteObject(handle, on: camera, completion: {})
                        } else {
                            self.deleteRemoteObject(handle, on: camera) { completion(.failure(error)) }
                        }
                    }
                }
            }
        }
    }

    private func uploadLargeFile(at url: URL,
                                 size: UInt64,
                                 modifiedAt: Date?,
                                 into destination: MTPFileNode,
                                 on camera: ICCameraDevice,
                                 cancellation: FileTransferCancellation,
                                 progress: TransferProgressTracker,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        fileIOQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                let localHandle = try FileHandle(forReadingFrom: url)
                DispatchQueue.main.async {
                    guard !cancellation.isCancelled else {
                        self.close(localHandle) { completion(.failure(FileTransferError.cancelled)) }
                        return
                    }
                    self.createEmptyFileHandle(named: url.lastPathComponent,
                                               modifiedAt: modifiedAt,
                                               in: destination,
                                               on: camera,
                                               cancellation: cancellation) { result in
                        switch result {
                        case .failure(let error):
                            self.close(localHandle) { completion(.failure(error)) }
                        case .success(let remoteHandle):
                            guard !cancellation.isCancelled else {
                                self.close(localHandle) {
                                    self.deleteRemoteObject(remoteHandle, on: camera) {
                                        completion(.failure(FileTransferError.cancelled))
                                    }
                                }
                                return
                            }
                            self.beginLargeUpload(localHandle: localHandle,
                                                  remoteHandle: remoteHandle,
                                                  name: url.lastPathComponent,
                                                  size: size,
                                                  on: camera,
                                                  cancellation: cancellation,
                                                  progress: progress,
                                                  completion: completion)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func createEmptyFileHandle(named name: String,
                                       modifiedAt: Date?,
                                       in destination: MTPFileNode,
                                       on camera: ICCameraDevice,
                                       cancellation: FileTransferCancellation,
                                       completion: @escaping (Result<UInt32, Error>) -> Void) {
        let parent = parentHandle(for: destination)
        let dataset = MTPCodec.objectInfoDataset(storageID: destination.storageID,
                                                 parentHandle: parent,
                                                 name: name,
                                                 isFolder: false,
                                                 size: 0,
                                                 modifiedAt: modifiedAt)
        sendCommandWithResponse(operationCode: MTPOperation.sendObjectInfo,
                                parameters: [destination.storageID, parent],
                                outData: dataset,
                                on: camera,
                                cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let handle = self.objectHandle(from: response) else {
                    completion(.failure(MTPServiceError.invalidDeviceResponse))
                    return
                }
                self.sendCommandWithResponse(
                    operationCode: MTPOperation.sendObject,
                    parameters: [],
                    outData: Data(),
                    on: camera,
                    cancellation: cancellation
                ) { sendResult in
                    switch sendResult {
                    case .success:
                        completion(.success(handle))
                    case .failure(let error):
                        if self.isTransferInterruption(error) {
                            completion(.failure(error))
                            self.deleteRemoteObject(handle, on: camera, completion: {})
                        } else {
                            self.deleteRemoteObject(handle, on: camera) { completion(.failure(error)) }
                        }
                    }
                }
            }
        }
    }

    private func beginLargeUpload(localHandle: FileHandle,
                                  remoteHandle: UInt32,
                                  name: String,
                                  size: UInt64,
                                  on camera: ICCameraDevice,
                                  cancellation: FileTransferCancellation,
                                  progress: TransferProgressTracker,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            failLargeUpload(localHandle: localHandle,
                            remoteHandle: remoteHandle,
                            editStarted: false,
                            error: FileTransferError.cancelled,
                            on: camera,
                            completion: completion)
            return
        }
        sendCommand(operationCode: MTPOperation.beginEditObject,
                    parameters: [remoteHandle],
                    on: camera,
                    cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                guard !cancellation.isCancelled else {
                    self.failLargeUpload(localHandle: localHandle,
                                         remoteHandle: remoteHandle,
                                         editStarted: true,
                                         error: FileTransferError.cancelled,
                                         on: camera,
                                         completion: completion)
                    return
                }
                self.uploadLargeFileChunks(localHandle: localHandle,
                                           remoteHandle: remoteHandle,
                                           name: name,
                                           offset: 0,
                                           expectedSize: size,
                                           on: camera,
                                           cancellation: cancellation,
                                           progress: progress,
                                           completion: completion)
            case .failure(let error):
                self.failLargeUpload(localHandle: localHandle,
                                     remoteHandle: remoteHandle,
                                     editStarted: false,
                                     error: self.largeUploadError(error, name: name),
                                     on: camera,
                                     completion: completion)
            }
        }
    }

    private func uploadLargeFileChunks(localHandle: FileHandle,
                                       remoteHandle: UInt32,
                                       name: String,
                                       offset: UInt64,
                                       expectedSize: UInt64,
                                       on camera: ICCameraDevice,
                                       cancellation: FileTransferCancellation,
                                       progress: TransferProgressTracker,
                                       completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            failLargeUpload(localHandle: localHandle,
                            remoteHandle: remoteHandle,
                            editStarted: true,
                            error: FileTransferError.cancelled,
                            on: camera,
                            completion: completion)
            return
        }
        guard offset < expectedSize else {
            finishLargeUpload(localHandle: localHandle,
                              remoteHandle: remoteHandle,
                              name: name,
                              expectedSize: expectedSize,
                              on: camera,
                              cancellation: cancellation,
                              progress: progress,
                              completion: completion)
            return
        }

        let requestedCount = Int(min(UInt64(transferChunkSize), expectedSize - offset))
        fileIOQueue.async { [weak self] in
            guard let self = self else { return }
            let data = localHandle.readData(ofLength: requestedCount)
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else {
                    self.failLargeUpload(localHandle: localHandle,
                                         remoteHandle: remoteHandle,
                                         editStarted: true,
                                         error: FileTransferError.cancelled,
                                         on: camera,
                                         completion: completion)
                    return
                }
                guard data.count == requestedCount else {
                    self.failLargeUpload(localHandle: localHandle,
                                         remoteHandle: remoteHandle,
                                         editStarted: true,
                                         error: MTPServiceError.incompleteTransfer(name,
                                                                                   expected: expectedSize,
                                                                                   actual: offset + UInt64(data.count)),
                                         on: camera,
                                         completion: completion)
                    return
                }
                self.sendCommandWithResponse(operationCode: MTPOperation.sendPartialObject,
                                             parameters: [remoteHandle,
                                                          UInt32(truncatingIfNeeded: offset),
                                                          UInt32(truncatingIfNeeded: offset >> 32),
                                                          UInt32(data.count),],
                                             outData: data,
                                             on: camera,
                                             cancellation: cancellation) { result in
                    switch result {
                    case .failure(let error):
                        self.failLargeUpload(localHandle: localHandle,
                                             remoteHandle: remoteHandle,
                                             editStarted: true,
                                             error: self.largeUploadError(error, name: name),
                                             on: camera,
                                             completion: completion)
                    case .success:
                        guard !cancellation.isCancelled else {
                            self.failLargeUpload(localHandle: localHandle,
                                                 remoteHandle: remoteHandle,
                                                 editStarted: true,
                                                 error: FileTransferError.cancelled,
                                                 on: camera,
                                                 completion: completion)
                            return
                        }
                        progress.advance(bytes: UInt64(data.count))
                        self.uploadLargeFileChunks(localHandle: localHandle,
                                                   remoteHandle: remoteHandle,
                                                   name: name,
                                                   offset: offset + UInt64(data.count),
                                                   expectedSize: expectedSize,
                                                   on: camera,
                                                   cancellation: cancellation,
                                                   progress: progress,
                                                   completion: completion)
                    }
                }
            }
        }
    }

    private func finishLargeUpload(localHandle: FileHandle,
                                   remoteHandle: UInt32,
                                   name: String,
                                   expectedSize: UInt64,
                                   on camera: ICCameraDevice,
                                   cancellation: FileTransferCancellation,
                                   progress: TransferProgressTracker,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            failLargeUpload(localHandle: localHandle,
                            remoteHandle: remoteHandle,
                            editStarted: true,
                            error: FileTransferError.cancelled,
                            on: camera,
                            completion: completion)
            return
        }
        sendCommand(operationCode: MTPOperation.truncateObject,
                    parameters: [remoteHandle, UInt32(truncatingIfNeeded: expectedSize), UInt32(truncatingIfNeeded: expectedSize >> 32),],
                    on: camera,
                    cancellation: cancellation) { [weak self] truncateResult in
            guard let self = self else { return }
            guard !cancellation.isCancelled else {
                self.failLargeUpload(localHandle: localHandle,
                                     remoteHandle: remoteHandle,
                                     editStarted: true,
                                     error: FileTransferError.cancelled,
                                     on: camera,
                                     completion: completion)
                return
            }
            switch truncateResult {
            case .failure(let error):
                self.failLargeUpload(localHandle: localHandle,
                                     remoteHandle: remoteHandle,
                                     editStarted: true,
                                     error: self.largeUploadError(error, name: name),
                                     on: camera,
                                     completion: completion)
            case .success:
                self.sendCommand(operationCode: MTPOperation.endEditObject,
                                 parameters: [remoteHandle],
                                 on: camera,
                                 cancellation: cancellation) { endResult in
                    switch endResult {
                    case .success:
                        self.close(localHandle) {
                            if cancellation.isCancelled {
                                self.deleteRemoteObject(remoteHandle, on: camera) {
                                    completion(.failure(FileTransferError.cancelled))
                                }
                            } else {
                                progress.advance(completesFile: true)
                                completion(.success(()))
                            }
                        }
                    case .failure(let error):
                        self.failLargeUpload(localHandle: localHandle,
                                             remoteHandle: remoteHandle,
                                             editStarted: true,
                                             error: self.largeUploadError(error, name: name),
                                             on: camera,
                                             completion: completion)
                    }
                }
            }
        }
    }

    private func failLargeUpload(localHandle: FileHandle,
                                 remoteHandle: UInt32,
                                 editStarted: Bool,
                                 error: Error,
                                 on camera: ICCameraDevice,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        close(localHandle) { [weak self] in
            guard let self = self else { return }
            let delete = { self.deleteRemoteObject(remoteHandle, on: camera) { completion(.failure(error)) } }
            if self.isTransferInterruption(error) {
                completion(.failure(error))
                let bestEffortDelete = { self.deleteRemoteObject(remoteHandle, on: camera, completion: {}) }
                if editStarted {
                    self.sendCommand(operationCode: MTPOperation.endEditObject,
                                     parameters: [remoteHandle],
                                     on: camera) { _ in bestEffortDelete() }
                } else {
                    bestEffortDelete()
                }
                return
            }
            guard editStarted else {
                delete()
                return
            }
            self.sendCommand(operationCode: MTPOperation.endEditObject, parameters: [remoteHandle], on: camera) { _ in delete() }
        }
    }

    private func deleteRemoteObject(_ handle: UInt32, on camera: ICCameraDevice, completion: @escaping () -> Void) {
        sendCommand(operationCode: MTPOperation.deleteObject, parameters: [handle, 0], on: camera) { _ in completion() }
    }

    private func close(_ handle: FileHandle, completion: @escaping () -> Void) {
        fileIOQueue.async {
            handle.closeFile()
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func exportItem(_ item: MTPFileNode,
                            to destinationURL: URL,
                            on camera: ICCameraDevice,
                            plan: ExportPlan,
                            cancellation: FileTransferCancellation,
                            progress: TransferProgressTracker,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        if item.isFolder {
            exportFolder(item,
                         to: destinationURL,
                         on: camera,
                         plan: plan,
                         cancellation: cancellation,
                         progress: progress,
                         completion: completion)
            return
        }

        guard let expectedSize = plan.sizesByNodeID[item.id] else {
            completion(.failure(MTPServiceError.unknownFileSize(item.name)))
            return
        }
        exportFile(item,
                   expectedSize: expectedSize,
                   to: destinationURL,
                   on: camera,
                   cancellation: cancellation,
                   progress: progress,
                   completion: completion)
    }

    private func exportFolder(_ item: MTPFileNode,
                              to destinationURL: URL,
                              on camera: ICCameraDevice,
                              plan: ExportPlan,
                              cancellation: FileTransferCancellation,
                              progress: TransferProgressTracker,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        fileIOQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw MTPServiceError.destinationAlreadyExists(destinationURL.lastPathComponent)
                }
                try FileManager.default.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
                DispatchQueue.main.async {
                    guard !cancellation.isCancelled else {
                        self.removeIncompleteExport(at: destinationURL, error: FileTransferError.cancelled, completion: completion)
                        return
                    }
                    let children = plan.childrenByNodeID[item.id] ?? []
                    self.exportChildren(children,
                                        index: 0,
                                        to: destinationURL,
                                        on: camera,
                                        plan: plan,
                                        cancellation: cancellation,
                                        progress: progress) { result in
                        switch result {
                        case .success:
                            completion(.success(()))
                        case .failure(let error):
                            self.removeIncompleteExport(at: destinationURL, error: error, completion: completion)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func exportFile(_ item: MTPFileNode,
                            expectedSize: UInt64,
                            to destinationURL: URL,
                            on camera: ICCameraDevice,
                            cancellation: FileTransferCancellation,
                            progress: TransferProgressTracker,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        startFileExport(item,
                        expectedSize: expectedSize,
                        to: destinationURL,
                        on: camera,
                        cancellation: cancellation,
                        progress: progress,
                        completion: completion)
    }

    private func startFileExport(_ item: MTPFileNode,
                                 expectedSize: UInt64,
                                 to destinationURL: URL,
                                 on camera: ICCameraDevice,
                                 cancellation: FileTransferCancellation,
                                 progress: TransferProgressTracker,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        fileIOQueue.async { [weak self] in
            guard let self = self else { return }
            let fileManager = FileManager.default
            // A file-promise URL grants access to the promised item, not to arbitrary sibling files in its parent
            // directory. Keep incomplete data in sandbox and install it at the promised URL only after verification.
            let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent("AndBridge-\(UUID().uuidString).partial")

            do {
                guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    throw MTPServiceError.destinationAlreadyExists(destinationURL.lastPathComponent)
                }
                try Data().write(to: temporaryURL, options: .withoutOverwriting)
                let handle = try FileHandle(forWritingTo: temporaryURL)
                DispatchQueue.main.async {
                    if expectedSize == 0 {
                        self.finishFileExport(handle: handle,
                                              temporaryURL: temporaryURL,
                                              destinationURL: destinationURL,
                                              expectedSize: expectedSize,
                                              modifiedAt: item.modifiedAt,
                                              cancellation: cancellation,
                                              progress: progress,
                                              completion: completion)
                    } else {
                        self.downloadFileChunks(item,
                                                offset: 0,
                                                expectedSize: expectedSize,
                                                handle: handle,
                                                temporaryURL: temporaryURL,
                                                destinationURL: destinationURL,
                                                on: camera,
                                                cancellation: cancellation,
                                                progress: progress,
                                                completion: completion)
                    }
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func downloadFileChunks(_ item: MTPFileNode,
                                    offset: UInt64,
                                    expectedSize: UInt64,
                                    handle: FileHandle,
                                    temporaryURL: URL,
                                    destinationURL: URL,
                                    on camera: ICCameraDevice,
                                    cancellation: FileTransferCancellation,
                                    progress: TransferProgressTracker,
                                    completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            failFileExport(handle: handle, temporaryURL: temporaryURL, error: FileTransferError.cancelled, completion: completion)
            return
        }
        guard offset < expectedSize else {
            finishFileExport(handle: handle,
                             temporaryURL: temporaryURL,
                             destinationURL: destinationURL,
                             expectedSize: expectedSize,
                             modifiedAt: item.modifiedAt,
                             cancellation: cancellation,
                             progress: progress,
                             completion: completion)
            return
        }

        let uses64BitOffsets = expectedSize > UInt64(UInt32.max)
        let requestedCount = UInt32(min(UInt64(transferChunkSize), expectedSize - offset))
        requestPartialObject(handle: item.handle,
                             offset: offset,
                             count: requestedCount,
                             uses64BitOffsets: uses64BitOffsets,
                             on: camera,
                             cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            guard !cancellation.isCancelled else {
                self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: FileTransferError.cancelled, completion: completion)
                return
            }
            switch result {
            case .failure(let error):
                if offset == 0, self.isUnsupportedPartialObjectError(error),
                    expectedSize <= self.maximumBufferedTransferSize {
                    self.downloadWholeFile(item,
                                           expectedSize: expectedSize,
                                           handle: handle,
                                           temporaryURL: temporaryURL,
                                           destinationURL: destinationURL,
                                           on: camera,
                                           cancellation: cancellation,
                                           progress: progress,
                                           completion: completion)
                } else {
                    let reportedError = offset == 0 && self.isUnsupportedPartialObjectError(error)
                            ? MTPServiceError.chunkedDownloadUnsupported(item.name) : error
                    self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: reportedError, completion: completion)
                }
            case .success(let response):
                guard !cancellation.isCancelled else {
                    self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: FileTransferError.cancelled, completion: completion)
                    return
                }
                let receivedCount = UInt64(response.data.count)
                let remaining = expectedSize - offset
                guard receivedCount > 0,
                    receivedCount <= UInt64(requestedCount),
                    receivedCount <= remaining,
                    response.parameters.first.map({ UInt64($0) == receivedCount }) ?? true
                else {
                    self.failFileExport(handle: handle,
                                        temporaryURL: temporaryURL,
                                        error: MTPServiceError.incompleteTransfer(item.name,
                                                                                  expected: expectedSize,
                                                                                  actual: offset + receivedCount),
                                        completion: completion)
                    return
                }
                self.fileIOQueue.async {
                    do {
                        guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                        try self.write(response.data, to: handle)
                        DispatchQueue.main.async {
                            progress.advance(bytes: receivedCount)
                            self.downloadFileChunks(item,
                                                    offset: offset + receivedCount,
                                                    expectedSize: expectedSize,
                                                    handle: handle,
                                                    temporaryURL: temporaryURL,
                                                    destinationURL: destinationURL,
                                                    on: camera,
                                                    cancellation: cancellation,
                                                    progress: progress,
                                                    completion: completion)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: error, completion: completion)
                        }
                    }
                }
            }
        }
    }

    private func downloadWholeFile(_ item: MTPFileNode,
                                   expectedSize: UInt64,
                                   handle: FileHandle,
                                   temporaryURL: URL,
                                   destinationURL: URL,
                                   on camera: ICCameraDevice,
                                   cancellation: FileTransferCancellation,
                                   progress: TransferProgressTracker,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            failFileExport(handle: handle, temporaryURL: temporaryURL, error: FileTransferError.cancelled, completion: completion)
            return
        }
        sendCommand(operationCode: MTPOperation.getObject,
                    parameters: [item.handle],
                    on: camera,
                    cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            guard !cancellation.isCancelled else {
                self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: FileTransferError.cancelled, completion: completion)
                return
            }
            switch result {
            case .failure(let error):
                self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: error, completion: completion)
            case .success(let data):
                guard !cancellation.isCancelled else {
                    self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: FileTransferError.cancelled, completion: completion)
                    return
                }
                guard UInt64(data.count) == expectedSize else {
                    self.failFileExport(handle: handle,
                                        temporaryURL: temporaryURL,
                                        error: MTPServiceError.incompleteTransfer(item.name,
                                                                                  expected: expectedSize,
                                                                                  actual: UInt64(data.count)),
                                        completion: completion)
                    return
                }
                self.fileIOQueue.async {
                    do {
                        guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                        try self.write(data, to: handle)
                        DispatchQueue.main.async {
                            progress.advance(bytes: UInt64(data.count))
                            self.finishFileExport(handle: handle,
                                                  temporaryURL: temporaryURL,
                                                  destinationURL: destinationURL,
                                                  expectedSize: expectedSize,
                                                  modifiedAt: item.modifiedAt,
                                                  cancellation: cancellation,
                                                  progress: progress,
                                                  completion: completion)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.failFileExport(handle: handle, temporaryURL: temporaryURL, error: error, completion: completion)
                        }
                    }
                }
            }
        }
    }

    private func requestPartialObject(handle: UInt32,
                                      offset: UInt64,
                                      count: UInt32,
                                      uses64BitOffsets: Bool,
                                      on camera: ICCameraDevice,
                                      cancellation: FileTransferCancellation,
                                      retriesRemaining: Int = 2,
                                      completion: @escaping (Result<MTPCommandResult, Error>) -> Void) {
        let operation = uses64BitOffsets ? MTPOperation.getPartialObject64 : MTPOperation.getPartialObject
        let parameters = uses64BitOffsets ? [handle, UInt32(truncatingIfNeeded: offset),
                                             UInt32(truncatingIfNeeded: offset >> 32), count,] : [handle, UInt32(offset), count]
        sendCommandWithResponse(operationCode: operation,
                                parameters: parameters,
                                outData: nil,
                                on: camera,
                                cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result,
                retriesRemaining > 0,
                !cancellation.isCancelled,
                self.isDeviceBusyError(error) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.requestPartialObject(handle: handle,
                                              offset: offset,
                                              count: count,
                                              uses64BitOffsets: uses64BitOffsets,
                                              on: camera,
                                              cancellation: cancellation,
                                              retriesRemaining: retriesRemaining - 1,
                                              completion: completion)
                }
                return
            }
            completion(result)
        }
    }

    private func finishFileExport(handle: FileHandle,
                                  temporaryURL: URL,
                                  destinationURL: URL,
                                  expectedSize: UInt64,
                                  modifiedAt: Date?,
                                  cancellation: FileTransferCancellation,
                                  progress: TransferProgressTracker,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        fileIOQueue.async {
            do {
                handle.closeFile()
                guard !cancellation.isCancelled else { throw FileTransferError.cancelled }
                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let actualSize = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
                guard actualSize == expectedSize else {
                    throw MTPServiceError.incompleteTransfer(destinationURL.lastPathComponent,
                                                             expected: expectedSize,
                                                             actual: actualSize)
                }
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw MTPServiceError.destinationAlreadyExists(destinationURL.lastPathComponent)
                }
                guard !cancellation.isCancelled else { throw FileTransferError.cancelled }

                // AppKit coordinates the URL supplied to an NSFilePromiseProvider. Coordinating that same URL again
                // can deadlock Finder while it waits for the promise completion handler.
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                if let modifiedAt = modifiedAt {
                    try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
                }
                DispatchQueue.main.async {
                    progress.advance(completesFile: true)
                    completion(.success(()))
                }
            } catch {
                handle.closeFile()
                try? FileManager.default.removeItem(at: temporaryURL)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func failFileExport(handle: FileHandle, temporaryURL: URL, error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        fileIOQueue.async {
            handle.closeFile()
            try? FileManager.default.removeItem(at: temporaryURL)
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    handle.fileDescriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard result > 0 else {
                    let errorCode = result == 0 ? EIO : errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
                }
                written += result
            }
        }
    }

    private func removeIncompleteExport(at url: URL, error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        fileIOQueue.async {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private func isUnsupportedPartialObjectError(_ error: Error) -> Bool {
        guard case MTPServiceError.response(let operation, let code) = error else { return false }
        return code == 0x2005 && (operation == MTPOperation.getPartialObject || operation == MTPOperation.getPartialObject64)
    }

    private func isUnsupportedOperationError(_ error: Error) -> Bool {
        guard case MTPServiceError.response(_, let code) = error else { return false }
        return code == 0x2005
    }

    private func isTransferInterruption(_ error: Error) -> Bool {
        if error is FileTransferError { return true }
        guard let serviceError = error as? MTPServiceError else { return false }
        switch serviceError {
        case .commandTimedOut, .deviceUnavailable:
            return true
        default:
            return false
        }
    }

    private func largeUploadError(_ error: Error, name: String) -> Error {
        isUnsupportedOperationError(error) ? MTPServiceError.chunkedUploadUnsupported(name) : error
    }

    func isDeviceBusyError(_ error: Error) -> Bool {
        guard case MTPServiceError.response(_, let code) = error else { return false }
        return code == 0x2019
    }

    private func exportChildren(_ children: [MTPFileNode],
                                index: Int,
                                to destinationDirectory: URL,
                                on camera: ICCameraDevice,
                                plan: ExportPlan,
                                cancellation: FileTransferCancellation,
                                progress: TransferProgressTracker,
                                completion: @escaping (Result<Void, Error>) -> Void) {
        guard !cancellation.isCancelled else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        guard index < children.count else {
            completion(.success(()))
            return
        }
        let child = children[index]
        exportItem(child,
                   to: destinationDirectory.appendingPathComponent(child.name),
                   on: camera,
                   plan: plan,
                   cancellation: cancellation,
                   progress: progress) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                completion(result)
            case .success:
                self.exportChildren(children,
                                    index: index + 1,
                                    to: destinationDirectory,
                                    on: camera,
                                    plan: plan,
                                    cancellation: cancellation,
                                    progress: progress,
                                    completion: completion)
            }
        }
    }

    // MARK: - Image Capture discovery and fallback catalog

    func deviceID(for device: ICDevice) -> String {
        if let uuid = device.uuidString, !uuid.isEmpty { return uuid }
        return "usb-\(device.usbVendorID)-\(device.usbProductID)-\(device.usbLocationID)"
    }

    func isAndroidMTPCandidate(_ camera: ICCameraDevice) -> Bool {
        guard camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue else { return false }
        return camera.usbVendorID != 0x05ac
    }

    func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func publishDevices() {
        let devices = camerasByID.map { id, camera in
            MTPDevice(id: id, name: camera.name ?? "Android device", icon: image(for: camera))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onDevicesChanged?(devices)
    }

    private func image(for _: ICCameraDevice) -> NSImage {
        SystemIcons.phone
    }

    func publishCameraContents(for camera: ICCameraDevice) {
        let id = deviceID(for: camera)
        guard selectedDeviceID == id else { return }
        let nodes = (camera.contents ?? []).map { makeNode(from: $0, deviceID: id, path: "", parentID: nil) }
            .sorted(by: MTPFileNode.displayOrder)
        rootsByDeviceID[id] = nodes
        onContentsChanged?(id, nodes)
    }

    private func makeNode(from item: ICCameraItem, deviceID: String, path: String, parentID: String?) -> MTPFileNode {
        let name = item.name ?? "Untitled"
        let itemPath = path + "/" + name
        let handle = item.ptpObjectHandle
        let id = "\(deviceID):\(handle):\(itemPath)"
        let folder = item as? ICCameraFolder
        let file = item as? ICCameraFile
        let node = MTPFileNode(id: id,
                               handle: handle,
                               storageID: 0,
                               name: name,
                               isFolder: folder != nil,
                               size: file.map { Int64($0.fileSize) },
                               modifiedAt: item.modificationDate,
                               isLocked: item.isLocked,
                               parentID: parentID)
        node.children = (folder?.contents ?? []).map { makeNode(from: $0, deviceID: deviceID, path: itemPath, parentID: id) }
            .sorted(by: MTPFileNode.displayOrder)
        return node
    }

}
