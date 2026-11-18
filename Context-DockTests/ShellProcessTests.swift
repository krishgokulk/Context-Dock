import Foundation
import Testing
@testable import Context_Dock

/// Regression tests for the three child-process hazards fixed in Issue #43:
/// 1. Inherited stdin → SIGTTIN in a test runner (stdin is not a terminal).
/// 2. Wait-before-read deadlock when output exceeds the 64 KB pipe buffer.
/// 3. Timeout: a hanging process is killed and nil is returned.
struct ShellProcessTests {

    // MARK: - 1. Stdin is null — child that reads stdin must not hang

    @Test func stdinIsNullDevice() async {
        // `cat` with no arguments reads from stdin until EOF.  With the old pattern
        // (standardInput unset) this would inherit the test runner's stdin and hang
        // on SIGTTIN.  ShellProcess sets standardInput=nullDevice so cat sees EOF
        // immediately and exits cleanly.
        let result = ShellProcess.runSync("/bin/cat", timeout: 5)
        #expect(result != nil, "cat exited without hanging on inherited stdin")
        #expect(result?.succeeded == true)
        #expect(result?.stdout == "")
    }

    // MARK: - 2. Large output — more than 128 KB must not deadlock

    @Test func largeOutputDoesNotDeadlock() async {
        // Produce ~200 KB of output (200 × 1024 chars) — well above the 64 KB pipe
        // buffer limit that causes wait-before-read deadlocks.
        let result = ShellProcess.runSync(
            "/bin/sh",
            arguments: ["-c", "yes | head -c 204800"],
            timeout: 15
        )
        #expect(result != nil, "large-output process returned without deadlocking")
        #expect((result?.stdout.count ?? 0) > 100_000)
    }

    // MARK: - 3. Timeout — a hanging process is killed; nil is returned

    @Test func timeoutKillsProcess() async {
        let start = Date()
        // `sleep 60` would run forever without a timeout.
        let result = ShellProcess.runSync("/bin/sleep", arguments: ["60"], timeout: 2)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == nil, "timed-out process returns nil")
        #expect(elapsed < 10, "timeout fires within 10 s (actual: \(elapsed)s)")
    }
}
