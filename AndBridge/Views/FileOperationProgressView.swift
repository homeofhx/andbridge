import AppKit
import SwiftUI

struct FileOperationProgressView: View {
    let message: String
    let transferProgress: FileTransferProgress?
    let canCancel: Bool
    let isCancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message).font(.headline).lineLimit(2)

            if let progress = transferProgress {
                DeterminateProgressBar(value: progress.fractionCompleted).frame(height: 16)

                HStack {
                    Text("\(Int(progress.fractionCompleted * 100))%")
                    Spacer()
                    Text(sizeDescription(for: progress))
                }.font(.caption).foregroundColor(.secondary)

                Text(fileDescription(for: progress)).font(.caption).foregroundColor(.secondary)
            } else {
                IndeterminateProgressBar().frame(height: 16)
            }

            Text("Keep the Android device connected!").font(.caption).foregroundColor(.secondary)

            if canCancel {
                HStack {
                    Spacer()
                    Button(isCancelling ? "Cancelling..." : "Cancel", action: onCancel).disabled(isCancelling)
                }
            }
        }.padding(22).frame(width: 380)
    }

    private func sizeDescription(for progress: FileTransferProgress) -> String {
        guard progress.totalFiles > 0 || progress.totalBytes > 0 else { return "Calculating size..." }
        return "\(formattedBytes(progress.transferredBytes)) of \(formattedBytes(progress.totalBytes))"
    }

    private func fileDescription(for progress: FileTransferProgress) -> String {
        guard progress.totalFiles > 0 else { return "Preparing file list..." }
        let noun = progress.totalFiles == 1 ? "file" : "files"
        return "\(progress.completedFiles) of \(progress.totalFiles) \(noun)"
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

private struct DeterminateProgressBar: NSViewRepresentable {
    let value: Double

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.doubleValue = min(1, max(0, value))
    }
}

private struct IndeterminateProgressBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.usesThreadedAnimation = true
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.startAnimation(nil)
    }
}
