import AppKit
import MapKit
import SwiftUI
import TeleportCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    /// Bumped whenever the map should jump to the pin. See `DeviceMapView.recenterToken`.
    @State private var recenterToken = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DeviceMapView(
                coordinate: Binding(
                    get: { model.markerCoordinate },
                    set: { model.moveMarker(to: $0) }
                ),
                isApplied: model.appliedCoordinate == model.markerCoordinate,
                recenterToken: recenterToken
            )

            LocationButton(onCoordinateCommitted: { _ in
                // Typed coordinates can land off-screen; bring the map with them.
                recenterToken += 1
            })
            .padding(22)
        }
        .toolbar { toolbarContent }
        .navigationTitle("Teleport")
        .sheet(isPresented: isMissingTool) {
            SetupSheet()
        }
        .task {
            await model.bootstrap()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            devicePicker
        }
        ToolbarItem {
            Button {
                recenterToken += 1
            } label: {
                Label("Center on Pin", systemImage: "scope")
            }
            .help("Center the map on the pin")
        }
        ToolbarItem {
            Button {
                Task { await model.refreshDevices() }
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
            .disabled(model.toolState != .ready)
            .help("Look for connected iPhones again")
        }
    }

    private var devicePicker: some View {
        @Bindable var model = model

        return Picker("Device", selection: $model.selectedDeviceID) {
            if model.devices.isEmpty {
                Text("No iPhone connected").tag(String?.none)
            }
            ForEach(model.devices) { device in
                Text(device.menuLabel).tag(String?.some(device.udid))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 210)
        .disabled(model.devices.isEmpty)
    }

    private var isMissingTool: Binding<Bool> {
        Binding(get: { model.toolState == .missing }, set: { _ in })
    }
}
