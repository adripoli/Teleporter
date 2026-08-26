import AppKit
import Foundation
import Observation

/// Whether the backing CLI is available.
enum ToolState: Equatable {
    case checking
    case ready
    case missing
}

/// What the status strip is currently saying.
enum ActivityState: Equatable {
    case idle
    case working(String)
    case applied(Coordinate)
    case cleared
    case failed(message: String, recovery: String?, detail: String?)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: - Observed state

    private(set) var toolState: ToolState = .checking
    private(set) var devices: [IOSDevice] = []
    private(set) var activity: ActivityState = .idle

    /// The coordinate the pin sits on — not necessarily the one the phone is using.
    private(set) var markerCoordinate: Coordinate = .eiffelTower

    /// The coordinate last successfully pushed to the phone, if any.
    private(set) var appliedCoordinate: Coordinate?

    var selectedDeviceID: String?

    /// Free text mirrors of the marker, so a half-typed coordinate doesn't move the pin.
    var latitudeText: String = ""
    var longitudeText: String = ""

    // MARK: - Derived

    var selectedDevice: IOSDevice? {
        devices.first { $0.udid == selectedDeviceID }
    }

    var canApply: Bool {
        toolState == .ready && selectedDevice != nil && markerCoordinate.isValid && !activity.isWorking
    }

    var canClear: Bool {
        toolState == .ready && selectedDevice != nil && !activity.isWorking
    }

    /// True when the pin has been moved away from what the phone is actually reporting.
    var hasUnappliedChange: Bool {
        guard let appliedCoordinate else { return false }
        return appliedCoordinate != markerCoordinate
    }

    private var controller: DeviceController?
    private let defaults = UserDefaults.standard

    /// The live `simulate-location set` process. The phone stays moved for as long as
    /// this is held, so it outlives the call that started it.
    private var locationSession: ParkedProcess?

    init() {
        restoreLastCoordinate()
        syncTextFields()

        // Never unregistered: the model is created once and lives until the process
        // exits, and a `deinit` in a @MainActor type can't touch isolated state anyway.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endSession()
            }
        }
    }

    // MARK: - Lifecycle

    /// Locates the tool, loads devices, then keeps the device list fresh for the window's
    /// lifetime. Cancelled automatically when the hosting `.task` goes away.
    func bootstrap() async {
        locateTool()
        await refreshDevices()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { break }
            // Don't race a set/clear that's already talking to the device.
            if !activity.isWorking { await refreshDevices(quietly: true) }
        }
    }

    func locateTool() {
        if let executable = DeviceController.locate() {
            controller = DeviceController(executable: executable)
            toolState = .ready
        } else {
            controller = nil
            toolState = .missing
        }
    }

    // MARK: - Devices

    func refreshDevices(quietly: Bool = false) async {
        guard let controller else { return }
        do {
            let found = try await controller.listDevices()
            devices = found

            // Keep the current pick if it's still plugged in; otherwise fall back.
            if let selectedDeviceID, found.contains(where: { $0.udid == selectedDeviceID }) {
                // still valid
            } else {
                selectedDeviceID = found.first?.udid
            }
        } catch {
            if !quietly { report(error) }
        }
    }

    // MARK: - Marker

    func moveMarker(to coordinate: Coordinate) {
        guard coordinate.isValid else { return }
        markerCoordinate = coordinate
        syncTextFields()
        // A stale success banner next to a moved pin reads as if the phone followed along.
        if case .applied = activity, hasUnappliedChange { activity = .idle }
    }

    /// Applies whatever is in the text fields, returning the parsed coordinate on success.
    @discardableResult
    func commitTextFields() -> Coordinate? {
        guard let latitude = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(longitudeText.trimmingCharacters(in: .whitespaces)) else {
            syncTextFields()
            return nil
        }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else {
            syncTextFields()
            return nil
        }
        moveMarker(to: coordinate)
        return coordinate
    }

    private func syncTextFields() {
        latitudeText = String(format: "%.6f", markerCoordinate.latitude)
        longitudeText = String(format: "%.6f", markerCoordinate.longitude)
    }

    // MARK: - Actions

    func applyLocation() async {
        guard let controller, let device = selectedDevice else {
            report(DeviceError.noDeviceSelected)
            return
        }
        let coordinate = markerCoordinate
        guard coordinate.isValid else { return }

        do {
            try await ensureDeveloperImage(controller: controller, udid: device.udid)

            activity = .working("Setting location…")

            // Retire the previous session first. Two sessions open at once means the one
            // that ends last decides where the phone thinks it is.
            endSession()

            locationSession = try await controller.startLocationSession(coordinate, udid: device.udid)

            appliedCoordinate = coordinate
            activity = .applied(coordinate)
            persist(coordinate)
        } catch {
            report(error)
        }
    }

    func clearLocation() async {
        guard let controller, let device = selectedDevice else {
            report(DeviceError.noDeviceSelected)
            return
        }
        do {
            activity = .working("Clearing…")
            endSession()
            try await controller.clearLocation(udid: device.udid)
            appliedCoordinate = nil
            activity = .cleared
        } catch {
            report(error)
        }
    }

    /// Ends the running simulation session, if any.
    ///
    /// macOS doesn't reap orphaned children, so skipping this would leave a
    /// pymobiledevice3 process holding the phone's location after the app is gone.
    func endSession() {
        guard let locationSession else { return }
        Diagnostics.log("ending location session")
        locationSession.terminate()
        self.locationSession = nil
    }

    /// Mounts the DDI on demand. Checking first keeps the common case to one fast call.
    private func ensureDeveloperImage(controller: DeviceController, udid: String) async throws {
        activity = .working("Checking developer image…")
        if try await controller.isDeveloperImageMounted(udid: udid) { return }

        activity = .working("Mounting developer image…")
        try await controller.mountDeveloperImage(udid: udid)
    }

    // MARK: - Status

    func dismissStatus() {
        activity = .idle
    }

    private func report(_ error: Error) {
        if let deviceError = error as? DeviceError {
            activity = .failed(
                message: deviceError.message,
                recovery: deviceError.recovery,
                detail: deviceError.detail
            )
        } else {
            activity = .failed(
                message: error.localizedDescription,
                recovery: nil,
                detail: nil
            )
        }
    }

    // MARK: - Persistence

    private enum DefaultsKey {
        static let latitude = "lastLatitude"
        static let longitude = "lastLongitude"
    }

    private func persist(_ coordinate: Coordinate) {
        defaults.set(coordinate.latitude, forKey: DefaultsKey.latitude)
        defaults.set(coordinate.longitude, forKey: DefaultsKey.longitude)
    }

    private func restoreLastCoordinate() {
        guard defaults.object(forKey: DefaultsKey.latitude) != nil,
              defaults.object(forKey: DefaultsKey.longitude) != nil else { return }
        let restored = Coordinate(
            latitude: defaults.double(forKey: DefaultsKey.latitude),
            longitude: defaults.double(forKey: DefaultsKey.longitude)
        )
        if restored.isValid { markerCoordinate = restored }
    }
}
