import AppKit
import MapKit
import SwiftUI

/// A map with a pin you can actually grab.
///
/// SwiftUI's `Map` cannot do this, by two separate routes:
///
/// - A pin drawn as an `Annotation` has its drags claimed by MapKit's own pan recogniser,
///   so the map slides instead of the pin.
/// - A pin drawn in an `.overlay` must be positioned by projecting its coordinate to a
///   screen point every frame. Driving that from `onMapCameraChange` feeds camera updates
///   back into the view that produces them; SwiftUI detects the cycle and resolves it by
///   dropping the update, so the overlay silently freezes at its first (empty) state.
///
/// `MKMapView` has supported draggable annotations natively for years, so this hands the
/// whole job to it and keeps SwiftUI out of the interaction path.
struct DeviceMapView: NSViewRepresentable {
    @Binding var coordinate: Coordinate

    /// Tints the pin green once the phone is actually reporting this spot.
    var isApplied: Bool

    /// Changing this value recentres the map on `coordinate`. It's a token rather than a
    /// flag so that recentring stays an explicit event and never fights the user's panning.
    var recenterToken: Int

    private static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false

        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate.clCoordinate
        annotation.title = "Simulated location"
        mapView.addAnnotation(annotation)

        mapView.setRegion(
            MKCoordinateRegion(center: coordinate.clCoordinate, span: Self.defaultSpan),
            animated: false
        )

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.delegate = context.coordinator
        // Without this the recogniser holds the mouse-down, and the pin's drag never starts.
        click.delaysPrimaryMouseButtonEvents = false
        mapView.addGestureRecognizer(click)

        context.coordinator.mapView = mapView
        context.coordinator.annotation = annotation

        // Some MapKit builds only begin a drag on an already-selected annotation, so the
        // pin is kept selected. The callout is off, so this has no visible cost.
        mapView.selectAnnotation(annotation, animated: false)

        Diagnostics.log("MKMapView created; pin at \(coordinate.formatted)")
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if let annotation = coordinator.annotation,
           !coordinator.isDragging,
           Coordinate(annotation.coordinate) != coordinate {
            annotation.coordinate = coordinate.clCoordinate
        }

        coordinator.refreshTint()

        if coordinator.lastRecenterToken != recenterToken {
            coordinator.lastRecenterToken = recenterToken
            mapView.setRegion(
                MKCoordinateRegion(center: coordinate.clCoordinate, span: mapView.region.span),
                animated: true
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: DeviceMapView
        weak var mapView: MKMapView?
        var annotation: MKPointAnnotation?
        var isDragging = false
        var lastRecenterToken: Int

        private static let reuseIdentifier = "TeleportPin"

        init(parent: DeviceMapView) {
            self.parent = parent
            self.lastRecenterToken = parent.recenterToken
        }

        // MARK: - Annotation view

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: Self.reuseIdentifier)
                as? DraggablePinView)
                ?? DraggablePinView(annotation: annotation, reuseIdentifier: Self.reuseIdentifier)

            view.annotation = annotation
            view.isDraggable = true
            view.canShowCallout = false
            view.apply(tint: parent.isApplied ? .systemGreen : .controlAccentColor)

            Diagnostics.log(
                "pin view ready — draggable=\(view.isDraggable) "
                    + "image=\(view.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")"
            )
            return view
        }

        func refreshTint() {
            guard let mapView, let annotation,
                  let view = mapView.view(for: annotation) as? DraggablePinView else { return }
            view.apply(tint: parent.isApplied ? .systemGreen : .controlAccentColor)
        }

        // MARK: - Dragging

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            switch newState {
            case .starting:
                isDragging = true
                // MapKit expects the view to advance its own drag state.
                view.dragState = .dragging

            case .ending, .canceling:
                isDragging = false
                view.dragState = .none
                if let moved = view.annotation?.coordinate {
                    Diagnostics.log("pin dragged to \(moved.latitude), \(moved.longitude)")
                    parent.coordinate = Coordinate(moved)
                }
                if let annotation {
                    mapView.selectAnnotation(annotation, animated: false)
                }

            default:
                break
            }
        }

        // MARK: - Click to place

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let mapView else { return }
            let point = recognizer.location(in: mapView)
            let moved = mapView.convert(point, toCoordinateFrom: mapView)
            Diagnostics.log("map clicked -> \(moved.latitude), \(moved.longitude)")
            parent.coordinate = Coordinate(moved)

            if let annotation {
                mapView.selectAnnotation(annotation, animated: false)
            }
        }

        /// Clicks that land on the pin belong to the drag, not to click-to-place.
        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard let mapView, let annotation,
                  let pinView = mapView.view(for: annotation) else { return true }
            let point = mapView.convert(event.locationInWindow, from: nil)
            return !pinView.frame.contains(point)
        }
    }
}

/// The pin itself: an SF Symbol, draggable, with a grab cursor.
final class DraggablePinView: MKAnnotationView {
    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isDraggable = true
        canShowCallout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func apply(tint: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, tint]))

        image = NSImage(
            systemSymbolName: "mappin.circle.fill",
            accessibilityDescription: "Simulated location"
        )?.withSymbolConfiguration(configuration)
    }

    /// Gives the pointer an open hand over the pin, so it reads as grabbable.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // Cursor rects alone are unreliable inside a map view, which manages its own cursor,
    // so the pointer is also driven directly from enter/exit tracking.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
