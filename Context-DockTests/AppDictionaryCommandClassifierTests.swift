// AppDictionaryCommandClassifierTests.swift
// Context-DockTests
//
// The read/write/outbound classification tests the dictionary rung owes the done-when
// (P13 #208). One vocabulary with the CLI learner: outbound above write above read,
// unknown asks (writes on the gate), and nothing that sends is ever a read.

import Testing
@testable import Context_Dock

@Suite
struct AppDictionaryCommandClassifierTests {

    @Test func reads() {
        for name in ["get", "count", "exists", "list", "search", "read"] {
            #expect(AppDictionaryCommandClassifier.verbClass(ofCommandName: name) == .read)
        }
        // AppleScript's odd spelling: extraction commands ("extract name from") read.
        #expect(
            AppDictionaryCommandClassifier.verbClass(ofCommandName: "extract name from")
                == .read)
    }

    @Test func writes() {
        for name in [
            "make", "set", "create", "delete", "move", "duplicate", "save", "open",
            "close", "play", "pause", "playpause", "stop", "next track", "export",
        ] {
            #expect(AppDictionaryCommandClassifier.verbClass(ofCommandName: name) == .write)
        }
        // A compound that hides a destructive part asks ("set-getter" carries set).
        #expect(
            AppDictionaryCommandClassifier.verbClass(ofCommandName: "mark-as-read") == .write)
        #expect(
            AppDictionaryCommandClassifier.verbClass(ofCommandName: "set-getter") == .write)
    }

    @Test func outboundNeverClassifiesToRead() {
        for name in ["send", "reply", "forward", "compose"] {
            #expect(AppDictionaryCommandClassifier.verbClass(ofCommandName: name) == .outbound)
        }
        for apple in ["redirect", "transmit", "publish", "share", "post", "upload"] {
            #expect(AppDictionaryCommandClassifier.verbClass(ofCommandName: apple) == .outbound)
        }
        // A send hiding in a compound ("send-later") still cannot be a read.
        #expect(
            AppDictionaryCommandClassifier.verbClass(ofCommandName: "send-later") == .outbound)
    }

    @Test func unclassifiedNetworkVerbsLandAsWrites() throws {
        // "check for new mail"/"synchronize" reach the network. The classifier has no
        // word for "check" — nil — and the parser lands every nil on .write, so a
        // network-touching verb can never sneak into the manifest as a read.
        #expect(
            AppDictionaryCommandClassifier.verbClass(ofCommandName: "check for new mail")
                == nil)
        let manifest = AppSdefParser.parse(
            AppScriptingDictionaryParserTests.mailExcerpt,
            bundleID: "com.apple.mail", appName: "Mail", version: "17")
        #expect(manifest.command(named: "check for new mail")?.verbClass == .write)
        #expect(manifest.command(named: "synchronize")?.verbClass == .write)
    }

    @Test func unknownIsWriteByDefault() {
        #expect(
            AppDictionaryCommandClassifier.verbClass(ofCommandName: "frobnicate") == nil)
        #expect(AppDictionaryCommandClassifier.verbClass(ofCommandName: "") == nil)
        // At the dictionary, an unclassified command still lands as .write in the
        // manifest (see the parser tests) — nothing unknown can masquerade as a read.
    }
}
