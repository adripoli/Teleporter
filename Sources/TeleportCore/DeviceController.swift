import Foundation

/// Wraps the `pymobiledevice3` CLI.
///
/// Every call goes through `--native`, which piggybacks Apple's own `remoted` tunnel via
/// `remotepairingd`. That's what keeps this root-free on iOS 17+ and lets it coexist with
/// Xcode and `devicectl` instead of fighting them for the tunnel.
public struct DeviceController: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Printed by `simulate-location set` once the location has been applied and it's
    /// parked waiting for a signal. Its appearance is our proof the work succeeded.
    private static let parkedMarker = "Press Ctrl+C"

    // MARK: - Locating the tool

    /// pipx puts its shims in `~/.local/bin`; Homebrew uses one of the two prefixes.
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/pymobiledevice3"),
            URL(filePath: "/usr/local/bin/pymobiledevice3"),
            URL(filePath: "/opt/homebrew/bin/pymobiledevice3"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Keep `rich` from wrapping output in ANSI colour we'd only have to strip back out.
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        // Essential, not cosmetic: Python block-buffers stdout when it isn't a TTY, which
        // would trap the "parked" marker in a buffer we never see.
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func run(_ arguments: [String], timeout: Duration = .seconds(120)) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    private func runExpectingSuccess(_ arguments: [String], timeout: Duration = .seconds(120)) async throws {
        let result = try await run(arguments, timeout: timeout)
        guard !DeviceError.indicatesFailure(result) else { throw DeviceError.from(result) }
    }

    // MARK: - Devices

    public func listDevices() async throws -> [IOSDevice] {
        let result = try await run(["usbmux", "list"], timeout: .seconds(30))
        guard !DeviceError.indicatesFailure(result) else { throw DeviceError.from(result) }

        guard let json = extractJSONArray(from: result.standardOutput),
              let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([IOSDevice].self, from: data)) ?? []
    }

    // MARK: - Developer disk image

    /// The DVT services that back location simulation only exist once the personalised
    /// developer disk image is mounted. It survives reboots, so this is usually a no-op.
    public func isDeveloperImageMounted(udid: String) async throws -> Bool {
        let result = try await run(["mounter", "list", "--udid", udid], timeout: .seconds(45))
        guard !DeviceError.indicatesFailure(result) else { throw DeviceError.from(result) }

        guard let json = extractJSONArray(from: result.standardOutput) else { return false }
        return json != "[]"
    }

    /// Fetches and mounts the image for this exact build. Needs the phone unlocked, and
    /// makes a TSS request to Apple, so it gets a long leash.
    public func mountDeveloperImage(udid: String) async throws {
        try await runExpectingSuccess(["mounter", "auto-mount", "--udid", udid], timeout: .seconds(300))
    }

    // MARK: - Location

    /// Starts a simulation session and returns once the phone has been moved.
    ///
    /// The returned handle owns the session: the location holds for as long as it lives,
    /// and the caller must `terminate()` it to end the simulation or replace it.
    public func startLocationSession(_ coordinate: Coordinate, udid: String) async throws -> ParkedProcess {
        do {
            return try await ProcessRunner.startParked(
                executable: executable,
                arguments: [
                    "developer", "dvt", "simulate-location", "set",
                    "--native", "--udid", udid,
                    // Separator matters: negative longitudes look like options otherwise.
                    "--",
                    String(coordinate.latitude), String(coordinate.longitude),
                ],
                environment: environment,
                marker: Self.parkedMarker,
                timeout: .seconds(90)
            )
        } catch CommandError.exitedBeforeReady(let result) {
            throw DeviceError.from(result)
        }
    }

    public func clearLocation(udid: String) async throws {
        try await runExpectingSuccess(
            ["developer", "dvt", "simulate-location", "clear", "--native", "--udid", udid],
            timeout: .seconds(90)
        )
    }

    // MARK: - Helpers

    /// Isolates the JSON array from output that may carry log lines above it.
    private func extractJSONArray(from output: String) -> String? {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start < end else { return nil }
        return String(output[start...end])
    }
}
