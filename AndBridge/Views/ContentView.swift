import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        HSplitView {
            DeviceSidebar(model: model)
            detailBody.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 780, minHeight: 500)
            .sheet(isPresented: fileOperationIsPresented) {
                if let message = model.activeFileOperation {
                    FileOperationProgressView(message: message,
                                              transferProgress: model.activeTransferProgress,
                                              canCancel: model.canCancelActiveFileOperation,
                                              isCancelling: model.isCancellingFileOperation,
                                              onCancel: model.cancelActiveFileOperation)
                }
            }
            .alert(isPresented: Binding(
                get: { model.transferErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.dismissTransferError() }
                })
            ) {
            Alert(title: Text("Copy Failed"),
                  message: Text(model.transferErrorMessage ?? "The copy operation couldn't be completed."),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var fileOperationIsPresented: Binding<Bool> {
        Binding(get: { model.activeFileOperation != nil },
                set: { _ in })
    }

    @ViewBuilder
    private var detailBody: some View {
        switch model.state {
        case .noDevice:
            placeholder(title: "Select an Android device in the sidebar",
                        message: "Connected Android devices will appear in the sidebar")
        case .loading where model.roots.isEmpty:
            placeholder(title: "Reading files...", message: "Do not unplug the Android device!")
        case .failed(let message) where model.roots.isEmpty:
            placeholder(title: "Couldn’t access the Android device!", message: message)
        case .ready where model.roots.isEmpty:
            placeholder(title: "No files found!",
                        message: "Check that USB settings on the Android device is set to File Transfer (MTP)")
        default:
            FileOutlineView(roots: model.roots,
                            actions: FileOutlineActions(loadChildren: model.loadChildren,
                                                        canMove: model.canMove,
                                                        move: model.move,
                                                        createFolder: model.createFolder,
                                                        copy: model.copy,
                                                        canPaste: model.canPaste,
                                                        paste: model.paste,
                                                        delete: model.delete,
                                                        importFiles: model.importFiles,
                                                        export: model.export))
        }
    }

    private func placeholder(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title).font(.title)
            Text(message).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
