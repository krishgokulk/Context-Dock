import Foundation
import Testing

@testable import Context_Dock

// What may be run, and what a pack may install.
//
// "Run the file named in this text" is the sentence every arbitrary-execution bug is written in,
// so these are mostly tests of refusals: the declaration is the allowlist, the folder is the
// boundary, and a pack's scripts arrive inert.

struct AppAgentScriptTests {

    private func makeFolder() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-scripts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeScript(
        _ name: String, in root: URL, bundleID: String = "com.apple.safari", executable: Bool = true
    ) -> URL {
        let folder = AppAgentScript.folder(forBundleID: bundleID, root: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? "#!/bin/zsh\necho hello\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    @Test func aDeclaredExecutableScriptResolves() {
        let root = makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        writeScript("tabs-to-md.sh", in: root)

        let result = AppAgentScript.resolve(
            name: "tabs-to-md.sh", declared: ["tabs-to-md.sh"], bundleID: "com.apple.Safari",
            root: root)
        #expect((try? result.get())?.lastPathComponent == "tabs-to-md.sh")
    }

    @Test func aScriptTheProfileDoesNotDeclareIsRefused() {
        // The declaration is the allowlist. Without this the app's scripts folder is a menu
        // anything can order from.
        let root = makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        writeScript("secret.sh", in: root)

        let result = AppAgentScript.resolve(
            name: "secret.sh", declared: ["tabs-to-md.sh"], bundleID: "com.apple.Safari",
            root: root)
        #expect(result == .failure(.notDeclared("secret.sh")))
    }

    @Test func aPathIsNotAName() {
        // The traversal that would otherwise reach anything on disk.
        for name in ["../../../usr/bin/osascript", "scripts/x.sh", "..", ".hidden"] {
            let result = AppAgentScript.resolve(
                name: name, declared: [name], bundleID: "com.apple.Safari",
                root: makeFolder())
            #expect(result == .failure(.unsafeName(name)), "\(name) must be refused")
        }
    }

    @Test func aSymlinkOutOfTheFolderIsRefused() throws {
        // The same escape as a path, written differently — so the check is after resolving.
        let root = makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.sh")
        try "#!/bin/zsh\necho nope\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: outside.path)

        let folder = AppAgentScript.folder(forBundleID: "com.apple.safari", root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.sh"), withDestinationURL: outside)

        let result = AppAgentScript.resolve(
            name: "link.sh", declared: ["link.sh"], bundleID: "com.apple.Safari", root: root)
        #expect(result == .failure(.outsideScriptsFolder("link.sh")))
    }

    @Test func aScriptThatIsNotExecutableSaysSo() {
        // Rather than failing later as an opaque shell error.
        let root = makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        writeScript("inert.sh", in: root, executable: false)

        let result = AppAgentScript.resolve(
            name: "inert.sh", declared: ["inert.sh"], bundleID: "com.apple.Safari", root: root)
        #expect(result == .failure(.notExecutable("inert.sh")))
    }

    @Test func aDeclaredScriptThatIsNotThereSaysThatInstead() {
        let root = makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = AppAgentScript.resolve(
            name: "gone.sh", declared: ["gone.sh"], bundleID: "com.apple.Safari", root: root)
        #expect(result == .failure(.missing("gone.sh")))
    }

    @Test func absentIsNotEmpty() {
        // A script can tell "nothing selected" from "an empty selection" only if the absent
        // case sets no variable at all.
        let withoutSelection = AppAgentScript.environment(
            appName: "Safari", bundleID: "com.apple.Safari", query: "tabs")
        #expect(withoutSelection["CD_SELECTION"] == nil)
        #expect(withoutSelection["CD_QUERY"] == "tabs")

        let withSelection = AppAgentScript.environment(
            appName: "Safari", bundleID: "com.apple.Safari", query: "tabs",
            selection: [URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(withSelection["CD_SELECTION"] == "/tmp/a.txt")
        #expect(withSelection["CD_SELECTION_COUNT"] == "1")
    }
}

// The directive a provider with no tools uses to reach a declared script.
struct AppAgentScriptDirectiveTests {

    @Test func aScriptIsReachableWithoutNativeTools() {
        // Claude Code is run with none of DoraX's tools, so `run_app_script` is unreachable
        // for it. Asked to run a declared script it searched ~/Downloads, ~/Desktop and
        // mdfind instead — the wrong answer, reached by the wrong authority.
        let invocation = AITypedInvocationResolver.invocation(
            from: #"{"app_script": {"name": "tabs-to-md.sh", "reason": "collect tabs"}}"#)
        #expect(invocation?.kind == .appScript)
        #expect(invocation?.arguments["name"] == "tabs-to-md.sh")
        #expect(invocation?.arguments["reason"] == "collect tabs")
        #expect(invocation?.requiresApproval == true)
    }

    @Test func aDirectiveWithNoNameIsNotOne() {
        let invocation = AITypedInvocationResolver.invocation(from: #"{"app_script": {}}"#)
        #expect(invocation?.kind != .appScript)
    }
}

// A profile and its scripts, as one thing to hand over.
struct AppAgentProfilePackTests {

    private func makePack(declaring: [String], carrying: [String]) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Safari.dxagent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let declared = declaring.isEmpty
            ? "" : "tools:\n  scripts: [\(declaring.joined(separator: ", "))]\n"
        try? """
            ---
            app: Safari
            bundle_id: com.apple.Safari
            \(declared)---

            Prefer the live page read.
            """.write(
                to: folder.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
        if !carrying.isEmpty {
            let scripts = folder.appendingPathComponent("scripts", isDirectory: true)
            try? FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            for name in carrying {
                let url = scripts.appendingPathComponent(name)
                try? "#!/bin/zsh\necho hi\n".write(to: url, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return folder
    }

    @Test func aPackSaysWhatItCarries() throws {
        let pack = makePack(declaring: ["a.sh"], carrying: ["a.sh"])
        defer { try? FileManager.default.removeItem(at: pack) }

        let contents = try AppAgentProfilePack.inspect(folder: pack)
        #expect(contents.profile.appName == "Safari")
        #expect(contents.scripts == ["a.sh"])
        #expect(contents.missingScripts.isEmpty)
    }

    @Test func aPromiseWithNoFileBehindItIsReported() throws {
        // A profile declaring a script it does not carry fails when somebody asks for it,
        // which is the worst moment to discover it.
        let pack = makePack(declaring: ["a.sh", "missing.sh"], carrying: ["a.sh"])
        defer { try? FileManager.default.removeItem(at: pack) }

        let contents = try AppAgentProfilePack.inspect(folder: pack)
        #expect(contents.missingScripts == ["missing.sh"])
    }

    @Test func aFolderWithNoProfileIsNotAPack() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-pack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: AppAgentProfilePack.PackError.self) {
            try AppAgentProfilePack.inspect(folder: folder)
        }
    }

    @Test func importedScriptsArriveInert() throws {
        // A pack is someone else's code. Becoming runnable is a decision, not a side effect of
        // opening a file — so the bit is off unless the caller says otherwise, and
        // AppAgentScript then refuses it with "chmod +x it" rather than running it.
        let pack = makePack(declaring: ["a.sh"], carrying: ["a.sh"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: pack)
            try? FileManager.default.removeItem(at: root)
        }

        _ = try AppAgentProfilePack.install(
            folder: pack, forBundleID: "com.apple.Safari", into: root)
        let installed = AppAgentScript.folder(forBundleID: "com.apple.safari", root: root)
            .appendingPathComponent("a.sh")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(!FileManager.default.isExecutableFile(atPath: installed.path))

        let refusal = AppAgentScript.resolve(
            name: "a.sh", declared: ["a.sh"], bundleID: "com.apple.Safari", root: root)
        #expect(refusal == .failure(.notExecutable("a.sh")))
    }

    @Test func sayingSoMakesThemRunnable() throws {
        let pack = makePack(declaring: ["a.sh"], carrying: ["a.sh"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: pack)
            try? FileManager.default.removeItem(at: root)
        }

        _ = try AppAgentProfilePack.install(
            folder: pack, forBundleID: "com.apple.Safari", into: root,
            makeScriptsExecutable: true)
        let result = AppAgentScript.resolve(
            name: "a.sh", declared: ["a.sh"], bundleID: "com.apple.Safari", root: root)
        #expect((try? result.get()) != nil)
    }

    @Test func exportCarriesTheProfileAndItsScripts() throws {
        let pack = makePack(declaring: ["a.sh"], carrying: ["a.sh"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-trip-\(UUID().uuidString)", isDirectory: true)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer {
            for url in [pack, root, out] { try? FileManager.default.removeItem(at: url) }
        }

        _ = try AppAgentProfilePack.install(
            folder: pack, forBundleID: "com.apple.Safari", into: root)
        let exported = try AppAgentProfilePack.export(
            forBundleID: "com.apple.Safari", appName: "Safari", from: root, to: out)

        let contents = try AppAgentProfilePack.inspect(folder: exported)
        #expect(exported.lastPathComponent == "Safari.dxagent")
        #expect(contents.scripts == ["a.sh"])
        #expect(contents.profile.tools.scripts == ["a.sh"])
    }

    @Test func exportingAnAppWithNoProfileRefuses() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AppAgentProfilePack.PackError.self) {
            try AppAgentProfilePack.export(
                forBundleID: "com.apple.Safari", appName: "Safari", from: root, to: root)
        }
    }
}
