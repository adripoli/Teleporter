import SwiftUI
import TeleportCore

/// The floating pin button in the bottom-right corner.
///
/// It doubles as the app's status light: because the controls live inside a popover that
/// is usually closed, the button itself has to show whether the phone is currently being
/// spoofed, whether there's an unsent change, and whether the last attempt failed.
struct LocationButton: View {
    @Environment(AppModel.self) private var model

    /// Forwarded to the popover so typed coordinates pull the map camera along.
    let onCoordinateCommitted: (Coordinate) -> Void

    @State private var isShowingControls = false

    private static let diameter: CGFloat = 54

    var body: some View {
        Button {
            isShowingControls.toggle()
        } label: {
            symbol
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .overlay {
            Circle()
                .strokeBorder(tint.opacity(0.55), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .animation(.snappy(duration: 0.25), value: tint)
        .help(helpText)
        .accessibilityLabel("Simulated location controls")
        .popover(isPresented: $isShowingControls, arrowEdge: .top) {
            LocationPopover(onCoordinateCommitted: onCoordinateCommitted)
                .environment(model)
        }
    }

    @ViewBuilder
    private var symbol: some View {
        if model.activity.isWorking {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var symbolName: String {
        switch model.activity {
        case .failed:
            "exclamationmark.triangle.fill"
        case .applied where !model.hasUnappliedChange:
            "mappin.circle.fill"
        default:
            "mappin.and.ellipse"
        }
    }

    private var tint: Color {
        switch model.activity {
        case .failed:
            .orange
        case .applied where !model.hasUnappliedChange:
            .green
        case .cleared, .idle:
            .secondary
        default:
            .accentColor
        }
    }

    private var helpText: String {
        switch model.activity {
        case .working(let message):
            message
        case .applied where model.hasUnappliedChange:
            "Pin moved — click to send it"
        case .applied(let coordinate):
            "iPhone is at \(coordinate.formatted)"
        case .cleared:
            "Using the real GPS — click to set a location"
        case .failed(let message, _, _):
            message
        case .idle:
            "Click to set the simulated location"
        }
    }
}
