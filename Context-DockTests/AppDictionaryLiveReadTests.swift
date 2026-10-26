// AppDictionaryLiveReadTests.swift
// Context-DockTests
//
// A tool-less provider (ChatGPT subscription, Claude Code, Apple Intelligence) is handed no
// tools, so "current volume level?" in a Spotify chat was answered from the window title —
// the model never asked for the dictionary read that holds the number. The app now reads the
// application properties the question names before the model is asked, and puts the values
// in the prompt as evidence. These cover the part that decides *which* properties.

import Foundation
import Testing

@testable import Context_Dock

@Suite
struct AppDictionaryLiveReadTests {

    private static let spotify = AppSdefParser.parse(
        AppScriptingDictionaryParserTests.spotifyExcerpt,
        bundleID: "com.spotify.client", appName: "Spotify", version: "1.2")

    @Test func aVolumeQuestionNamesTheSoundVolumeProperty() {
        for text in ["current volume level?", "what is the volume in Spotify", "how loud is it, volume?"] {
            #expect(
                AppDictionaryCapabilities.askedApplicationProperties(
                    query: text, in: Self.spotify) == ["sound volume"],
                "\"\(text)\"")
        }
    }

    @Test func aQuestionNamingAValueOfAnEnumerationReadsThatProperty() {
        for text in ["is it playing?", "is it paused right now", "has it stopped"] {
            #expect(
                AppDictionaryCapabilities.askedApplicationProperties(
                    query: text, in: Self.spotify) == ["player state"],
                "\"\(text)\"")
        }
    }

    @Test func aQuestionThatNamesNoPropertyReadsNothing() {
        #expect(
            AppDictionaryCapabilities.askedApplicationProperties(
                query: "list all tracks", in: Self.spotify).isEmpty)
    }

    @Test func aPropertyThatIsAnObjectIsNotReadAsAValue() {
        // `current track` is a track object, read through `root`; as an application
        // property it would come back as a specifier, not an answer.
        #expect(
            !AppDictionaryCapabilities.askedApplicationProperties(
                query: "what is the current track", in: Self.spotify).contains("current track"))
    }

    @Test func aDictionaryWithoutAnApplicationClassReadsNothing() {
        let empty = AppScriptingDictionary(
            bundleID: "com.none.app", appName: "Nothing", version: "1",
            parsedAt: Date(), classes: [], commands: [])
        #expect(
            AppDictionaryCapabilities.askedApplicationProperties(query: "volume", in: empty).isEmpty)
    }

    @Test func listingAClassTheAppDoesNotExposeAsACollectionNamesTheBoundary() throws {
        let note = try #require(
            AppDictionaryCapabilities.collectionBoundary(
                query: "list all tracks", in: Self.spotify))
        #expect(note.contains("tracks"))
        // The way out the dictionary does offer: the item the app names.
        #expect(note.contains("current track"))
    }

    @Test func aQuestionThatIsNotAListingHasNoBoundaryNote() {
        for text in ["what is the current track", "current volume level?"] {
            #expect(
                AppDictionaryCapabilities.collectionBoundary(query: text, in: Self.spotify) == nil,
                "\"\(text)\"")
        }
    }
}
