import Darwin
import Foundation

/// A colour in linear 0...255 space, kept as `Double` so gradients can interpolate
/// without rounding to mud at every step.
struct RGB: Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        return RGB(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t
        )
    }

    /// Scales toward black. Used for the trailing dim parts of the beam.
    func dimmed(_ factor: Double) -> RGB {
        RGB(r * factor, g * factor, b * factor)
    }
}

/// The palette. One place to retune the whole look.
enum Ink {
    static let violet = RGB(150, 90, 255)
    static let magenta = RGB(235, 80, 200)
    static let cyan = RGB(70, 225, 240)
    static let mint = RGB(90, 240, 170)
    static let amber = RGB(255, 185, 70)
    static let coral = RGB(255, 95, 105)
    static let slate = RGB(120, 130, 155)
    static let bone = RGB(232, 236, 245)
}

/// ANSI plumbing, degrading cleanly when stdout isn't a colour terminal.
enum Term {
    // MARK: - Capabilities

    static let isInteractive = isatty(STDOUT_FILENO) == 1

    static let usesColor: Bool = {
        guard isInteractive else { return false }
        let env = ProcessInfo.processInfo.environment
        if env["NO_COLOR"] != nil { return false }
        let term = env["TERM"] ?? ""
        return !term.isEmpty && term != "dumb"
    }()

    /// 24-bit colour where the terminal advertises it; the 6×6×6 cube everywhere else.
    private static let usesTrueColor: Bool = {
        let colorterm = ProcessInfo.processInfo.environment["COLORTERM"] ?? ""
        return colorterm.contains("truecolor") || colorterm.contains("24bit")
    }()

    /// Live terminal width, so panels and rules track a resized window.
    static var width: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"], let value = Int(columns) {
            return value
        }
        return 80
    }

    // MARK: - Escapes

    static let reset = escape("0m")
    static let bold = escape("1m")
    static let dim = escape("2m")
    static let italic = escape("3m")

    static func color(_ rgb: RGB) -> String {
        guard usesColor else { return "" }
        let r = clampByte(rgb.r), g = clampByte(rgb.g), b = clampByte(rgb.b)
        guard usesTrueColor else { return "\u{1B}[38;5;\(cubeIndex(r, g, b))m" }
        return "\u{1B}[38;2;\(r);\(g);\(b)m"
    }

    static func paint(_ text: String, _ rgb: RGB, bold: Bool = false) -> String {
        guard usesColor else { return text }
        return (bold ? self.bold : "") + color(rgb) + text + reset
    }

    /// Colours a string character by character along a gradient.
    ///
    /// `span` lets several calls share one continuous ramp: pass the width of the whole
    /// line and the offset of this fragment, and the seams disappear.
    static func gradient(
        _ text: String,
        from start: RGB,
        to end: RGB,
        bold: Bool = false,
        span: Int? = nil,
        offset: Int = 0
    ) -> String {
        let characters = Array(text)
        guard usesColor, !characters.isEmpty else { return text }

        let total = max((span ?? characters.count) - 1, 1)
        var out = bold ? self.bold : ""
        var lastColor: String?

        for (index, character) in characters.enumerated() {
            let shade = color(RGB.mix(start, end, Double(offset + index) / Double(total)))
            // Repeating an identical SGR sequence per character bloats the output and makes
            // slow terminals flicker; only emit it when it actually changes.
            if shade != lastColor {
                out += shade
                lastColor = shade
            }
            out.append(character)
        }
        return out + reset
    }

    // MARK: - Cursor and output

    static func hideCursor() { write(escape("?25l")) }
    static func showCursor() { write(escape("?25h")) }

    /// Wipes the current line and parks the cursor at its start.
    static func clearLine() { write("\r" + escape("2K")) }

    static func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }

    static func line(_ text: String = "") {
        write(text + "\n")
    }

    // MARK: - Internals

    private static func escape(_ body: String) -> String {
        usesColor ? "\u{1B}[" + body : ""
    }

    private static func clampByte(_ value: Double) -> Int {
        Int(min(max(value.rounded(), 0), 255))
    }

    /// Maps 24-bit colour onto xterm-256's colour cube (indices 16...231).
    private static func cubeIndex(_ r: Int, _ g: Int, _ b: Int) -> Int {
        func axis(_ value: Int) -> Int { Int((Double(value) / 255.0 * 5.0).rounded()) }
        return 16 + 36 * axis(r) + 6 * axis(g) + axis(b)
    }
}
