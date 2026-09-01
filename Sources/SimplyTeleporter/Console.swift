import Darwin
import Foundation
import TeleportCore

/// The whole terminal front end: banner, device pick, then a prompt that takes
/// `latitude,longitude` and moves the phone there.
@MainActor
final class Console {
    private var controller: DeviceController?
    private var devices: [IOSDevice] = []
    private var device: IOSDevice?
    private var applied: Coordinate?

    /// Devices whose developer disk image we've already confirmed this run, so repeat
    /// teleports skip a round trip to the phone.
    private var imageConfirmed: Set<String> = []

    /// Signal sources stop firing the moment they're deallocated.
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - Entry point

    func run(arguments: [String]) async {
        installSignalHandlers()

        if arguments.contains("--help") || arguments.contains("-h") {
            Chrome.help()
            return
        }

        await Banner.show()

        guard let executable = DeviceController.locate() else {
            Chrome.failure(DeviceError.toolMissing)
            shutdown(code: 1)
        }
        controller = DeviceController(executable: executable)
        Chrome.note("◆", "pymobiledevice3 · \(executable.path)", Ink.violet)

        await refreshDevices()

        // One-shot: `simplyteleporter 40,32` applies and then parks until Ctrl+C, which
        // is what you want from a script or a second terminal tab.
        let request = arguments.joined(separator: " ")
        if !request.isEmpty {
            guard let coordinate = Coordinate(parsing: request) else {
                reject(request)
                shutdown(code: 1)
            }
            await teleport(to: coordinate)
            guard liveSession.isLive else { shutdown(code: 1) }
            Chrome.hint("holding — Ctrl+C releases the location")
            await parkForever()
        }

        Chrome.hint("type a coordinate like 48.8583,2.2945 — or help")
        Term.line()
        await repl()
        shutdown(code: 0)
    }

    // MARK: - Prompt loop

    private func repl() async {
        while true {
            Term.write(prompt())

            // Ctrl+D (or a closed pipe) reads as nil, and means the same as `quit`.
            guard let raw = readLine(strippingNewline: true) else {
                Term.line()
                return
            }
            let input = raw.trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty else { continue }

            switch input.lowercased() {
            case "help", "h", "?":
                Chrome.help()
            case "quit", "q", "exit":
                return
            case "clear", "c":
                await releaseLocation()
            case "status", "s":
                showStatus()
            case "devices", "d":
                await refreshDevices()
            default:
                if let coordinate = Coordinate(parsing: input) {
                    await teleport(to: coordinate)
                } else {
                    reject(input)
                }
            }
        }
    }

    /// A filled dot means a session is holding the phone somewhere right now.
    private func prompt() -> String {
        let indicator = liveSession.isLive
            ? Term.paint("●", Ink.mint, bold: true)
            : Term.paint("○", Ink.slate)
        return " " + indicator + " "
            + Term.gradient("teleport", from: Ink.violet, to: Ink.cyan, bold: true)
            + Term.paint(" ▸ ", Ink.magenta)
    }

    // MARK: - Actions

    private func teleport(to coordinate: Coordinate) async {
        guard let controller else {
            Chrome.failure(DeviceError.toolMissing)
            return
        }
        guard let device else {
            Chrome.failure(DeviceError.noDeviceSelected)
            return
        }
        guard coordinate.isValid else {
            rejectRange(coordinate)
            return
        }

        do {
            try await ensureDeveloperImage(controller: controller, udid: device.udid)

            // Retire the previous session *before* opening the next. Held both at once,
            // whichever ends last is the one that decides where the phone thinks it is.
            liveSession.end()

            let session = try await Effects.withActivity(
                "locking on \(coordinate.formatted)",
                style: .beam
            ) {
                try await controller.startLocationSession(coordinate, udid: device.udid)
            }

            liveSession.adopt(session)
            applied = coordinate

            await Effects.flash("teleported")
            Chrome.arrival(coordinate: coordinate, device: device)
        } catch {
            Chrome.failure(error)
        }
    }

    private func releaseLocation() async {
        guard let controller, let device else {
            Chrome.failure(DeviceError.noDeviceSelected)
            return
        }
        do {
            liveSession.end()
            try await Effects.withActivity("handing location back") {
                try await controller.clearLocation(udid: device.udid)
            }
            applied = nil
            Chrome.note("○", "released — the phone is back on its own GPS", Ink.amber)
        } catch {
            Chrome.failure(error)
        }
    }

    /// The DVT services behind location simulation only exist once the personalised
    /// developer disk image is mounted. It survives reboots, so this is usually a no-op.
    private func ensureDeveloperImage(controller: DeviceController, udid: String) async throws {
        guard !imageConfirmed.contains(udid) else { return }

        let mounted = try await Effects.withActivity("checking developer disk image") {
            try await controller.isDeveloperImageMounted(udid: udid)
        }
        if !mounted {
            try await Effects.withActivity("mounting developer disk image — this can take a minute") {
                try await controller.mountDeveloperImage(udid: udid)
            }
        }
        imageConfirmed.insert(udid)
    }

    // MARK: - Devices

    private func refreshDevices() async {
        guard let controller else { return }

        do {
            devices = try await Effects.withActivity("scanning USB") {
                try await controller.listDevices()
            }
        } catch {
            Chrome.failure(error)
            return
        }

        guard !devices.isEmpty else {
            device = nil
            Chrome.note("◇", "no iPhone on USB", Ink.amber)
            Chrome.hint("plug one in, unlock it, then type: devices")
            return
        }

        // Keep the current pick if it's still plugged in.
        if let device, devices.contains(where: { $0.udid == device.udid }) {
            // still valid
        } else {
            device = devices.count == 1 ? devices[0] : chooseDevice()
        }

        if let device {
            Chrome.note("◆", "\(device.name) · \(device.modelLabel) · iOS \(device.productVersion)", Ink.mint)
        }
    }

    private func chooseDevice() -> IOSDevice {
        Term.line()
        Chrome.note("◆", "\(devices.count) devices connected", Ink.cyan)
        for (index, candidate) in devices.enumerated() {
            Term.line(
                "   " + Term.paint("\(index + 1)", Ink.cyan, bold: true)
                    + Term.paint(" · ", Ink.slate)
                    + Term.paint("\(candidate.name) · \(candidate.modelLabel) · iOS \(candidate.productVersion)", Ink.bone)
            )
        }

        while true {
            Term.write(" " + Term.paint("pick 1–\(devices.count) ▸ ", Ink.magenta))
            guard let answer = readLine(strippingNewline: true) else { return devices[0] }

            let trimmed = answer.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return devices[0] }
            if let choice = Int(trimmed), devices.indices.contains(choice - 1) {
                return devices[choice - 1]
            }
            Chrome.hint("that isn't one of them")
        }
    }

    // MARK: - Status

    private func showStatus() {
        var entries: [(String, String)] = [
            ("device", device.map { "\($0.name) · \($0.modelLabel)" } ?? "none connected"),
        ]

        if let applied {
            entries.append(("latitude", String(format: "%+.6f°", applied.latitude)))
            entries.append(("longitude", String(format: "%+.6f°", applied.longitude)))
            entries.append((
                "session",
                liveSession.isLive ? "live — holding" : "dropped — teleport again to restore"
            ))
        } else {
            entries.append(("location", "not simulated — the phone is using its own GPS"))
        }

        Term.line()
        Chrome.panel(title: "STATUS", accent: Ink.cyan, entries: entries)
        Term.line()
    }

    // MARK: - Bad input

    private func reject(_ input: String) {
        Term.line()
        Chrome.note("×", "\"\(input)\" isn't a coordinate or a command", Ink.coral)
        Chrome.hint("coordinates look like 40,32 — latitude first · help for the rest")
        Term.line()
    }

    private func rejectRange(_ coordinate: Coordinate) {
        Term.line()
        Chrome.note("×", "that's off the map", Ink.coral)
        let swapped = Coordinate(latitude: coordinate.longitude, longitude: coordinate.latitude)
        if swapped.isValid {
            Chrome.hint("latitude comes first — did you mean \(swapped.formatted)?")
        } else {
            Chrome.hint("latitude runs −90 to 90, longitude −180 to 180")
        }
        Term.line()
    }

    // MARK: - Lifecycle

    /// Ctrl+C has to end the session, not just kill us: the child process would otherwise
    /// outlive the terminal and keep the phone teleported.
    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            // The default disposition would kill us before the source ever fires.
            signal(number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                // Deliberately off the main actor: the prompt is usually parked inside a
                // blocking `readLine()`, so nothing main-isolated would ever get to run.
                liveSession.end()
                Term.showCursor()
                Term.line()
                Term.line(" " + Term.paint("released · back to reality", Ink.slate))
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func parkForever() async -> Never {
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func shutdown(code: Int32) -> Never {
        liveSession.end()
        Term.showCursor()
        Term.line()
        Term.line(" " + Term.paint("released · back to reality", Ink.slate))
        Term.line()
        exit(code)
    }
}

// MARK: - Input parsing

extension Coordinate {
    /// Reads `40,32` — and the shapes people actually type around it: `40, 32`,
    /// `40 32`, `(40, 32)`, `40.7°, -74.0°`.
    init?(parsing input: String) {
        let normalised = input
            .replacingOccurrences(of: "°", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ";", with: ",")

        let fields = normalised.split { $0 == "," || $0.isWhitespace }
        guard fields.count == 2,
              let latitude = Double(fields[0]),
              let longitude = Double(fields[1]) else { return nil }

        self.init(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Main

@main
@MainActor
struct SimplyTeleporter {
    static func main() async {
        await Console().run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
}
