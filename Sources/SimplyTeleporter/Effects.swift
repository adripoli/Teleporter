import Foundation

/// In-place animations that run *while* real work happens on the device.
///
/// Each animator owns its line: it hides the cursor on entry and, once cancelled, wipes
/// the line and restores the cursor before returning. Callers await that return before
/// printing anything else, otherwise a stray frame lands on top of the next message.
enum Effects {
    enum Style {
        /// A braille spinner for short, opaque waits.
        case spinner
        /// A sweeping beam for the teleport itself.
        case beam

        var frameInterval: Duration {
            switch self {
            case .spinner: .milliseconds(80)
            case .beam: .milliseconds(45)
            }
        }
    }

    /// Runs `work`, animating `label` for as long as it takes.
    ///
    /// Inheriting the caller's isolation via `#isolation` is what lets `work` touch the
    /// console's main-actor state: without it the closure would have to cross into this
    /// function's own isolation domain, which no coordinator closure could satisfy.
    @discardableResult
    static func withActivity<T>(
        _ label: String,
        style: Style = .spinner,
        isolation: isolated (any Actor)? = #isolation,
        work: () async throws -> T
    ) async throws -> T {
        guard Term.isInteractive else {
            Chrome.note("·", label + "…", Ink.slate)
            return try await work()
        }

        let animation = Task.detached { await animate(label: label, style: style) }
        do {
            let value = try await work()
            await settle(animation)
            return value
        } catch {
            await settle(animation)
            throw error
        }
    }

    /// A one-off flourish for a coordinate that has just landed.
    static func flash(_ text: String) async {
        guard Term.isInteractive, Term.usesColor else {
            Term.line("  " + text)
            return
        }
        for tint in [Ink.bone, Ink.mint, Ink.cyan] {
            Term.clearLine()
            Term.write("  " + Term.paint("✦ " + text, tint, bold: true))
            try? await Task.sleep(for: .milliseconds(70))
        }
        Term.line()
    }

    // MARK: - Internals

    /// Cancels an animator and waits for it to tidy its own line.
    private static func settle(_ animation: Task<Void, Never>) async {
        animation.cancel()
        await animation.value
    }

    private static func animate(label: String, style: Style) async {
        Term.hideCursor()
        var frame = 0
        while !Task.isCancelled {
            Term.clearLine()
            Term.write(render(label: label, style: style, frame: frame))
            // A cancelled sleep throws; the loop condition above turns that into an exit.
            try? await Task.sleep(for: style.frameInterval)
            frame += 1
        }
        Term.clearLine()
        Term.showCursor()
    }

    private static func render(label: String, style: Style, frame: Int) -> String {
        switch style {
        case .spinner:
            let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            let glyph = String(frames[frame % frames.count])
            // Cycle the tint with the spin so the whole thing breathes.
            let phase = (sin(Double(frame) / 4) + 1) / 2
            return " " + Term.paint(glyph, RGB.mix(Ink.violet, Ink.cyan, phase), bold: true)
                + " " + Term.paint(label + "…", Ink.slate)

        case .beam:
            return " " + beam(frame: frame) + " " + Term.paint(label + "…", Ink.slate)
        }
    }

    /// A gradient track with a bright band bouncing along it.
    private static func beam(frame: Int) -> String {
        let track = 22
        // Ping-pong: fold a 2×-length ramp back on itself.
        let cycle = frame % (track * 2 - 2)
        let head = Double(cycle < track ? cycle : (track * 2 - 2) - cycle)

        var out = Term.paint("⟨", Ink.slate)
        for column in 0..<track {
            let base = RGB.mix(Ink.violet, Ink.cyan, Double(column) / Double(track - 1))
            let distance = abs(Double(column) - head)
            if distance < 1 {
                out += Term.paint("━", RGB.mix(base, Ink.bone, 0.8), bold: true)
            } else if distance < 3 {
                out += Term.paint("━", RGB.mix(base, Ink.bone, (3 - distance) / 6))
            } else {
                out += Term.paint("─", base.dimmed(0.4))
            }
        }
        return out + Term.paint("⟩", Ink.slate)
    }
}
