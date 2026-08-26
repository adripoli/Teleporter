import Foundation

/// Opt-in stderr logging: `TELEPORT_DEBUG=1 ./Teleport.app/Contents/MacOS/Teleport`.
///
/// The pin is drawn by projecting a coordinate to a screen point, which can fail silently
/// and leave nothing on screen. This makes that failure observable instead of invisible.
enum Diagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["TELEPORT_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[teleport] \(message())\n".utf8))
    }
}
