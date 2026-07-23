import Foundation

/// Thread-safe "resume exactly once" gate for a CheckedContinuation that can be
/// completed from more than one path (e.g. a stream callback OR a timeout). The
/// first caller to `claim()` wins; the rest are no-ops, so the continuation is
/// never resumed twice (which would crash).
final class ResumeOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
