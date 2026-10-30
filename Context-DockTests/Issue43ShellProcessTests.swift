import Testing
@testable import Context_Dock

// Issue #43: 54 Process call sites inherited stdin or deadlocked on a full pipe.
//
// The fix introduces ShellProcess, a safe wrapper that (a) always sets null stdin so a child
// that has no terminal does not stop on SIGTTIN, and (b) drains both pipes on dedicated
// threads before `waitUntilExit`, so a child that produces more than the 64 KB pipe buffer
// does not block on write while the host blocks on wait.
//
// These tests verify the two traps the acceptance criteria call out:
//   - a child that would read stdin returns rather than hanging
//   - a child that writes >64 KB returns its whole output

struct ShellProcessCheckTests {

    @Test func checkReturnsTrueWhenCommandExitsZero() {
        #expect(ShellProcess.check("/usr/bin/true"))
    }

    @Test func checkReturnsFalseWhenCommandExitsNonzero() {
        #expect(!ShellProcess.check("/usr/bin/false"))
    }

    @Test func checkReturnsFalseForMissingExecutable() {
        #expect(!ShellProcess.check("/does/not/exist/binary"))
    }

    @Test func checkNullStdinPreventsHangOnStdinRead() {
        // `head -1` reads one line from stdin. With null stdin it sees EOF immediately
        // and exits 0. Without it, it blocks on a tty. The short timeout surfaces a hang.
        let ok = ShellProcess.check("/usr/bin/head", arguments: ["-1"])
        #expect(ok, "`head -1` should exit 0 on EOF from null stdin, not hang indefinitely")
    }
}

struct ShellProcessSyncTests {

    @Test func runSyncCapturesStdout() {
        let result = ShellProcess.runSync("/bin/echo", arguments: ["hello-43"])
        #expect(result?.succeeded == true)
        #expect(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-43")
    }

    @Test func runSyncNonzeroCapturesStatus() {
        let result = ShellProcess.runSync("/usr/bin/false")
        #expect(result?.status != 0)
    }

    @Test func runSyncReturnsNilForMissingExecutable() {
        let result = ShellProcess.runSync("/does/not/exist")
        #expect(result == nil)
    }

    @Test func runSyncNullStdinPreventsHang() {
        // `cat` with no file reads stdin and exits when it sees EOF. With null stdin it
        // gets EOF at once and returns. Without null stdin under a tty it blocks forever.
        let result = ShellProcess.runSync("/bin/cat", timeout: 5)
        #expect(result != nil, "`cat` with null stdin should exit immediately on EOF from /dev/null")
        #expect(result?.status == 0)
    }

    @Test func runSyncLargeOutputDoesNotDeadlock() {
        // 10,000 lines × 12 bytes = ~120 KB — past the 64 KB pipe buffer.
        // Without the drain-before-wait fix, the child blocks writing while the host blocks
        // waiting, and runSync returns nil after the timeout.
        let result = ShellProcess.runSync(
            "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 10000); do printf 'hello world\\n'; done"],
            timeout: 30)
        #expect(result != nil, "large output should not deadlock; got nil (timed out or errored)")
        let lineCount = result?.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        #expect(lineCount == 10000, "expected 10,000 lines; got \(lineCount ?? -1)")
    }

    @Test func runSyncCapturesBothPipes() {
        let result = ShellProcess.runSync(
            "/bin/sh", arguments: ["-c", "echo stdout-line; echo stderr-line >&2"])
        #expect(result?.stdout.contains("stdout-line") == true)
        #expect(result?.stderr.contains("stderr-line") == true)
    }

    @Test func runSyncTimeoutKillsHungProcess() {
        // sleep 60 will be killed by the 2-second timeout, not left running.
        let result = ShellProcess.runSync("/bin/sleep", arguments: ["60"], timeout: 2)
        // A timed-out run returns nil (the helper returns nil on timeout).
        #expect(result == nil, "a process exceeding timeout should be killed and return nil")
    }
}

struct ShellProcessAsyncTests {

    @Test func runAsyncCapturesStdout() async {
        let result = await ShellProcess.run("/bin/echo", arguments: ["async-43"])
        #expect(result?.succeeded == true)
        #expect(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "async-43")
    }

    @Test func runAsyncLargeOutputDoesNotDeadlock() async {
        let result = await ShellProcess.run(
            "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 10000); do printf 'hello world\\n'; done"],
            timeout: 30)
        #expect(result != nil, "async large output must not deadlock")
        let lineCount = result?.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        #expect(lineCount == 10000, "expected 10,000 lines; got \(lineCount ?? -1)")
    }

    @Test func runAsyncTimeoutKillsProcess() async {
        let result = await ShellProcess.run("/bin/sleep", arguments: ["60"], timeout: 2)
        #expect(result == nil, "a process exceeding timeout should be killed and return nil")
    }
}
