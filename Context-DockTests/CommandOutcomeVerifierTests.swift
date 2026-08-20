import Testing
import Foundation
@testable import Context_Dock

// MARK: - Reading back what a command claimed to change
//
// A shell command that exits zero has run. That is not the same as having worked, and the
// difference is invisible to a model: `defaults write NSGlobalDomain AppleInterfaceStyle`
// returns nothing and exits zero whether or not the desktop changed.
//
// The verdict used to live in the sentence — callers decided pass or fail by looking for the
// prefix "NOT applied", which every reader had to parse and any rewording would break. It
// carries a status now.

@MainActor
struct CommandOutcomeVerifierTests {

    // MARK: Quit-shaped commands

    /// The app names in these are almost certainly not running under test, so the reading is
    /// "no longer running" — which is the verified outcome for a quit.
    @Test func aQuitIsReadBackAgainstWhatIsRunning() {
        for command in [
            "killall Xyzzy-NotARealApp",
            "pkill -x Xyzzy-NotARealApp",
            #"osascript -e 'quit app "Xyzzy-NotARealApp"'"#,
        ] {
            let reading = CommandOutcomeVerifier.verify(command: command)
            #expect(reading != nil, "should recognise: \(command)")
            #expect(reading?.status == .verified)
        }
    }

    /// A verdict a caller can switch on, not a prefix it has to match.
    @Test func theVerdictIsTypedRatherThanSpelled() {
        let reading = CommandOutcomeVerifier.verify(command: "killall Xyzzy-NotARealApp")
        #expect(reading?.status.claimsSuccess == true)
        // The old contract leaked the verdict into the prose. The message is now a reading.
        #expect(reading?.message.hasPrefix("Verified:") == false)
        #expect(reading?.message.hasPrefix("NOT applied") == false)
    }

    /// Something is always readable back, so the receipt has a sentence to carry.
    @Test func aReadingAlwaysSaysWhatItSaw() {
        let reading = CommandOutcomeVerifier.verify(command: "killall Xyzzy-NotARealApp")
        #expect(reading?.message.isEmpty == false)
        #expect(reading?.message.contains("Xyzzy-NotARealApp") == true)
    }

    // MARK: Appearance

    /// Read from the same defaults domain the command writes, so the status reflects the
    /// machine rather than the request.
    @Test func appearanceIsReadFromTheSystemNotTheCommand() {
        let reading = CommandOutcomeVerifier
            .verify(command: "defaults write NSGlobalDomain AppleInterfaceStyle -string Dark")
        #expect(reading != nil)
        // Whichever the desktop is actually in, the answer is one of these two and never a
        // shrug — the whole point is that this command cannot report its own effect.
        #expect(reading?.status == .verified || reading?.status == .contradicted)
    }

    // MARK: Nothing to read

    /// Deliberately small. A verifier that guesses is worse than none: it confirms things
    /// that did not happen, which is the failure it exists to stop.
    @Test func commandsWithNoReadableEffectReturnNothing() {
        for command in ["ls -la", "echo hello", "git status", "brew update"] {
            #expect(CommandOutcomeVerifier.verify(command: command) == nil,
                    "should not claim to verify: \(command)")
        }
    }

    @Test func isVerifiableAgreesWithVerify() {
        #expect(CommandOutcomeVerifier.isVerifiable(command: "killall Xyzzy-NotARealApp"))
        #expect(!CommandOutcomeVerifier.isVerifiable(command: "ls -la"))
    }
}
