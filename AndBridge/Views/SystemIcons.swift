import AppKit

enum SystemIcons {
    static let phone: NSImage = {
        let image: NSImage

        if #available(macOS 11.0, *) {
            image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Android device")
                ?? NSImage(named: NSImage.touchBarCommunicationAudioTemplateName) ?? NSImage(size: NSSize(width: 32, height: 32))
        } else {
            image = NSImage(named: NSImage.touchBarCommunicationAudioTemplateName) ?? NSImage(size: NSSize(width: 32, height: 32))
        }

        image.isTemplate = true
        return image
    }()

    static let refresh: NSImage = {
        let image = NSImage(named: NSImage.refreshTemplateName) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()

    static let folder: NSImage = { NSImage(named: NSImage.folderName) ?? NSImage(size: NSSize(width: 16, height: 16)) }()
    static let genericFile: NSImage = { NSImage(named: NSImage.multipleDocumentsName) ?? NSImage(size: NSSize(width: 16, height: 16)) }()
    static let disconnected: NSImage = { NSImage(named: NSImage.cautionName) ?? NSImage(size: NSSize(width: 32, height: 32)) }()

    static func fileIcon(for node: MTPFileNode) -> NSImage {
        if node.isFolder { return folder }
        let fileExtension = (node.name as NSString).pathExtension
        guard !fileExtension.isEmpty else { return genericFile }
        return NSWorkspace.shared.icon(forFileType: fileExtension)
    }
}
