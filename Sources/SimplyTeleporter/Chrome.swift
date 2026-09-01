import Foundation
import TeleportCore

/// Boxes, rules, and status lines — everything that frames content.
///
/// Panels are laid out from the *plain* text and colourised afterwards, because ANSI
/// sequences count as zero columns and padding computed on the coloured string would
/// tear the right-hand border off every box.
enum Chrome {
    private static let minimumPanelWidth = 48
    private static let maximumPanelWidth = 78

    // MARK: - Small parts

    static func note(_ symbol: String, _ text: String, _ tint: RGB) {
        Term.line(" " + Term.paint(symbol, tint, bold: true) + " " + Term.paint(text, Ink.bone))
    }

    static func hint(_ text: String) {
        Term.line("   " + Term.paint(text, Ink.slate))
    }

    static func rule() {
        let width = min(Term.width - 2, maximumPanelWidth)
        Term.line(" " + Term.gradient(
            String(repeating: "─", count: max(width, 10)),
            from: Ink.violet.dimmed(0.55),
            to: Ink.cyan.dimmed(0.55)
        ))
    }

    // MARK: - Panels

    /// A titled box of label/value pairs.
    static func panel(
        title: String,
        accent: RGB,
        entries: [(String, String)],
        footer: String? = nil
    ) {
        let labelWidth = entries.map(\.0.count).max() ?? 0
        let bodyWidths = entries.map { labelWidth + 2 + $0.1.count }
        let needed = max(
            (bodyWidths.max() ?? 0) + 6,
            title.count + 8,
            (footer?.count ?? 0) + 6
        )
        let width = min(max(needed, minimumPanelWidth), min(maximumPanelWidth, max(Term.width - 2, minimumPanelWidth)))
        let border = accent.dimmed(0.7)

        // ╭─ TITLE ─────╮
        let headLead = "╭─ "
        let headTail = String(repeating: "─", count: max(width - headLead.count - title.count - 2, 1)) + "╮"
        Term.line(
            " " + Term.paint(headLead, border)
                + Term.paint(title, accent, bold: true)
                + Term.paint(" " + headTail, border)
        )

        for (label, value) in entries {
            let padded = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            for (index, chunk) in wrap(value, to: width - labelWidth - 8).enumerated() {
                let key = index == 0 ? padded : String(repeating: " ", count: labelWidth)
                let content = "  \(key)  \(chunk)"
                Term.line(
                    " " + Term.paint("│", border)
                        + Term.paint("  \(key)  ", Ink.slate)
                        + Term.paint(chunk, Ink.bone)
                        + String(repeating: " ", count: max(width - 2 - content.count, 0))
                        + Term.paint("│", border)
                )
            }
        }

        if let footer {
            let content = "  " + footer
            Term.line(
                " " + Term.paint("│", border)
                    + Term.paint(content, accent)
                    + String(repeating: " ", count: max(width - 2 - content.count, 0))
                    + Term.paint("│", border)
            )
        }

        Term.line(" " + Term.paint("╰" + String(repeating: "─", count: width - 2) + "╯", border))
    }

    /// The landing card, printed after the phone has actually moved.
    static func arrival(coordinate: Coordinate, device: IOSDevice) {
        Term.line()
        panel(
            title: "ARRIVED",
            accent: Ink.mint,
            entries: [
                ("latitude", String(format: "%.6f° %@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S")),
                ("longitude", String(format: "%.6f° %@", abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")),
                ("device", "\(device.name) · \(device.modelLabel)"),
            ],
            footer: "holding — the phone stays here until you clear or quit"
        )
        Term.line()
    }

    /// Renders any error, pulling the recovery advice out of `DeviceError` where we have it.
    static func failure(_ error: Error) {
        var entries: [(String, String)] = []
        let message: String

        if let deviceError = error as? DeviceError {
            message = deviceError.message
            if let recovery = deviceError.recovery { entries.append(("fix", recovery)) }
            if let detail = deviceError.detail { entries.append(("detail", detail)) }
        } else {
            message = error.localizedDescription
        }

        Term.line()
        panel(
            title: "STUCK",
            accent: Ink.coral,
            entries: [("what", message)] + entries
        )
        Term.line()
    }

    // MARK: - Help

    static func help() {
        Term.line()
        panel(
            title: "COMMANDS",
            accent: Ink.violet,
            entries: [
                ("40,32", "teleport — latitude first, then longitude"),
                ("clear", "stop simulating and hand location back to the phone"),
                ("status", "where the phone thinks it is right now"),
                ("devices", "rescan USB and pick a different iPhone"),
                ("help", "this list"),
                ("quit", "release the location and exit  (Ctrl+C works too)"),
            ]
        )
        Term.line()
    }

    // MARK: - Internals

    /// Word-wraps on whitespace, breaking a single over-long word only as a last resort.
    private static func wrap(_ text: String, to width: Int) -> [String] {
        let width = max(width, 12)
        guard text.count > width else { return [text] }

        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= width {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                var remainder = Substring(word)
                while remainder.count > width {
                    lines.append(String(remainder.prefix(width)))
                    remainder = remainder.dropFirst(width)
                }
                current = String(remainder)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
