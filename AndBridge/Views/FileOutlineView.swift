import AppKit
import CoreServices
import SwiftUI

struct FileOutlineActions {
    let loadChildren: (MTPFileNode) -> Void
    let canMove: ([MTPFileNode], MTPFileNode) -> Bool
    let move: ([MTPFileNode], MTPFileNode) -> Void
    let createFolder: (String, MTPFileNode) -> Void
    let copy: ([MTPFileNode]) -> Void
    let canPaste: (MTPFileNode) -> Bool
    let paste: (MTPFileNode) -> Void
    let delete: ([MTPFileNode]) -> Void
    let importFiles: ([URL], MTPFileNode, @escaping () -> Void) -> Void
    let export: (MTPFileNode, URL, @escaping (Error?) -> Void) -> Void
}

struct FileOutlineView: NSViewRepresentable {
    let roots: [MTPFileNode]
    let actions: FileOutlineActions

    func makeCoordinator() -> Coordinator {
        Coordinator(roots: roots, actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = ContextOutlineView()
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.headerView = NSTableHeaderView()
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 16
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        var draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]
        draggedTypes.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType(rawValue: $0) })
        outlineView.registerForDraggedTypes(draggedTypes)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let name = NSTableColumn(identifier: Coordinator.Column.name)
        name.title = "Name"
        name.minWidth = 240
        name.width = 440
        outlineView.addTableColumn(name)
        outlineView.outlineTableColumn = name

        let modified = NSTableColumn(identifier: Coordinator.Column.modified)
        modified.title = "Date Modified"
        modified.minWidth = 150
        modified.width = 185
        outlineView.addTableColumn(modified)

        let size = NSTableColumn(identifier: Coordinator.Column.size)
        size.title = "Size"
        size.minWidth = 90
        size.width = 110
        outlineView.addTableColumn(size)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        outlineView.contextMenuProvider = {
            [weak coordinator = context.coordinator, weak outlineView] event in
            coordinator?.contextMenu(for: event, in: outlineView)
        }
        outlineView.reloadData()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(roots: roots, actions: actions)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSFilePromiseProviderDelegate {

        enum Column {
            static let name = NSUserInterfaceItemIdentifier("NameColumn")
            static let modified = NSUserInterfaceItemIdentifier("ModifiedColumn")
            static let size = NSUserInterfaceItemIdentifier("SizeColumn")
        }

        var roots: [MTPFileNode]
        var actions: FileOutlineActions
        weak var outlineView: NSOutlineView?

        private var draggedNodeIDs: [String] = []
        private var contextNode: MTPFileNode?
        private var contextNodes: [MTPFileNode] = []
        private var expandedNodeIDs = Set<String>()
        private var isRefreshingExpandedItems = false
        private var treeSnapshot: TreeSnapshot

        private struct NodeSnapshot: Equatable {
            let childIdentities: [ObjectIdentifier]
            let childrenLoaded: Bool
            let isLoadingChildren: Bool
        }

        private struct TreeSnapshot {
            let rootIdentities: [ObjectIdentifier]
            let nodesByID: [String: NodeSnapshot]

            init(roots: [MTPFileNode]) {
                rootIdentities = roots.map { ObjectIdentifier($0) }
                var snapshots: [String: NodeSnapshot] = [:]

                func record(_ node: MTPFileNode) {
                    snapshots[node.id] = NodeSnapshot(childIdentities: node.children.map { ObjectIdentifier($0) },
                                                      childrenLoaded: node.childrenLoaded,
                                                      isLoadingChildren: node.isLoadingChildren)
                    node.children.forEach(record)
                }

                roots.forEach(record)
                nodesByID = snapshots
            }
        }

        private let filePromiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "hx.AndBridge.file-promises"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        private let receiverQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "hx.AndBridge.file-promise-receivers"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        private let byteFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        init(roots: [MTPFileNode], actions: FileOutlineActions) {
            self.roots = roots
            self.actions = actions
            treeSnapshot = TreeSnapshot(roots: roots)
        }

        func update(roots: [MTPFileNode], actions: FileOutlineActions) {
            let previousSnapshot = treeSnapshot
            let updatedSnapshot = TreeSnapshot(roots: roots)
            self.roots = roots
            self.actions = actions
            treeSnapshot = updatedSnapshot

            guard let outlineView = outlineView else { return }
            let reloadsEntireTree = previousSnapshot.rootIdentities != updatedSnapshot.rootIdentities
            let changedNodeIDs = reloadsEntireTree ? [] : structurallyChangedNodeIDs(in: roots,
                                                                                     previous: previousSnapshot,
                                                                                     updated: updatedSnapshot)
            guard reloadsEntireTree || !changedNodeIDs.isEmpty else { return }

            let selectedNodeIDs = selectedNodes(in: outlineView).map(\.id)
            if reloadsEntireTree {
                outlineView.reloadData()
            } else {
                let expandedChangedNodes = changedNodeIDs.compactMap { id -> MTPFileNode? in
                    guard let previous = previousSnapshot.nodesByID[id],
                        let updated = updatedSnapshot.nodesByID[id],
                        previous.childIdentities.isEmpty,
                        !updated.childIdentities.isEmpty,
                        let node = roots.node(withID: id),
                        expandedNodeIDs.contains(id) || outlineView.isItemExpanded(node)
                    else { return nil }
                    return node
                }

                // An item first expands before its asynchronous children arrive. AppKit otherwise keeps the zero-child
                // expansion cached even after reloadItem, so force expanded changed items through a collapsed state before
                // reloading and restoring them.
                isRefreshingExpandedItems = true
                for node in expandedChangedNodes { outlineView.collapseItem(node, collapseChildren: false) }
                for id in changedNodeIDs {
                    guard let node = roots.node(withID: id),
                        let previous = previousSnapshot.nodesByID[id],
                        let updated = updatedSnapshot.nodesByID[id]
                    else { continue }
                    let childrenChanged = previous.childIdentities != updated.childIdentities || previous.childrenLoaded != updated.childrenLoaded
                    outlineView.reloadItem(node, reloadChildren: childrenChanged)
                }
                for node in expandedChangedNodes { outlineView.expandItem(node) }
                isRefreshingExpandedItems = false
            }
            restoreExpandedItems(in: roots, outlineView: outlineView)

            let selectedRows = IndexSet(
                selectedNodeIDs.compactMap { id in
                    guard let node = roots.node(withID: id) else { return nil }
                    let row = outlineView.row(forItem: node)
                    return row >= 0 ? row : nil
                }
            )
            outlineView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }

        private func structurallyChangedNodeIDs(in nodes: [MTPFileNode], previous: TreeSnapshot, updated: TreeSnapshot) -> [String] {
            var changedIDs: [String] = []
            for node in nodes {
                if let oldValue = previous.nodesByID[node.id],
                    let newValue = updated.nodesByID[node.id],
                    oldValue != newValue {
                    changedIDs.append(node.id)
                }
                changedIDs.append(contentsOf: structurallyChangedNodeIDs(in: node.children, previous: previous, updated: updated))
            }

            return changedIDs
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? MTPFileNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? MTPFileNode else { return false }
            return node.isFolder && (!node.childrenLoaded || !node.children.isEmpty)
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? MTPFileNode else { return }
            expandedNodeIDs.insert(node.id)
            actions.loadChildren(node)
        }

        func outlineViewItemWillCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? MTPFileNode else { return }
            guard !isRefreshingExpandedItems else { return }
            expandedNodeIDs.remove(node.id)
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? MTPFileNode { return node.children[index] }
            return roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? MTPFileNode, let tableColumn = tableColumn else { return nil }
            if tableColumn.identifier == Column.name { return nameCell(for: node, in: outlineView) }
            if tableColumn.identifier == Column.modified {
                return textCell(identifier: Column.modified,
                                text: node.modifiedAt.map(dateFormatter.string(from:)) ?? "-",
                                alignment: .left,
                                in: outlineView)
            }

            return textCell(identifier: Column.size,
                            text: node.size.map(byteFormatter.string(fromByteCount:)) ?? "—",
                            alignment: .right,
                            in: outlineView)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? MTPFileNode, !node.isStorageRoot else { return nil }
            let selectedNodes = self.selectedNodes(in: outlineView).filter { !$0.isStorageRoot }
            draggedNodeIDs = selectedNodes.contains(where: { $0.id == node.id }) ? selectedNodes.map(\.id) : [node.id]
            let provider = NSFilePromiseProvider(fileType: promisedFileType(for: node), delegate: self)
            provider.userInfo = node
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView,
                         validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let destination = item as? MTPFileNode else { return [] }
            if isInternalDrag(info) {
                let sources = draggedNodes()
                guard actions.canMove(sources, destination) else { return [] }
                outlineView.setDropItem(destination, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }
            guard destination.isFolder,
                !destination.isLocked,
                hasImportableFiles(in: info.draggingPasteboard)
            else { return [] }
            outlineView.setDropItem(destination, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let destination = item as? MTPFileNode else { return false }
            if isInternalDrag(info) {
                let sources = draggedNodes()
                guard actions.canMove(sources, destination) else { return false }
                actions.move(sources, destination)
                return true
            }

            let pasteboard = info.draggingPasteboard
            if let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL], !objects.isEmpty {
                actions.importFiles(objects.map { $0 as URL }, destination, {})
                return true
            }
            guard
                let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                                       options: nil
                ) as? [NSFilePromiseReceiver], !receivers.isEmpty
            else { return false }
            receive(receivers, into: destination)
            return true
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? MTPFileNode)?.name ?? "Android file"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let node = filePromiseProvider.userInfo as? MTPFileNode else {
                completionHandler(FilePromiseError.missingItem)
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    completionHandler(FilePromiseError.missingItem)
                    return
                }

                self.actions.export(node, url, completionHandler)
            }
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            filePromiseQueue
        }

        func contextMenu(for event: NSEvent, in outlineView: NSOutlineView?) -> NSMenu? {
            guard let outlineView = outlineView else { return nil }
            let location = outlineView.convert(event.locationInWindow, from: nil)
            let row = outlineView.row(at: location)
            guard row >= 0, let node = outlineView.item(atRow: row) as? MTPFileNode else { return nil }
            if !outlineView.selectedRowIndexes.contains(row) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            contextNode = node
            contextNodes = selectedNodes(in: outlineView)
            let multipleItems = contextNodes.count > 1
            let canCopy = !contextNodes.isEmpty && contextNodes.allSatisfy { !$0.isStorageRoot }
            let canDelete = !contextNodes.isEmpty && contextNodes.allSatisfy { !$0.isStorageRoot && !$0.isLocked }

            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(menuItem(title: "New Folder", action: #selector(newFolder(_:)), enabled: node.isFolder && !node.isLocked))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem(title: multipleItems ? "Copy \(contextNodes.count) Items" : "Copy",
                                  action: #selector(copyItem(_:)),
                                  enabled: canCopy))
            menu.addItem(menuItem(title: "Paste", action: #selector(pasteItem(_:)), enabled: actions.canPaste(node)))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem(title: multipleItems ? "Delete \(contextNodes.count) Items..." : "Delete",
                                  action: #selector(deleteItem(_:)),
                                  enabled: canDelete))

            return menu
        }

        @objc private func newFolder(_ sender: Any?) {
            guard let destination = contextNode, destination.isFolder, !destination.isLocked else { return }

            let alert = NSAlert()
            alert.messageText = "Create a New Folder"
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            let nameField = NSTextField(string: "New Folder")
            nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            nameField.selectText(nil)
            alert.accessoryView = nameField
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            actions.createFolder(nameField.stringValue, destination)
        }

        @objc private func copyItem(_ sender: Any?) {
            guard !contextNodes.isEmpty,
                contextNodes.allSatisfy({ !$0.isStorageRoot })
            else { return }
            actions.copy(contextNodes)
        }

        @objc private func pasteItem(_ sender: Any?) {
            guard let destination = contextNode, actions.canPaste(destination) else { return }
            actions.paste(destination)
        }

        @objc private func deleteItem(_ sender: Any?) {
            guard !contextNodes.isEmpty,
                contextNodes.allSatisfy({ !$0.isStorageRoot && !$0.isLocked })
            else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            if contextNodes.count == 1, let node = contextNodes.first {
                alert.messageText = "Delete “\(node.name)”?"
                alert.informativeText = node.isFolder
                    ? "This permanently deletes the folder and everything in it from the Android device."
                    : "This permanently deletes the file from the Android device."
            } else {
                alert.messageText = "Delete \(contextNodes.count) items?"
                alert.informativeText = "This permanently deletes the selected items from the Android device."
            }
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            actions.delete(contextNodes)
        }

        private func isInternalDrag(_ info: NSDraggingInfo) -> Bool {
            info.draggingSource as AnyObject? === outlineView
        }

        private func draggedNodes() -> [MTPFileNode] {
            draggedNodeIDs.compactMap { roots.node(withID: $0) }
        }

        private func selectedNodes(in outlineView: NSOutlineView) -> [MTPFileNode] {
            outlineView.selectedRowIndexes.compactMap { row in
                outlineView.item(atRow: row) as? MTPFileNode
            }
        }

        private func restoreExpandedItems(in nodes: [MTPFileNode], outlineView: NSOutlineView) {
            for node in nodes where expandedNodeIDs.contains(node.id) {
                outlineView.expandItem(node)
                restoreExpandedItems(in: node.children, outlineView: outlineView)
            }
        }

        private func hasImportableFiles(in pasteboard: NSPasteboard) -> Bool {
            pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        }

        private func receive(_ receivers: [NSFilePromiseReceiver], into destination: MTPFileNode) {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AndBridge-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                NSApp.presentError(error)
                return
            }
            let group = DispatchGroup()
            let resultLock = NSLock()
            var receivedURLs: [URL] = []
            var firstError: Error?
            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: temporaryDirectory, options: [:], operationQueue: receiverQueue
                ) { url, error in
                    resultLock.lock()
                    if let error = error {
                        firstError = firstError ?? error
                    } else {
                        receivedURLs.append(url)
                    }
                    resultLock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                if let error = firstError {
                    self.receiverQueue.addOperation { try? FileManager.default.removeItem(at: temporaryDirectory) }
                    NSApp.presentError(error)
                    return
                }
                self.actions.importFiles(receivedURLs, destination) {
                    self.receiverQueue.addOperation { try? FileManager.default.removeItem(at: temporaryDirectory) }
                }
            }
        }

        private func promisedFileType(for node: MTPFileNode) -> String {
            if node.isFolder { return kUTTypeFolder as String }
            let fileExtension = (node.name as NSString).pathExtension
            guard !fileExtension.isEmpty,
                let type = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension,
                                                                 fileExtension as CFString,
                                                                 kUTTypeData)?.takeRetainedValue()
            else { return kUTTypeData as String }

            return type as String
        }

        private func menuItem(title: String, action: Selector, enabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }

        private func nameCell(for node: MTPFileNode, in outlineView: NSOutlineView) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier("NameCell")
            let displayName = node.isLoadingChildren ? "\(node.name) - Reading..." : node.name
            if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell.textField?.stringValue = displayName
                cell.imageView?.image = SystemIcons.fileIcon(for: node)
                return cell
            }

            let cell = NSTableCellView()
            cell.identifier = identifier
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: displayName)
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         imageView.widthAnchor.constraint(equalToConstant: 16),
                                         imageView.heightAnchor.constraint(equalToConstant: 16),
                                         textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                                         textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                         textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),])
            imageView.image = SystemIcons.fileIcon(for: node)
            return cell
        }

        private func textCell(identifier: NSUserInterfaceItemIdentifier,
                              text: String,
                              alignment: NSTextAlignment,
                              in outlineView: NSOutlineView) -> NSTableCellView {
            if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell.textField?.stringValue = text
                return cell
            }

            let cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: text)
            textField.textColor = .secondaryLabelColor
            textField.alignment = alignment
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                         textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),])
            return cell
        }
    }

}

private final class ContextOutlineView: NSOutlineView {

    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
    }

}

private enum FilePromiseError: LocalizedError {
    case missingItem

    var errorDescription: String? { "The dragged Android item is no longer available." }
}
