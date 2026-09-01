import Foundation
import TeleportCore

/// Owns the live `simulate-location set` process — the thing that actually holds the
/// phone in place.
///
/// It is reached from two directions: the console on the main actor, and the signal
/// source on a background queue when someone hits Ctrl+C. That rules out actor isolation,
/// so it locks instead. Terminating happens outside the lock: the child's reader threads
/// want it too, and holding it across teardown invites a deadlock.
final class LocationSession: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: ParkedProcess?

    var isLive: Bool {
        lock.withLock { parked?.isRunning ?? false }
    }

    /// Takes ownership of a new session, retiring whatever it replaces.
    func adopt(_ session: ParkedProcess) {
        let previous: ParkedProcess? = lock.withLock {
            defer { parked = session }
            return parked
        }
        previous?.terminate()
    }

    func end() {
        let previous: ParkedProcess? = lock.withLock {
            defer { parked = nil }
            return parked
        }
        previous?.terminate()
    }
}

/// Process-wide, because the signal handler has to reach it without going through the
/// console. macOS doesn't reap orphans: miss this on the way out and a stray
/// pymobiledevice3 keeps the phone teleported after the terminal is gone.
let liveSession = LocationSession()
