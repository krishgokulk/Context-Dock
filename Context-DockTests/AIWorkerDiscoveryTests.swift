import Foundation
import Testing

@testable import Context_Dock

/// Finding the specialists once, so a request never has to go looking.
///
/// The typing path is the reason this is separate from the router: Global Context answers as
/// the user types, and a filesystem probe — let alone a process launch — has no business
/// there. Discovery resolves paths on a background pass and writes what it found; a request
/// reads that and nothing else.
@Suite("Worker discovery")
struct AIWorkerDiscoveryTests {
    @Test func aBinaryThatIsNotThereIsNotAWorker() {
        let found = AIWorkerDiscovery.workers(
            candidates: [.claudeCode: ["/nowhere/claude"], .codex: ["/nowhere/codex"]],
            isExecutable: { _ in false })

        #expect(found.isEmpty)
    }

    @Test func theFirstPathThatExistsWins() throws {
        let found = AIWorkerDiscovery.workers(
            candidates: [.claudeCode: ["/missing/claude", "/opt/homebrew/bin/claude"]],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" })

        let worker = try #require(found.first)
        #expect(worker.kind == .claudeCode)
        #expect(worker.executablePath.path == "/opt/homebrew/bin/claude")
    }

    /// A specialist claims domains, and an installed one claims the same domains every time:
    /// what a worker is good for is a property of the worker, not of where it was found.
    @Test func anInstalledWorkerCarriesItsDomains() throws {
        let found = AIWorkerDiscovery.workers(
            candidates: [.codex: ["/usr/local/bin/codex"]],
            isExecutable: { _ in true })

        let worker = try #require(found.first)
        #expect(worker.domains.contains(.coding))
        #expect(worker.domains.contains(.repository))
    }

    @Test func resultsAreOrderedForOfferingNotByDictionaryChance() {
        let found = AIWorkerDiscovery.workers(
            candidates: [.codex: ["/bin/codex"], .claudeCode: ["/bin/claude"]],
            isExecutable: { _ in true })

        #expect(found.map(\.kind) == [.claudeCode, .codex])
    }

    /// The registry is what a request reads, and it holds only what discovery found.
    @MainActor
    @Test func theRegistryHoldsWhatDiscoveryFound() {
        let registry = AIWorkerRegistry.shared
        let previous = registry.installed
        defer { registry.replaceInstalled(previous) }

        registry.replaceInstalled(
            AIWorkerDiscovery.workers(
                candidates: [.claudeCode: ["/bin/claude"]],
                isExecutable: { _ in true }))

        #expect(registry.installed.map(\.kind) == [.claudeCode])
        #expect(registry.eligible(for: "fix this compile error").count == 1)
    }
}
