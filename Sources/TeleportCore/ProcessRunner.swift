import Foundation

/// The outcome of running a command line tool to completion.
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }
}

public enum CommandError: LocalizedError {
    case launchFailed(String)
    case timedOut(Duration)
    /// A tool expected to park instead exited on its own — meaning it failed.
    case exitedBeforeReady(CommandResult)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            "Couldn't start pymobiledevice3: \(reason)"
        case .timedOut(let duration):
            "The device didn't respond within \(duration.wholeSeconds) seconds."
        case .exitedBeforeReady:
            "The command stopped before it finished."
        }
    }
}

// MARK: - Supporting primitives

/// Accumulates pipe output on the reader thread, and optionally watches it for a marker.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let marker: String?
    private let onMarker: (@Sendable () -> Void)?
    private var didFireMarker = false

    init(marker: String? = nil, onMarker: (@Sendable () -> Void)? = nil) {
        self.marker = marker
        self.onMarker = onMarker
    }

    func append(_ chunk: Data) {
        var shouldFire = false

        lock.lock()
        data.append(chunk)
        if let marker, !didFireMarker, String(decoding: data, as: UTF8.self).contains(marker) {
            didFireMarker = true
            shouldFire = true
        }
        lock.unlock()

        // Fired outside the lock: the handler may terminate the process, and that path
        // shouldn't run while holding a lock the reader thread also wants.
        if shouldFire { onMarker?() }
    }

    func snapshot(appending remainder: Data? = nil) -> String {
        lock.withLock {
            if let remainder { data.append(remainder) }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// A one-shot signal raised on an arbitrary thread and awaited from async code.
///
/// Signalling before anyone waits is fine — a later waiter returns immediately — which
/// matters because a process can exit before we get around to awaiting it.
private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isRaised = false

    func signal() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            isRaised = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let alreadyRaised: Bool = lock.withLock {
                if isRaised { return true }
                continuation = cont
                return false
            }
            if alreadyRaised { cont.resume() }
        }
    }
}

/// A tool that has finished its work and is now parked, held open on purpose.
///
/// `simulate-location set` keeps the DVT session open for as long as it runs, so the
/// object that owns this handle owns the simulation. Dropping it without calling
/// `terminate()` leaks a child process — macOS does not reap orphans for us.
public final class ParkedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let outPipe: Pipe
    private let errPipe: Pipe
    private var isTornDown = false

    fileprivate init(process: Process, outPipe: Pipe, errPipe: Pipe) {
        self.process = process
        self.outPipe = outPipe
        self.errPipe = errPipe
    }

    public var isRunning: Bool {
        lock.withLock { process.isRunning }
    }

    public func terminate() {
        lock.withLock {
            guard !isTornDown else { return }
            isTornDown = true
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }
}

/// Holds a `Process` so it can be terminated from a racing task or a reader thread.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.withLock {
            if process.isRunning { process.terminate() }
        }
    }
}

private enum RaceOutcome: Sendable {
    case exited
    case markerReached
    case sleepCancelled
}

/// Everything created by a launch, kept together so both run modes can share setup.
private struct Launch {
    let process: Process
    let outPipe: Pipe
    let errPipe: Pipe
    let outBuffer: OutputBuffer
    let errBuffer: OutputBuffer
    let terminationSignal: OneShotSignal
    let markerSignal: OneShotSignal

    func teardownPipes() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Drains whatever the handlers didn't see before exit.
    func finalResult() -> CommandResult {
        let trailingOut = try? outPipe.fileHandleForReading.readToEnd()
        let trailingErr = try? errPipe.fileHandleForReading.readToEnd()
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: outBuffer.snapshot(appending: trailingOut ?? nil),
            standardError: errBuffer.snapshot(appending: trailingErr ?? nil)
        )
    }
}

// MARK: - Runner

public enum ProcessRunner {
    /// Runs `executable` to completion, capturing both streams.
    ///
    /// Both pipes are drained continuously so a chatty tool can't deadlock by filling the
    /// 64 KB pipe buffer while we wait on exit.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration = .seconds(120)
    ) async throws -> CommandResult {
        let launch = try launch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            marker: nil
        )
        let box = ProcessBox(launch.process)

        do {
            _ = try await race(launch: launch, box: box, expectsMarker: false, timeout: timeout)
        } catch {
            launch.teardownPipes()
            throw error
        }

        launch.teardownPipes()
        return launch.finalResult()
    }

    /// Starts a tool that does its work and then parks, and returns once it's parked.
    ///
    /// `pymobiledevice3 developer dvt simulate-location set` is exactly this shape: it
    /// applies the location, prints a line saying it's now waiting for a signal, then
    /// blocks in `sigwait` to hold the DVT session open. Waiting for it to exit would hang
    /// forever, so we wait for that line instead — which is proof the work completed — and
    /// hand back a live handle the caller keeps for as long as the session should last.
    ///
    /// - Throws: `CommandError.exitedBeforeReady` if it exits first, which means it failed.
    public static func startParked(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        marker: String,
        timeout: Duration = .seconds(120)
    ) async throws -> ParkedProcess {
        let launch = try launch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            marker: marker
        )
        let box = ProcessBox(launch.process)

        let outcome: RaceOutcome
        do {
            outcome = try await race(launch: launch, box: box, expectsMarker: true, timeout: timeout)
        } catch {
            launch.teardownPipes()
            throw error
        }

        switch outcome {
        case .markerReached:
            Diagnostics.log("session parked and holding")
            return ParkedProcess(process: launch.process, outPipe: launch.outPipe, errPipe: launch.errPipe)

        case .exited, .sleepCancelled:
            launch.teardownPipes()
            let result = launch.finalResult()
            Diagnostics.log("session exited before parking: \(result.standardError.suffix(200))")
            throw CommandError.exitedBeforeReady(result)
        }
    }

    // MARK: - Internals

    private static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        marker: String?
    ) throws -> Launch {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let terminationSignal = OneShotSignal()
        let markerSignal = OneShotSignal()

        let outBuffer = OutputBuffer(marker: marker, onMarker: { markerSignal.signal() })
        let errBuffer = OutputBuffer()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBuffer.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBuffer.append(chunk) }
        }

        process.terminationHandler = { _ in terminationSignal.signal() }

        let launch = Launch(
            process: process,
            outPipe: outPipe,
            errPipe: errPipe,
            outBuffer: outBuffer,
            errBuffer: errBuffer,
            terminationSignal: terminationSignal,
            markerSignal: markerSignal
        )

        do {
            try process.run()
        } catch {
            launch.teardownPipes()
            throw CommandError.launchFailed(error.localizedDescription)
        }

        return launch
    }

    /// Races exit against the marker and the timeout.
    ///
    /// Every sibling parked on a continuation must be released before the group drains, or
    /// cleanup deadlocks waiting on something nothing will ever resume.
    private static func race(
        launch: Launch,
        box: ProcessBox,
        expectsMarker: Bool,
        timeout: Duration
    ) async throws -> RaceOutcome {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: RaceOutcome.self) { group in
                group.addTask {
                    await launch.terminationSignal.wait()
                    return .exited
                }
                if expectsMarker {
                    group.addTask {
                        await launch.markerSignal.wait()
                        return .markerReached
                    }
                }
                group.addTask {
                    // A cancelled sleep means someone else won the race.
                    do { try await Task.sleep(for: timeout) } catch { return .sleepCancelled }
                    box.terminate()
                    launch.markerSignal.signal()
                    throw CommandError.timedOut(timeout)
                }

                let first = try await group.next() ?? .exited

                switch first {
                case .markerReached:
                    // Release the exit waiter *without* killing the process — the whole
                    // point is that it stays alive and parked.
                    launch.terminationSignal.signal()
                case .exited, .sleepCancelled:
                    launch.markerSignal.signal()
                }

                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
            launch.markerSignal.signal()
        }
    }
}

private extension Duration {
    var wholeSeconds: Int { Int(components.seconds) }
}
