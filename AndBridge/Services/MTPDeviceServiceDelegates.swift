import ImageCaptureCore

// Image Capture delegates
extension MTPDeviceService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        performOnMain { [weak self] in
            guard let self = self,
                let camera = device as? ICCameraDevice,
                self.isAndroidMTPCandidate(camera)
            else { return }
            camera.delegate = self
            self.camerasByID[self.deviceID(for: camera)] = camera
            if !moreComing { self.publishDevices() }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.forgetDevice(device, reportDisconnection: true)
            if !moreGoing { self.publishDevices() }
        }
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        performOnMain { [weak self] in self?.publishDevices() }
    }
}

extension MTPDeviceService: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let id = self.deviceID(for: device)
            if let camera = device as? ICCameraDevice {
                self.mtpDeviceSessionDidOpen(camera, error: error)
            }
            if let error = error {
                self.onError?(id, error.localizedDescription)
                return
            }

            guard let camera = device as? ICCameraDevice else { return }
            if let roots = self.rootsByDeviceID[id] {
                self.onContentsChanged?(id, roots)
                return
            }

            self.onLoadingChanged?(id, "Preparing MTP storage...")
            if camera.contentCatalogPercentCompleted == 100 {
                self.beginMTPFileEnumeration(on: camera)
            }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            if let camera = device as? ICCameraDevice {
                self.mtpDeviceSessionDidClose(camera)
            }
            if let error = error {
                self.onError?(self.deviceID(for: device), error.localizedDescription)
            }
        }
    }

    func didRemove(_ device: ICDevice) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.forgetDevice(device, reportDisconnection: false)
            self.publishDevices()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        refreshFallbackContents(for: camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        refreshFallbackContents(for: camera)
    }

    func cameraDevice(_ camera: ICCameraDevice,
                      didReceiveThumbnail thumbnail: CGImage?,
                      for item: ICCameraItem,
                      error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice,
                      didReceiveMetadata metadata: [AnyHashable: Any]?,
                      for item: ICCameraItem,
                      error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        refreshFallbackContents(for: camera)
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        refreshFallbackContents(for: camera)
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        performOnMain { [weak self] in self?.beginMTPFileEnumeration(on: device) }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        beginEnumeration(for: device)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        beginEnumeration(for: device)
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.onError?(self.deviceID(for: device), "Unlock the Android device and allow USB file access.")
        }
    }
}

extension MTPDeviceService {
    fileprivate func forgetDevice(_ device: ICDevice, reportDisconnection: Bool) {
        let id = deviceID(for: device)
        if let camera = device as? ICCameraDevice {
            mtpDeviceWasRemoved(camera)
        }
        camerasByID.removeValue(forKey: id)
        rootsByDeviceID.removeValue(forKey: id)
        mtpEnumerationTokens.removeValue(forKey: id)
        rawMTPDeviceIDs.remove(id)
        guard reportDisconnection, selectedDeviceID == id else { return }
        selectedDeviceID = nil
        onError?(id, "The selected device was disconnected.")
    }

    fileprivate func refreshFallbackContents(for camera: ICCameraDevice) {
        performOnMain { [weak self] in
            guard let self = self,
                !self.rawMTPDeviceIDs.contains(self.deviceID(for: camera))
            else { return }
            self.publishCameraContents(for: camera)
        }
    }

    fileprivate func beginEnumeration(for device: ICDevice) {
        performOnMain { [weak self] in
            guard let self = self, let camera = device as? ICCameraDevice else { return }
            self.beginMTPFileEnumeration(on: camera)
        }
    }
}
