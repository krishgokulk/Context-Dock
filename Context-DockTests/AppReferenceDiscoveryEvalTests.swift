import Foundation
import Testing

@testable import Context_Dock

// Evals for where an app's documentation comes from.
//
// The rule under test is that discovery never guesses. A wrong docs link is worse than none:
// it is cited, it reads as authoritative, and the answer built on it is confidently about
// some other piece of software.

struct AppReferenceOverrideEvalTests {

    /// A bundle id per test, not one shared by the suite.
    ///
    /// swift-testing runs these in parallel and they all write to the same UserDefaults key,
    /// so a shared id meant one test's cleanup deleted another's fixture mid-assertion — two
    /// failures that looked like a validation bug and were a test bug.
    private var bundleId: String { "eval.dorax.override.\(UUID().uuidString)" }

    private func clear(_ bundleId: String) {
        for url in AppReferenceOverrides.urls(forBundleId: bundleId) {
            AppReferenceOverrides.remove(url, forBundleId: bundleId)
        }
    }

    @Test func aPastedLinkIsRemembered() {
        let bundleId = bundleId
        defer { clear(bundleId) }
        #expect(AppReferenceOverrides.add("https://tutorini.app/help", forBundleId: bundleId))
        #expect(AppReferenceOverrides.urls(forBundleId: bundleId) == ["https://tutorini.app/help"])
    }

    @Test func aPastedAddressWithNoSchemeStillWorks() {
        // People copy "tutorini.app/help" out of a browser bar. Assuming https is not a guess
        // about which site — the user named it — only about how to reach it.
        let bundleId = bundleId
        defer { clear(bundleId) }
        #expect(AppReferenceOverrides.add("tutorini.app/help", forBundleId: bundleId))
        #expect(AppReferenceOverrides.urls(forBundleId: bundleId).first == "https://tutorini.app/help")
    }

    @Test func somethingThatIsNotAnAddressIsRefused() {
        // Refused rather than stored: a bad link fails at fetch time, silently, long after
        // the user has forgotten typing it.
        let bundleId = bundleId
        defer { clear(bundleId) }
        #expect(!AppReferenceOverrides.add("see the help menu", forBundleId: bundleId))
        #expect(!AppReferenceOverrides.add("", forBundleId: bundleId))
        // A bare word is a hostname to the parser and a mistake to everyone else.
        #expect(!AppReferenceOverrides.add("tutorini", forBundleId: bundleId))
        #expect(AppReferenceOverrides.urls(forBundleId: bundleId).isEmpty)
    }

    @Test func addingTheSameLinkTwiceKeepsOneCopy() {
        let bundleId = bundleId
        defer { clear(bundleId) }
        AppReferenceOverrides.add("https://tutorini.app", forBundleId: bundleId)
        AppReferenceOverrides.add("https://TUTORINI.app", forBundleId: bundleId)
        #expect(AppReferenceOverrides.urls(forBundleId: bundleId).count == 1)
    }

    @Test func oneAppsLinksDoNotLeakIntoAnother() {
        let bundleId = bundleId
        defer { clear(bundleId) }
        AppReferenceOverrides.add("https://tutorini.app", forBundleId: bundleId)
        #expect(AppReferenceOverrides.urls(forBundleId: "eval.dorax.other").isEmpty)
    }
}

struct AppBundleLinkEvalTests {

    @Test func aBundleThatIsNotInstalledYieldsNothingRatherThanAGuess() {
        #expect(
            AppBundleLinks.fromBundle(
                bundleId: "eval.dorax.not-installed", appName: "Nothing").isEmpty)
    }

    @Test func finderCarriesNoVendorDocumentationOfItsOwn() {
        // A real bundle, scanned for real. Apple's own apps are full of apple.com URLs —
        // schemas, support pages, telemetry — none of which is Finder documenting itself,
        // and all of which would be cited as though it were.
        let links = AppBundleLinks.fromBundle(
            bundleId: "com.apple.finder", appName: "Finder")
        #expect(links.allSatisfy { !$0.lowercased().contains("w3.org") })
        #expect(links.allSatisfy { !$0.lowercased().contains("schemas") })
    }
}
