import AppKit
import SwiftUI
import TeleportCore

/// Shown when `pymobiledevice3` isn't on disk. Without it the app has nothing to drive.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model

    private let installCommand = "pipx install pymobiledevice3"

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("One-time setup")
                    .font(.title2.bold())
                Text("Teleport talks to your iPhone through **pymobiledevice3**, which drives Apple's own developer services. Install it once, then come back here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                HStack {
                    Text(installCommand)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copyCommand()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                    }
                    .controlSize(.small)
                }
                .padding(4)
            }

            Text("No administrator password is required — Teleport uses macOS's built-in device tunnel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("Check Again") {
                    model.locateTool()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(installCommand, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}
