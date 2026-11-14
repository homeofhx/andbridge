import SwiftUI

struct DeviceSidebar: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Devices").font(.headline)
                Spacer()
                if model.isRefreshing { LoadingIndicator().frame(width: 16, height: 16) }
                Button(action: model.refreshDevices) {
                    Image(nsImage: SystemIcons.refresh).frame(width: 16, height: 16)
                }.buttonStyle(PlainButtonStyle())
            }.padding(.horizontal, 12).frame(height: 44)

            Divider()

            if model.devices.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(nsImage: SystemIcons.disconnected).resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)
                        .opacity(0.55)
                    Text(model.isRefreshing ? "Looking for Android devices..." : "No Android devices").font(.headline)
                    Text("Connect Android device to this Mac with a USB cable, then set the Android device's USB mode to File Transfer (MTP).")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 18)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device,
                                      selected: device.id == model.selectedDeviceID,
                                      canRefresh: model.canRefreshFiles,
                                      action: { model.select(device) },
                                      refreshAction: model.refreshFiles)
                        }
                    }.padding(6)
                }
            }
        }.frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
    }
}

private struct DeviceRow: View {
    let device: MTPDevice
    let selected: Bool
    let canRefresh: Bool
    let action: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(nsImage: device.icon).resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                    Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                }.padding(.leading, 8).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(PlainButtonStyle())

            if selected {
                Button(action: refreshAction) {
                    Image(nsImage: SystemIcons.refresh).frame(width: 16, height: 16).padding(6)
                }.buttonStyle(PlainButtonStyle())
                    .disabled(!canRefresh)
                    .accessibility(label: Text("Refresh Files"))
                    .padding(.trailing, 4)
            }
        }.frame(height: 42)
            .foregroundColor(selected ? .white : .primary)
            .background(selected ? Color.accentColor : Color.clear)
            .cornerRadius(6)
    }
}
