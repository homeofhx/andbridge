import Foundation
import ImageCaptureCore

// Raw MTP catalog
extension MTPDeviceService {
    func beginMTPFileEnumeration(on camera: ICCameraDevice) {
        let id = deviceID(for: camera)
        guard selectedDeviceID == id,
            mtpEnumerationTokens[id] == nil
        else { return }
        guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        else {
            publishCameraContents(for: camera)
            return
        }

        let token = UUID()
        mtpEnumerationTokens[id] = token
        rawMTPDeviceIDs.insert(id)
        onLoadingChanged?(id, "Reading Android device's storage...")

        sendCommand(operationCode: MTPOperation.getStorageIDs,
                    parameters: [],
                    on: camera) { [weak self] result in
            guard let self = self,
                self.mtpEnumerationTokens[id] == token
            else { return }
            switch result {
            case .failure(let error):
                self.rawMTPDeviceIDs.remove(id)
                self.mtpEnumerationTokens.removeValue(forKey: id)
                if !(camera.contents?.isEmpty ?? true) {
                    self.publishCameraContents(for: camera)
                } else {
                    self.onError?(id, error.localizedDescription)
                }
            case .success(let data):
                do {
                    let storageIDs = try MTPCodec.storageIDs(from: data)
                    guard !storageIDs.isEmpty else { throw MTPServiceError.noStorage }
                    self.requestStorageRoots(storageIDs: storageIDs,
                                             index: 0,
                                             roots: [],
                                             deviceID: id,
                                             token: token,
                                             on: camera)
                } catch {
                    self.rawMTPDeviceIDs.remove(id)
                    self.mtpEnumerationTokens.removeValue(forKey: id)
                    self.onError?(id, error.localizedDescription)
                }
            }
        }
    }

    func requestObjectHandles(storageID: UInt32,
                              parentHandle: UInt32,
                              on camera: ICCameraDevice,
                              cancellation: FileTransferCancellation? = nil,
                              completion: @escaping (Result<[UInt32], Error>) -> Void) {
        // Object format 0 is the MTP wildcard. It includes hidden entries
        sendCommand(operationCode: MTPOperation.getObjectHandles,
                    parameters: [storageID, 0, parentHandle],
                    on: camera,
                    cancellation: cancellation) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    let handles = try MTPCodec.objectHandles(from: data)
                    completion(.success(handles))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func requestObjectSize(handle: UInt32,
                           on camera: ICCameraDevice,
                           cancellation: FileTransferCancellation? = nil,
                           completion: @escaping (Result<UInt64, Error>) -> Void) {
        sendCommand(operationCode: MTPOperation.getObjectPropValue,
                    parameters: [handle, MTPObjectProperty.objectSize],
                    on: camera,
                    cancellation: cancellation) { result in
            completion(result.flatMap { data in Result { try MTPCodec.objectSize(from: data) } })
        }
    }

    private func requestStorageRoots(storageIDs: [UInt32],
                                     index: Int,
                                     roots: [MTPFileNode],
                                     deviceID: String,
                                     token: UUID,
                                     on camera: ICCameraDevice) {
        guard mtpEnumerationTokens[deviceID] == token else { return }
        guard index < storageIDs.count else {
            let sortedRoots = roots.sorted(by: MTPFileNode.displayOrder)
            rootsByDeviceID[deviceID] = sortedRoots
            if selectedDeviceID == deviceID { onContentsChanged?(deviceID, sortedRoots) }
            return
        }

        let storageID = storageIDs[index]
        sendCommand(operationCode: MTPOperation.getStorageInfo, parameters: [storageID], on: camera) { [weak self] result in
            guard let self = self,
                self.mtpEnumerationTokens[deviceID] == token
            else { return }
            let fallbackName = storageIDs.count == 1 ? "Internal shared storage" : "Storage \(index + 1)"
            let storageInfo: MTPStorageInfo
            switch result {
            case .success(let data):
                storageInfo = (try? MTPCodec.storageInfo(from: data, fallbackName: fallbackName))
                    ?? MTPStorageInfo(name: fallbackName, isReadOnly: false)
            case .failure:
                storageInfo = MTPStorageInfo(name: fallbackName, isReadOnly: false)
            }

            let root = MTPFileNode(id: "\(deviceID):storage:\(storageID)",
                                   handle: UInt32.max,
                                   storageID: storageID,
                                   name: storageInfo.name,
                                   isFolder: true,
                                   isStorageRoot: true,
                                   size: nil,
                                   modifiedAt: nil,
                                   isLocked: storageInfo.isReadOnly,
                                   parentID: nil,
                                   childrenLoaded: false)
            self.requestStorageRoots(storageIDs: storageIDs,
                                     index: index + 1,
                                     roots: roots + [root],
                                     deviceID: deviceID,
                                     token: token,
                                     on: camera)
        }
    }

    func requestObjectInfos(handles: [UInt32],
                            index: Int,
                            parentID: String,
                            fallbackStorageID: UInt32,
                            nodes: [MTPFileNode],
                            firstError: Error?,
                            on camera: ICCameraDevice,
                            cancellation: FileTransferCancellation? = nil,
                            progress: (([MTPFileNode]) -> Void)?,
                            completion: @escaping (Result<[MTPFileNode], Error>) -> Void) {
        guard cancellation?.isCancelled != true else {
            completion(.failure(FileTransferError.cancelled))
            return
        }
        guard index < handles.count else {
            finishObjectInfoRequest(nodes: nodes, firstError: firstError, completion: completion)
            return
        }

        requestObjectNode(handle: handles[index],
                          parentID: parentID,
                          fallbackStorageID: fallbackStorageID,
                          on: camera,
                          cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            var updatedNodes = nodes
            var updatedError = firstError
            switch result {
            case .failure(let error):
                if error is FileTransferError {
                    completion(.failure(error))
                    return
                }
                if case MTPServiceError.commandTimedOut = error {
                    completion(.failure(error))
                    return
                }
                updatedError = updatedError ?? error
            case .success(let node):
                updatedNodes.append(node)
                progress?(updatedNodes.sorted(by: MTPFileNode.displayOrder))
            }
            self.requestObjectInfos(handles: handles,
                                    index: index + 1,
                                    parentID: parentID,
                                    fallbackStorageID: fallbackStorageID,
                                    nodes: updatedNodes,
                                    firstError: updatedError,
                                    on: camera,
                                    cancellation: cancellation,
                                    progress: progress,
                                    completion: completion)
        }
    }

    private func finishObjectInfoRequest(nodes: [MTPFileNode], firstError: Error?, completion: (Result<[MTPFileNode], Error>) -> Void) {
        if nodes.isEmpty, let firstError = firstError {
            completion(.failure(firstError))
            return
        }
        completion(.success(nodes.sorted(by: MTPFileNode.displayOrder)))
    }

    private func requestObjectNode(handle: UInt32,
                                   parentID: String,
                                   fallbackStorageID: UInt32,
                                   on camera: ICCameraDevice,
                                   cancellation: FileTransferCancellation?,
                                   completion: @escaping (Result<MTPFileNode, Error>) -> Void) {
        sendCommand(operationCode: MTPOperation.getObjectInfo,
                    parameters: [handle],
                    on: camera,
                    cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    let info = try MTPCodec.objectInfo(from: data)
                    self.makeObjectNode(handle: handle,
                                        info: info,
                                        parentID: parentID,
                                        fallbackStorageID: fallbackStorageID,
                                        camera: camera,
                                        cancellation: cancellation,
                                        completion: completion)
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func makeObjectNode(handle: UInt32,
                                info: MTPObjectInfo,
                                parentID: String,
                                fallbackStorageID: UInt32,
                                camera: ICCameraDevice,
                                cancellation: FileTransferCancellation?,
                                completion: @escaping (Result<MTPFileNode, Error>) -> Void) {
        let finish: (Int64?) -> Void = { [weak self] exactSize in
            guard let self = self else { return }
            let storageID = info.storageID == 0 ? fallbackStorageID : info.storageID
            let name = info.filename.isEmpty ? String(format: "Object %08X", handle) : info.filename
            completion(.success(MTPFileNode(id: "\(self.deviceID(for: camera)):\(handle)",
                                            handle: handle,
                                            storageID: storageID,
                                            name: name,
                                            isFolder: info.isFolder,
                                            size: info.isFolder ? nil : exactSize,
                                            modifiedAt: info.modifiedAt,
                                            isLocked: info.protectionStatus != 0,
                                            parentID: parentID,
                                            childrenLoaded: !info.isFolder)))
        }

        guard !info.isFolder, info.compressedSize == UInt32.max else {
            finish(info.isFolder ? nil : Int64(info.compressedSize))
            return
        }
        requestObjectSize(handle: handle, on: camera, cancellation: cancellation) { sizeResult in
            switch sizeResult {
            case .success(let size) where size <= UInt64(Int64.max):
                finish(Int64(size))
            case .success, .failure:
                finish(nil)   // Keep the file visible if an older OEM stack cannot provide its 64-bit size
            }
        }
    }
}
