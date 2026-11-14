import AppKit
import Foundation

struct MTPDevice: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
}

final class MTPFileNode: NSObject, Identifiable {

    let id: String
    let handle: UInt32
    var storageID: UInt32
    let name: String
    let isFolder: Bool
    let isStorageRoot: Bool
    let size: Int64?
    let modifiedAt: Date?
    let isLocked: Bool
    var parentID: String?
    var children: [MTPFileNode]
    var childrenLoaded: Bool
    var isLoadingChildren: Bool

    init(id: String,
         handle: UInt32,
         storageID: UInt32,
         name: String,
         isFolder: Bool,
         isStorageRoot: Bool = false,
         size: Int64?,
         modifiedAt: Date?,
         isLocked: Bool,
         parentID: String?,
         children: [MTPFileNode] = [],
         childrenLoaded: Bool = true,
         isLoadingChildren: Bool = false) {
        self.id = id
        self.handle = handle
        self.storageID = storageID
        self.name = name
        self.isFolder = isFolder
        self.isStorageRoot = isStorageRoot
        self.size = size
        self.modifiedAt = modifiedAt
        self.isLocked = isLocked
        self.parentID = parentID
        self.children = children
        self.childrenLoaded = childrenLoaded
        self.isLoadingChildren = isLoadingChildren
    }

    func containsDescendant(withID candidateID: String) -> Bool {
        children.contains { child in
            child.id == candidateID || child.containsDescendant(withID: candidateID)
        }
    }

    func updateStorageIDRecursively(to storageID: UInt32) {
        self.storageID = storageID
        for child in children { child.updateStorageIDRecursively(to: storageID) }
    }

    static func displayOrder(_ lhs: MTPFileNode, _ rhs: MTPFileNode) -> Bool {
        if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

}

extension Array where Element == MTPFileNode {
    func node(withID id: String) -> MTPFileNode? {
        for node in self {
            if node.id == id { return node }
            if let match = node.children.node(withID: id) { return match }
        }

        return nil
    }

    @discardableResult
    mutating func removeNode(withID id: String) -> Bool {
        if let index = firstIndex(where: { $0.id == id }) {
            remove(at: index)
            return true
        }

        return contains { $0.children.removeNode(withID: id) }
    }
}

enum BrowserState: Equatable {
    case noDevice
    case loading(String)
    case ready
    case failed(String)
}
