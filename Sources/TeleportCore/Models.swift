import CoreLocation
import Foundation

/// A latitude/longitude pair.
///
/// Deliberately not `CLLocationCoordinate2D`: this crosses isolation boundaries into the
/// process layer, and a plain `Sendable`/`Hashable` value keeps that free of ceremony.
public struct Coordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ clCoordinate: CLLocationCoordinate2D) {
        self.init(latitude: clCoordinate.latitude, longitude: clCoordinate.longitude)
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90.0...90.0).contains(latitude)
            && (-180.0...180.0).contains(longitude)
    }

    /// Six decimal places is roughly 10 cm — well past what the device does anything with.
    public var formatted: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    public static let eiffelTower = Coordinate(latitude: 48.858370, longitude: 2.294481)
}

/// A device as reported by `pymobiledevice3 usbmux list`.
public struct IOSDevice: Identifiable, Hashable, Sendable, Decodable {
    public let udid: String
    public let name: String
    public let productType: String
    public let productVersion: String
    public let connectionType: String

    public var id: String { udid }

    enum CodingKeys: String, CodingKey {
        case udid = "UniqueDeviceID"
        case name = "DeviceName"
        case productType = "ProductType"
        case productVersion = "ProductVersion"
        case connectionType = "ConnectionType"
    }

    /// `iPhone14,5` → `iPhone 13`-ish. The model table isn't worth carrying, so fall back
    /// to the raw identifier rather than guessing wrong.
    public var modelLabel: String {
        Self.knownModels[productType] ?? productType
    }

    public var menuLabel: String { "\(name) — iOS \(productVersion)" }

    private static let knownModels: [String: String] = [
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
    ]
}

/// A failure from the device tooling, translated into something worth showing a person.
public struct DeviceError: LocalizedError, Sendable {
    public let message: String
    public let recovery: String?
    public let detail: String?

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recovery }

    public init(message: String, recovery: String? = nil, detail: String? = nil) {
        self.message = message
        self.recovery = recovery
        self.detail = detail
    }

    public static let toolMissing = DeviceError(
        message: "pymobiledevice3 isn't installed.",
        recovery: "Install it with: pipx install pymobiledevice3"
    )

    public static let noDeviceSelected = DeviceError(
        message: "No iPhone selected.",
        recovery: "Connect your iPhone over USB and pick it in the toolbar."
    )

    /// Whether a finished command actually failed.
    ///
    /// Exit status alone isn't trustworthy here: pymobiledevice3 has paths that report a
    /// hard failure on stderr and still exit 0, so the streams have to be inspected too.
    public static func indicatesFailure(_ result: CommandResult) -> Bool {
        if !result.succeeded { return true }

        let stderr = result.standardError
        let failureTokens = [
            "Traceback",
            "Exception",
            "Apple removed this service",
            "ERROR",
            "error:",
        ]
        return failureTokens.contains { stderr.contains($0) }
    }

    /// Maps a failed command onto a specific cause where we recognise one.
    ///
    /// pymobiledevice3 renders tracebacks through `rich`, so the useful line is usually the
    /// last one outside the box-drawing frame.
    public static func from(_ result: CommandResult) -> DeviceError {
        let combined = result.standardError + "\n" + result.standardOutput

        if combined.contains("DeviceLocked") {
            return DeviceError(
                message: "Your iPhone is locked.",
                recovery: "Unlock it, leave it on the Home Screen, and try again.",
                detail: lastMeaningfulLine(combined)
            )
        }
        if combined.contains("PasswordProtected") || combined.localizedCaseInsensitiveContains("trust") {
            return DeviceError(
                message: "This Mac isn't trusted by the iPhone.",
                recovery: "Unlock the iPhone and tap Trust when prompted.",
                detail: lastMeaningfulLine(combined)
            )
        }
        if combined.contains("DeveloperModeDisabled") || combined.localizedCaseInsensitiveContains("developer mode") {
            return DeviceError(
                message: "Developer Mode is off on the iPhone.",
                recovery: "Enable Settings › Privacy & Security › Developer Mode, then restart the phone.",
                detail: lastMeaningfulLine(combined)
            )
        }
        if combined.contains("NoDeviceConnectedError") || combined.contains("No device found") {
            return DeviceError(
                message: "The iPhone disconnected.",
                recovery: "Reconnect the cable and hit refresh.",
                detail: lastMeaningfulLine(combined)
            )
        }
        if combined.contains("InvalidServiceError") || combined.contains("DvtDirListError") {
            return DeviceError(
                message: "The developer disk image isn't available.",
                recovery: "Unlock the iPhone and try again — Teleport will mount it.",
                detail: lastMeaningfulLine(combined)
            )
        }

        return DeviceError(
            message: "The command failed (exit code \(result.exitCode)).",
            recovery: nil,
            detail: lastMeaningfulLine(combined)
        )
    }

    /// Pulls the last line that isn't `rich` frame decoration or whitespace.
    private static func lastMeaningfulLine(_ text: String) -> String? {
        let frameCharacters = CharacterSet(charactersIn: "│╭╰╮╯─━┃┏┓┗┛ \t")
        let candidate = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { line in
                guard !line.isEmpty else { return false }
                return !line.unicodeScalars.allSatisfy { frameCharacters.contains($0) }
                    && !line.hasPrefix("│")
                    && !line.hasPrefix("╭")
                    && !line.hasPrefix("╰")
            }
        return candidate
    }
}
