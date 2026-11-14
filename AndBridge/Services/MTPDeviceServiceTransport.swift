import Foundation
import ImageCaptureCore

// Serialized MTP transport
extension MTPDeviceService {
    func sendCommand(operationCode: UInt16,
                     parameters: [UInt32],
                     on camera: ICCameraDevice,
                     cancellation: FileTransferCancellation? = nil,
                     retriesRemaining: Int = 2,
                     completion: @escaping (Result<Data, Error>) -> Void) {
        sendCommandWithResponse(operationCode: operationCode,
                                parameters: parameters,
                                outData: nil,
                                on: camera,
                                cancellation: cancellation) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result,
                retriesRemaining > 0,
                cancellation?.isCancelled != true,
                self.isDeviceBusyError(error) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.sendCommand(operationCode: operationCode,
                                     parameters: parameters,
                                     on: camera,
                                     cancellation: cancellation,
                                     retriesRemaining: retriesRemaining - 1,
                                     completion: completion)
                }
                return
            }
            completion(result.map(\.data))
        }
    }

    func sendCommandWithResponse(operationCode: UInt16,
                                 parameters: [UInt32],
                                 outData: Data?,
                                 on camera: ICCameraDevice,
                                 cancellation: FileTransferCancellation? = nil,
                                 completion: @escaping (Result<MTPCommandResult, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.sendCommandWithResponse(operationCode: operationCode,
                                              parameters: parameters,
                                              outData: outData,
                                              on: camera,
                                              cancellation: cancellation,
                                              completion: completion)
            }
            return
        }

        guard cancellation?.isCancelled != true else {
            completion(.failure(FileTransferError.cancelled))
            return
        }

        let transactionID = nextTransactionID
        nextTransactionID &+= 1
        let command = MTPCodec.command(operationCode: operationCode, transactionID: transactionID, parameters: parameters)
        pendingMTPCommands.append(PendingMTPCommand(operationCode: operationCode,
                                                    command: command,
                                                    outData: outData,
                                                    camera: camera,
                                                    cancellation: cancellation,
                                                    completion: completion))
        startNextMTPCommandIfNeeded()
    }

    private func startNextMTPCommandIfNeeded() {
        guard !isMTPCommandInFlight, recoveringMTPDeviceIDs.isEmpty else { return }
        while let first = pendingMTPCommands.first, first.cancellation?.isCancelled == true {
            pendingMTPCommands.removeFirst().completion(.failure(FileTransferError.cancelled))
        }
        guard !pendingMTPCommands.isEmpty else { return }
        let request = pendingMTPCommands.removeFirst()
        guard request.camera.hasOpenSession else {
            request.completion(.failure(MTPServiceError.deviceUnavailable))
            startNextMTPCommandIfNeeded()
            return
        }

        isMTPCommandInFlight = true
        activeMTPCommand = request
        activeMTPCommandCompletionDelivered = false
        activeMTPCommandCancellationHandlerID = request.cancellation?.registerCancellationHandler { [weak self] in
            DispatchQueue.main.async { self?.cancelActiveMTPCommand(withID: request.id) }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.timeOutActiveMTPCommand(withID: request.id)
        }
        activeMTPCommandTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + commandTimeout(for: request), execute: timeout)

        request.camera.requestSendPTPCommand(request.command, outData: request.outData) { [weak self] firstData, secondData, error in
            DispatchQueue.main.async {
                self?.finishActiveMTPCommand(request, firstData: firstData, secondData: secondData, error: error)
            }
        }
    }

    private func commandTimeout(for request: PendingMTPCommand) -> TimeInterval {
        let outgoingMiB = Double(request.outData?.count ?? 0) / (1024 * 1024)
        return min(300, 60 + outgoingMiB * 2)
    }

    private func cancelActiveMTPCommand(withID id: UUID) {
        guard let request = activeMTPCommand,
            request.id == id,
            !activeMTPCommandCompletionDelivered
        else { return }
        deliverActiveMTPCommandCompletion(.failure(FileTransferError.cancelled))
        recoverMTPTransport(after: request)
    }

    private func timeOutActiveMTPCommand(withID id: UUID) {
        guard let request = activeMTPCommand,
            request.id == id,
            !activeMTPCommandCompletionDelivered
        else { return }
        deliverActiveMTPCommandCompletion(.failure(MTPServiceError.commandTimedOut))
        recoverMTPTransport(after: request)
    }

    private func finishActiveMTPCommand(_ request: PendingMTPCommand,
                                        firstData: Data,
                                        secondData: Data,
                                        error: Error?) {
        guard activeMTPCommand?.id == request.id else { return }
        if !activeMTPCommandCompletionDelivered {
            deliverActiveMTPCommandCompletion(
                commandResult(for: request,
                              firstData: firstData,
                              secondData: secondData,
                              error: error)
            )
        }
        clearActiveMTPCommand()
        startNextMTPCommandIfNeeded()
    }

    private func deliverActiveMTPCommandCompletion(_ result: Result<MTPCommandResult, Error>) {
        guard let request = activeMTPCommand, !activeMTPCommandCompletionDelivered else { return }
        activeMTPCommandCompletionDelivered = true
        activeMTPCommandTimeout?.cancel()
        activeMTPCommandTimeout = nil
        request.cancellation?.removeCancellationHandler(activeMTPCommandCancellationHandlerID)
        activeMTPCommandCancellationHandlerID = nil
        request.completion(result)
    }

    private func clearActiveMTPCommand() {
        activeMTPCommandTimeout?.cancel()
        activeMTPCommandTimeout = nil
        activeMTPCommand?.cancellation?.removeCancellationHandler(activeMTPCommandCancellationHandlerID)
        activeMTPCommandCancellationHandlerID = nil
        activeMTPCommand = nil
        activeMTPCommandCompletionDelivered = false
        isMTPCommandInFlight = false
    }

    private func recoverMTPTransport(after request: PendingMTPCommand) {
        let deviceID = deviceID(for: request.camera)
        guard recoveringMTPDeviceIDs.insert(deviceID).inserted else { return }
        if request.camera.hasOpenSession {
            request.camera.requestCloseSession()
        } else {
            mtpDeviceSessionDidClose(request.camera)
        }
    }

    func mtpDeviceSessionDidClose(_ camera: ICCameraDevice) {
        let id = deviceID(for: camera)
        if activeMTPCommand?.camera === camera {
            if !activeMTPCommandCompletionDelivered {
                deliverActiveMTPCommandCompletion(.failure(MTPServiceError.deviceUnavailable))
            }
            clearActiveMTPCommand()
        }

        guard recoveringMTPDeviceIDs.contains(id) else {
            startNextMTPCommandIfNeeded()
            return
        }
        guard selectedDeviceID == id, camerasByID[id] === camera else {
            recoveringMTPDeviceIDs.remove(id)
            startNextMTPCommandIfNeeded()
            return
        }
        camera.requestOpenSession()
    }

    func mtpDeviceSessionDidOpen(_ camera: ICCameraDevice, error: Error?) {
        let id = deviceID(for: camera)
        guard recoveringMTPDeviceIDs.remove(id) != nil else { return }
        if error != nil {
            pendingMTPCommands.removeAll { request in
                guard request.camera === camera else { return false }
                request.completion(.failure(MTPServiceError.deviceUnavailable))
                return true
            }
        }
        startNextMTPCommandIfNeeded()
    }

    func mtpDeviceWasRemoved(_ camera: ICCameraDevice) {
        let id = deviceID(for: camera)
        recoveringMTPDeviceIDs.remove(id)
        if activeMTPCommand?.camera === camera {
            if !activeMTPCommandCompletionDelivered {
                deliverActiveMTPCommandCompletion(.failure(MTPServiceError.deviceUnavailable))
            }
            clearActiveMTPCommand()
        }

        let removedRequests = pendingMTPCommands.filter { $0.camera === camera }
        pendingMTPCommands.removeAll { $0.camera === camera }
        for request in removedRequests {
            request.completion(.failure(MTPServiceError.deviceUnavailable))
        }
        startNextMTPCommandIfNeeded()
    }

    private func commandResult(for request: PendingMTPCommand,
                               firstData: Data,
                               secondData: Data,
                               error: Error?) -> Result<MTPCommandResult, Error> {
        if let error = error { return .failure(error) }

        let response: Data
        let inputData: Data
        if MTPCodec.containerType(of: secondData) == 3 {
            response = secondData
            inputData = firstData
        } else if MTPCodec.containerType(of: firstData) == 3 {
            response = firstData
            inputData = secondData
        } else {
            return .failure(MTPServiceError.invalidDeviceResponse)
        }

        guard let responseCode = MTPCodec.responseCode(from: response) else { return .failure(MTPServiceError.invalidDeviceResponse) }
        guard responseCode == 0x2001 else { return .failure(MTPServiceError.response(request.operationCode, responseCode)) }

        do {
            return .success(MTPCommandResult(data: try MTPCodec.validatedPayload(from: inputData,
                                                                                 operationCode: request.operationCode),
                                             parameters: MTPCodec.responseParameters(from: response)))
        } catch {
            return .failure(MTPServiceError.invalidDeviceResponse)
        }
    }
}
