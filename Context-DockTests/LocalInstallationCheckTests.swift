import Testing
@testable import Context_Dock

struct LocalInstallationCheckTests {
    @Test func parsesNaturalInstallationQuestions() {
        let first = LocalInstallationCheck.parse("check is llmbrain is installed on my system.")
        #expect(first?.displayName == "llmbrain")
        #expect(first?.executableNames.first == "llmbrain")

        let screenshotWording = LocalInstallationCheck.parse(
            "check is llmbrain installed on my system.")
        #expect(screenshotWording?.displayName == "llmbrain")
        #expect(screenshotWording?.executableNames.first == "llmbrain")

        let second = LocalInstallationCheck.parse("Is Visual Studio Code installed on my Mac?")
        #expect(second?.displayName == "Visual Studio Code")
        #expect(second?.executableNames.contains("visual-studio-code") == true)
    }

    @Test func ignoresNonInstallationRequests() {
        #expect(LocalInstallationCheck.parse("install llmbrain") == nil)
        #expect(LocalInstallationCheck.parse("what does llmbrain install?") == nil)
        #expect(LocalInstallationCheck.parse("open llmbrain") == nil)
    }
}

struct ExplicitCommandContractTests {
    @Test func parsesReadOnlyCommandFollowedByReport() {
        let query = "Run the read-only command seq 1 5000, then report the final five lines from the actual output."
        #expect(AgentAnswerVerifier.explicitlyRequestedCommand(in: query) == "seq 1 5000")
        #expect(AgentAnswerVerifier.explicitExecutionIsMissing(query: query, executed: []))
    }

    @Test func reportsRequestedTailFromActualOutput() async {
        let query = "Run the read-only command seq 1 5000, then report the final five lines from the actual output."
        let result = await AgentAnswerVerifier.executeMissingExplicitContract(
            query: query,
            executed: [],
            commandExecutor: { command, _, _ in
                #expect(command == "seq 1 5000")
                return (true, "1\n2\n3\n4\n5\n6\n", 0)
            })
        #expect(result?.answer.contains("2\n3\n4\n5\n6") == true)
        #expect(result?.additions.count == 1)
    }
}
