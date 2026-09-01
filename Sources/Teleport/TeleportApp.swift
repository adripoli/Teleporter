import SwiftUI
import TeleportCore

@main
struct TeleportApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Teleport", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            // Nothing here creates or opens documents.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Device") {
                Button("Set Location") {
                    Task { await model.applyLocation() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canApply)

                Button("Reset to Real GPS") {
                    Task { await model.clearLocation() }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canClear)

                Divider()

                Button("Refresh Devices") {
                    Task { await model.refreshDevices() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
