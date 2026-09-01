import SwiftUI
import TeleportCore

/// The controls behind the corner pin button: what's happening, where the pin is, and the
/// two actions that actually touch the phone.
struct LocationPopover: View {
    @Environment(AppModel.self) private var model

    /// Called when typed coordinates should pull the map camera along with them.
    let onCoordinateCommitted: (Coordinate) -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case latitude, longitude
    }

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 14) {
            StatusRow()

            Divider().opacity(0.6)

            HStack(alignment: .bottom, spacing: 10) {
                coordinateField(title: "Latitude", text: $model.latitudeText, field: .latitude)
                coordinateField(title: "Longitude", text: $model.longitudeText, field: .longitude)
            }

            HStack(spacing: 10) {
                Button("Reset") {
                    Task { await model.clearLocation() }
                }
                .disabled(!model.canClear)
                .help("Hand control back to the phone's real GPS (⌘⌫)")

                Spacer(minLength: 4)

                Button {
                    commitFields()
                    Task { await model.applyLocation() }
                } label: {
                    Text(model.appliedCoordinate == nil ? "Set Location" : "Update")
                        .frame(minWidth: 84)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApply)
                .keyboardShortcut(.defaultAction)
                .help("Push this coordinate to the iPhone (⌘↩)")
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func coordinateField(title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .focused($focusedField, equals: field)
                .onSubmit(commitFields)
        }
    }

    /// Parses both fields together — a coordinate is only meaningful as a pair.
    private func commitFields() {
        if let coordinate = model.commitTextFields() {
            onCoordinateCommitted(coordinate)
        }
        focusedField = nil
    }
}

/// One line describing what the app is doing, or what went wrong.
private struct StatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.2), value: headline)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.activity {
        case .working:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18)
        case .applied where model.hasUnappliedChange:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.tint)
        case .applied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cleared:
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        switch model.activity {
        case .working(let message):
            message
        case .applied where model.hasUnappliedChange:
            "Pin moved — not sent yet"
        case .applied:
            "iPhone is here"
        case .cleared:
            "Back to real GPS"
        case .failed(let message, _, _):
            message
        case .idle:
            model.selectedDevice == nil ? "Waiting for an iPhone" : "Ready"
        }
    }

    private var detail: String? {
        switch model.activity {
        case .failed(_, let recovery, let commandDetail):
            recovery ?? commandDetail
        case .applied(let coordinate):
            coordinate.formatted
        case .idle where model.selectedDevice == nil:
            "Connect one over USB, unlocked, with Developer Mode on."
        case .idle:
            "Drag the pin or click the map, then press Set Location."
        default:
            nil
        }
    }
}
