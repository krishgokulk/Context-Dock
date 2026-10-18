import Foundation
import Testing
@testable import Context_Dock

struct CLIProcessTests {
    @Test func linesKeepSplitUnicodeAndUnterminatedTail() {
        let bytes = Array("hello 🌍\ntail".utf8)
        var buffer = CLIByteLines()
        #expect(buffer.append(Data(bytes.prefix(8))).isEmpty)
        #expect(buffer.append(Data(bytes.dropFirst(8))) == ["hello 🌍"])
        #expect(buffer.finish() == "tail")
        #expect(buffer.finish() == nil)
    }

    @Test func processReadsStdinAndSeparatesDiagnosticsAndExitStatus() async throws {
        let result = try await CLIProcess.run(
            binary: "/bin/sh", arguments: ["-c", "cat; printf diagnostic >&2; exit 7"],
            directory: nil, environment: ["PATH": "/bin:/usr/bin"], input: "hello 🌍\n", timeout: 5)
        #expect(result.stdout == "hello 🌍\n")
        #expect(result.stderr == "diagnostic")
        #expect(result.status == 7)
    }

    @Test func cancellationStopsTheRunningProcess() async throws {
        let task = Task {
            try await CLIProcess.run(binary: "/bin/sleep", arguments: ["30"],
                directory: nil, environment: [:], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process returned success")
        } catch is CancellationError {} catch { Issue.record("Wrong cancellation error: \(error)") }
    }

    @Test func timeoutStopsTheRunningProcess() async throws {
        do {
            _ = try await CLIProcess.run(binary: "/bin/sleep", arguments: ["30"],
                directory: nil, environment: [:], timeout: 0.1)
            Issue.record("Timed out process returned success")
        } catch is CLIProcess.Failure {} catch { Issue.record("Wrong timeout error: \(error)") }
    }

    @Test func timeoutKillsAStubbornDescendantHoldingThePipes() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            _ = try await CLIProcess.run(
                binary: "/bin/sh", arguments: ["-c",
                    "(trap '' TERM; sleep 4; printf survived > \"$1\") & wait", "sh", marker.path],
                directory: nil, environment: ["PATH": "/bin:/usr/bin"], timeout: 0.1)
            Issue.record("Timed out process returned success")
        } catch is CLIProcess.Failure {} catch { Issue.record("Wrong timeout error: \(error)") }
        // Assert child behavior, not when the parallel test scheduler resumes this task.
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellingWhileALargePromptIsBlockedOnStdinCannotSignalTheApp() async throws {
        do {
            _ = try await CLIProcess.run(
                binary: "/bin/sleep", arguments: ["30"], directory: nil, environment: [:],
                input: String(repeating: "x", count: 2_000_000), timeout: 0.1)
            Issue.record("Timed out process returned success")
        } catch is CLIProcess.Failure {} catch { Issue.record("Wrong timeout error: \(error)") }
    }
}
