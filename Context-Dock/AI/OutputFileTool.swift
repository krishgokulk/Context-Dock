// OutputFileTool.swift
// Context-Dock
//
// `write_output_file`: the model's way to hand the user a real file — a .md, .txt, .csv or .docx
// in ~/Documents/DoraX Outputs. The result carries the full path, so `TurnFileExtractor` draws it
// as a card (Open, Reveal, Quick Look, drag) with no extra wiring.
//
// This is a write, so it always asks: the same approval sheet as every other write tool, naming
// the file, the folder and the start of the content. Refused without asking when the caller is an
// unattended MCP agent (nobody is at the keyboard to say no). One entry point,
// `AgentToolRegistry.runWriteOutputFile`, serves the in-app agent and the DoraX MCP server. The
// rules for names, formats and the folder live in OutputFileWriter.

import Foundation

extension AgentToolRegistry {

    func registerOutputFileTool() {
        register(
            AgentTool(
                name: "write_output_file",
                description: "Write a new file for the user into their DoraX Outputs folder "
                    + "(~/Documents/DoraX Outputs) and show it as a file card. Formats: md, txt, "
                    + "csv (plain UTF-8 text, written exactly as given) or docx (a Word document, "
                    + "one paragraph per line). You choose the name and format, never the folder; "
                    + "an existing file is never overwritten (a \" 2\" is added). The user "
                    + "approves each file. Returns the full path: quote it in your answer.",
                properties: [
                    "name": [
                        "type": "string",
                        "description": "A plain file name without folders, e.g. \"passport files\". "
                            + "The extension is added from 'format'.",
                    ],
                    "format": [
                        "type": "string",
                        "description": "One of: md, txt, csv, docx.",
                    ],
                    "content": [
                        "type": "string",
                        "description": "The whole file content. For csv, header row first.",
                    ],
                ],
                required: ["name", "format", "content"]
            ) { arguments, context in
                await AgentToolRegistry.runWriteOutputFile(
                    name: arguments["name"] as? String ?? "",
                    format: arguments["format"] as? String ?? "",
                    content: arguments["content"] as? String ?? "",
                    scope: context.chatScope, attended: true)
            })
    }

    /// The single entry point for both the in-app tool and the MCP tool.
    ///
    /// `attended` is false for an outside MCP agent: nobody can approve, so nothing is written.
    /// `folder` and `approve` are injected for tests; the defaults are the real outputs folder
    /// and the shared approval sheet (which itself refuses inside an unattended run).
    @MainActor
    static func runWriteOutputFile(
        name: String, format: String, content: String, scope: GeneralChatScope?,
        attended: Bool,
        folder: URL = OutputFileWriter.defaultFolder(),
        approve: ((AIActionPlan, AICapability) async -> Bool)? = nil
    ) async -> AgentToolResult {
        let shown = "write_output_file(\(name))"

        // Refuse a bad request before asking anyone to approve it.
        guard let kind = OutputFileWriter.Format(model: format) else {
            return failure(OutputFileWriter.Refusal.unsupportedFormat(format), shown)
        }
        let stem: String
        do { stem = try OutputFileWriter.sanitisedStem(name, format: kind) } catch {
            return failure(error, shown)
        }
        guard content.utf8.count <= OutputFileWriter.maxContentBytes else {
            return failure(OutputFileWriter.Refusal.tooLarge, shown)
        }

        guard attended else {
            AICapabilityApprovalCenter.recordUnattendedRefusal(OutputFileTool.capabilityID)
            return AgentToolResult(
                success: false,
                output: "Writing a file needs the user's approval, and this caller is unattended, "
                    + "so nothing was written.",
                displayCommand: shown + " · refused")
        }

        let plan = OutputFileTool.plan(stem: stem, format: kind, content: content, folder: folder)
        let capability = OutputFileTool.capability()
        let approved: Bool
        if let approve {
            approved = await approve(plan, capability)
        } else {
            approved = await AICapabilityApprovalCenter.shared.requestApproval(
                plan: plan, capability: capability, context: .none, chatScope: scope)
        }
        guard approved else {
            var denied = AgentToolResult(
                success: false,
                output: "The user did not approve writing \(stem).\(kind.rawValue). Say so and stop.",
                displayCommand: shown + " · declined")
            denied.deniedByUser = true
            return denied
        }

        do {
            let url = try OutputFileWriter.write(
                name: name, format: format, content: content, folder: folder)
            return AgentToolResult(
                success: true,
                output: "Saved `\(url.path)` — it is shown to the user as a file card. Quote "
                    + "this full path in your answer.",
                displayCommand: "write_output_file(\(url.lastPathComponent))")
        } catch {
            return failure(error, shown)
        }
    }

    private static func failure(_ error: Error, _ shown: String) -> AgentToolResult {
        AgentToolResult(
            success: false, output: error.localizedDescription, displayCommand: shown)
    }
}

/// The approval the sheet shows. Medium risk: it creates a file and never replaces one, but it is
/// still the model putting something on the user's disk.
enum OutputFileTool {
    static let capabilityID = "output.writeFile"

    static func capability() -> AICapability {
        AICapability(
            id: capabilityID,
            title: "Write a file to DoraX Outputs",
            appBundleID: nil,
            inputSchema: .init(fields: []),
            riskLevel: .medium,
            runsWithoutAdapter: true,
            executor: { _ in
                throw AICapabilityError.blocked(
                    "Output files are written by write_output_file, not the registry.")
            })
    }

    static func plan(
        stem: String, format: OutputFileWriter.Format, content: String, folder: URL
    ) -> AIActionPlan {
        let preview = String(content.prefix(300))
        return AIActionPlan(
            capability: capabilityID,
            input: [
                "file": "\(stem).\(format.rawValue)",
                "folder": folder.path,
                "size": "\(content.utf8.count) bytes",
            ],
            explanation: "Create \(stem).\(format.rawValue) in \(folder.path). "
                + "An existing file is never replaced.\n\nStarts with:\n\(preview)"
                + (content.count > 300 ? "…" : ""))
    }
}
