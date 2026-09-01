import Foundation

/// The wordmark: five-row block letters under a letterspaced "simply", swept once by a
/// highlight so the thing announces itself before dropping into the prompt.
enum Banner {
    private static let rows = 5
    private static let glyphWidth = 5

    /// Only the letters the wordmark needs. A full font would be dead weight.
    private static let font: [Character: [String]] = [
        "T": ["█████", "  █  ", "  █  ", "  █  ", "  █  "],
        "E": ["█████", "█    ", "████ ", "█    ", "█████"],
        "L": ["█    ", "█    ", "█    ", "█    ", "█████"],
        "P": ["█████", "█   █", "█████", "█    ", "█    "],
        "O": ["█████", "█   █", "█   █", "█   █", "█████"],
        "R": ["█████", "█   █", "█████", "█  █ ", "█   █"],
        " ": ["     ", "     ", "     ", "     ", "     "],
    ]

    private static let word = "TELEPORTER"

    /// Block width plus the single-column gaps between glyphs.
    private static var wordWidth: Int {
        word.count * glyphWidth + (word.count - 1)
    }

    static func show() async {
        let terminalWidth = Term.width

        guard Term.isInteractive, terminalWidth >= wordWidth + 4 else {
            compact()
            return
        }

        let indent = String(repeating: " ", count: max((terminalWidth - wordWidth) / 2, 0))

        Term.line()
        Term.line(indent + spacedOut("simply"))

        // Reveal top-down, then sweep a highlight back across the finished block.
        Term.hideCursor()
        for row in 0..<rows {
            Term.line(indent + render(row: row, highlight: nil))
            try? await Task.sleep(for: .milliseconds(45))
        }

        for step in stride(from: -6.0, through: Double(wordWidth) + 6, by: 3.0) {
            Term.write("\u{1B}[\(rows)A")
            for row in 0..<rows {
                Term.clearLine()
                Term.line(indent + render(row: row, highlight: step))
            }
            try? await Task.sleep(for: .milliseconds(16))
        }

        Term.write("\u{1B}[\(rows)A")
        for row in 0..<rows {
            Term.clearLine()
            Term.line(indent + render(row: row, highlight: nil))
        }
        Term.showCursor()

        Term.line()
        Term.line(indent + Term.paint("latitude,longitude — and the phone is there", Ink.slate))
        Term.line()
    }

    /// Fallback for narrow windows, pipes, and `NO_COLOR`.
    private static func compact() {
        Term.line()
        Term.line("  " + Term.gradient("simply TELEPORTER", from: Ink.violet, to: Ink.cyan, bold: true))
        Term.line("  " + Term.paint("latitude,longitude — and the phone is there", Ink.slate))
        Term.line()
    }

    // MARK: - Rendering

    /// One row of the block word, gradient-tinted by column.
    ///
    /// `highlight` is a column position; cells near it are lifted toward white, which is
    /// what makes the sweep read as a shine rather than a colour change.
    private static func render(row: Int, highlight: Double?) -> String {
        var cells: [Character] = []
        for (index, letter) in word.enumerated() {
            if index > 0 { cells.append(" ") }
            cells.append(contentsOf: font[letter]![row])
        }

        guard Term.usesColor else { return String(cells) }

        let span = Double(max(cells.count - 1, 1))
        var out = Term.bold
        var lastColor: String?

        for (column, cell) in cells.enumerated() {
            guard cell != " " else {
                out.append(" ")
                continue
            }
            var shade = RGB.mix(Ink.violet, Ink.cyan, Double(column) / span)
            if let highlight {
                let distance = abs(Double(column) - highlight)
                if distance < 5 { shade = RGB.mix(shade, Ink.bone, 1 - distance / 5) }
            }
            let code = Term.color(shade)
            if code != lastColor {
                out += code
                lastColor = code
            }
            out.append(cell)
        }
        return out + Term.reset
    }

    private static func spacedOut(_ text: String) -> String {
        let letterspaced = text.map(String.init).joined(separator: " ")
        return Term.gradient(letterspaced, from: Ink.magenta, to: Ink.violet, bold: true)
    }
}
