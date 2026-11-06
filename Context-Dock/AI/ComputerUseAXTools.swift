// ComputerUseAXTools.swift
// Context-Dock
//
// Phase 3.5 of the unified frontmost-app spec: the observe → act → verify loop.
//
// `operate_app` presses one menu item. Most real work in an app with no route is not a menu
// item — it is a button in a sheet, a field to fill, a tab to pick. These two tools give the
// model that reach without giving it pixels:
//
//   • `ax_snapshot` reads the pinned app's front window as a short list of elements, each with
//     an id (`e7`). The model names an id; it never guesses a coordinate.
//   • `ax_act` clicks, types into, or focuses one of those ids, then reports what changed.
//
// Everything that made `operate_app` safe is reused rather than restated: the same consent
// mode (`ComputerUseConsentStore`), the same approval card (`ComputerUseApproval`), the same
// destructive/outbound denylist, and the same scoping to the one app the chat belongs to. On
// top of that the loop has a step budget and a repeat guard so a confused model stops instead
// of clicking forever.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Loop guard (pure, testable)

/// Step budget and stall detection for one app's run of AX actions.
struct AXLoopGuard {
    enum Verdict: Equatable {
        case proceed
        case budgetExhausted
        case stalled
    }

    let maxSteps: Int
    let maxIdenticalRepeats: Int
    private(set) var steps = 0
    private var lastKey: String?
    private var repeats = 0

    init(maxSteps: Int = 25, maxIdenticalRepeats: Int = 2) {
        self.maxSteps = maxSteps
        self.maxIdenticalRepeats = maxIdenticalRepeats
    }

    /// Record an attempt. The same action on the same target in a row is a stall; the model
    /// is not learning anything from the third identical try.
    mutating func record(actionKey: String) -> Verdict {
        if steps >= maxSteps { return .budgetExhausted }
        steps += 1
        if actionKey == lastKey {
            repeats += 1
        } else {
            lastKey = actionKey
            repeats = 1
        }
        return repeats > maxIdenticalRepeats ? .stalled : .proceed
    }
}

// MARK: - Snapshot

struct AXSnapshotElement {
    let id: String
    let role: String
    let label: String
    let value: String?
    let isEnabled: Bool
    let canPress: Bool
    let isTextInput: Bool

    var line: String {
        var text = "[\(id)] \(role)"
        if !label.isEmpty { text += " \"\(label)\"" }
        if let value, !value.isEmpty { text += " value=\"\(value)\"" }
        if !isEnabled { text += " (disabled)" }
        return text
    }
}

@MainActor
enum AXSnapshotter {

    private static let maxElements = 150
    private static let maxDepth = 14

    /// Roles worth an id. Everything else is layout.
    private static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXLink", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider",
        "AXTabGroup", "AXDisclosureTriangle", "AXRow", "AXCell",
    ]
    private static let textInputs: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Element handles from the latest snapshot, per bundle id. Ids are valid until the next
    /// snapshot of the same app; a stale id is refused rather than guessed at.
    private static var handles: [String: [String: AXUIElement]] = [:]

    static func take(app: NSRunningApplication, bundleID: String) -> (
        elements: [AXSnapshotElement], context: [String], windowTitle: String
    )? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            var windowsRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                let windows = windowsRef as? [AXUIElement], let first = windows.first
            else { return nil }
            windowRef = first
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement

        var elements: [AXSnapshotElement] = []
        var context: [String] = []
        var table: [String: AXUIElement] = [:]
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0

        while cursor < queue.count, elements.count < maxElements {
            let (element, depth) = queue[cursor]
            cursor += 1
            let role = string(element, kAXRoleAttribute) ?? ""

            if actionable.contains(role) {
                let label = firstNonEmpty([
                    string(element, kAXTitleAttribute),
                    string(element, kAXDescriptionAttribute),
                    string(element, kAXPlaceholderValueAttribute),
                    string(element, kAXHelpAttribute),
                ])
                // Rows/cells with no label are layout; skip to keep the list readable.
                if !(role == "AXRow" || role == "AXCell") || !label.isEmpty {
                    let id = "e\(elements.count + 1)"
                    let isInput = textInputs.contains(role)
                    let value = isInput ? string(element, kAXValueAttribute).map { String($0.prefix(60)) } : nil
                    let actions = actionNames(element)
                    elements.append(
                        AXSnapshotElement(
                            id: id,
                            role: String(role.dropFirst(2)),
                            label: String(label.prefix(80)),
                            value: value,
                            isEnabled: bool(element, kAXEnabledAttribute) ?? true,
                            canPress: actions.contains(kAXPressAction as String),
                            isTextInput: isInput))
                    table[id] = element
                }
            } else if role == "AXStaticText", context.count < 20,
                let text = string(element, kAXValueAttribute), !text.isEmpty
            {
                context.append(String(text.prefix(100)))
            }

            if depth < maxDepth {
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                    let children = childrenRef as? [AXUIElement]
                {
                    for child in children { queue.append((child, depth + 1)) }
                }
            }
        }

        handles[bundleID] = table
        return (elements, context, string(window, kAXTitleAttribute) ?? "")
    }

    static func element(id: String, bundleID: String) -> AXUIElement? {
        handles[bundleID]?[id]
    }

    static func render(
        appName: String, snapshot: (elements: [AXSnapshotElement], context: [String], windowTitle: String)
    ) -> String {
        var out = "\(appName) — window \"\(snapshot.windowTitle)\". Element ids are valid until the next ax_snapshot.\n"
        out += snapshot.elements.map(\.line).joined(separator: "\n")
        if !snapshot.context.isEmpty {
            out += "\n\nText on screen:\n" + snapshot.context.map { "- \($0)" }.joined(separator: "\n")
        }
        return out
    }

    // MARK: AX attribute helpers

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func firstNonEmpty(_ values: [String?]) -> String {
        values.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
}

// MARK: - Runner

@MainActor
enum ComputerUseAXRunner {

    /// One guard per app, forgotten after five idle minutes so a new task starts fresh.
    private static var guards: [String: (guard: AXLoopGuard, last: Date)] = [:]
    private static let idleReset: TimeInterval = 300

    enum Action: String { case click, type, focus }

    // MARK: ax_snapshot

    static func snapshot(
        bundleID: String, reason: String, scope: GeneralChatScope?, screen: Bool = false
    ) async -> AgentToolResult {
        guard let (app, appName) = resolveApp(bundleID: bundleID) else {
            return fail("The app is not running, so there is no window to read. Use operate_app to start it.", "ax_snapshot")
        }
        guard AXIsProcessTrusted() else {
            return fail(
                "DoraX needs Accessibility permission (System Settings → Privacy & Security → Accessibility). Say that plainly.",
                "ax_snapshot(\(appName))")
        }
        if let refusal = await ensureConsent(
            app: app, appName: appName, bundleID: bundleID,
            target: ComputerUseTarget(path: ["Read \(appName) window"], isEnabled: true),
            reason: reason, scope: scope, perStepPrompt: false)
        {
            return refusal
        }
        if let stopped = stopRefusal(appName) { return stopped }
        ComputerUseSession.shared.began(appName: appName, bundleID: bundleID)
        _ = app.activate(options: [])
        if screen {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let text = await ComputerUseVision.read(bundleID: bundleID, appName: appName) else {
                return fail(
                    "Could not read \(appName)'s window from pixels. Screen Recording permission "
                        + "may be missing (System Settings → Privacy & Security → Screen Recording), "
                        + "or no text is visible. Say that plainly.",
                    "ax_snapshot(\(appName)) · screen")
            }
            return AgentToolResult(
                success: true,
                output: text + "\n\nClick or type with ax_act using a t-id. Each pixel click is "
                    + "approved by the user. Re-read after every step.",
                displayCommand: "ax_snapshot(\(appName)) · screen")
        }
        guard let snap = AXSnapshotter.take(app: app, bundleID: bundleID) else {
            return fail("\(appName) has no readable window right now.", "ax_snapshot(\(appName))")
        }
        return AgentToolResult(
            success: true,
            output: AXSnapshotter.render(appName: appName, snapshot: snap)
                + "\n\nPick ONE element id and call ax_act. Re-snapshot after each action; "
                + "do not reuse ids from older snapshots.",
            displayCommand: "ax_snapshot(\(appName))")
    }

    // MARK: ax_act

    static func act(
        action: Action, id: String, text: String?, reason: String, bundleID: String,
        scope: GeneralChatScope?
    ) async -> AgentToolResult {
        guard let (app, appName) = resolveApp(bundleID: bundleID) else {
            return fail("The app is not running.", "ax_act")
        }
        guard AXIsProcessTrusted() else {
            return fail("DoraX needs Accessibility permission to operate \(appName).", "ax_act(\(appName))")
        }
        if let stopped = stopRefusal(appName) { return stopped }
        let pixel = ComputerUseVision.isPixelID(id)
            ? ComputerUseVision.target(id: id, bundleID: bundleID) : nil
        let element = pixel == nil ? AXSnapshotter.element(id: id, bundleID: bundleID) : nil
        guard element != nil || pixel != nil else {
            return fail(
                "Element \(id) is not in the latest snapshot. Call ax_snapshot again and use an id from it.",
                "ax_act(\(appName): \(id)) · stale")
        }
        let label: String
        let role: String
        if let pixel {
            label = pixel.label
            role = "text (pixels)"
        } else if let element {
            label = [
                AXSnapshotter.string(element, kAXTitleAttribute),
                AXSnapshotter.string(element, kAXDescriptionAttribute),
            ].compactMap { $0 }.first { !$0.isEmpty } ?? id
            role = String((AXSnapshotter.string(element, kAXRoleAttribute) ?? "element").dropFirst(2))
        } else {
            label = id
            role = "element"
        }

        // Same denylist as menus: Send / Delete / Pay-style controls are never pressed here.
        let displayTarget = "\(action.rawValue) \(role) \"\(label)\""
        if action == .click, ComputerUseTargetResolver.isForbidden(path: [label]) {
            return AgentToolResult(
                success: false,
                output: "\"\(label)\" is a destructive or outbound control and is never pressed from "
                    + "Computer Use. Tell the user where it is and let them press it.",
                displayCommand: "ax_act(\(appName): \(displayTarget)) · forbidden"
            ).withUserSummary("\"\(label)\" is a destructive or outbound action, so DoraX won't press it. You can press it yourself.")
        }

        // Budget and stall guard.
        var entry = guards[bundleID].flatMap {
            Date().timeIntervalSince($0.last) < idleReset ? $0.guard : nil
        } ?? AXLoopGuard()
        let verdict = entry.record(actionKey: "\(action.rawValue)|\(id)|\(text ?? "")")
        guards[bundleID] = (entry, Date())
        switch verdict {
        case .budgetExhausted:
            return fail(
                "The step budget for this task is used up. Stop and tell the user what is done and what is left.",
                "ax_act(\(appName)) · budget")
        case .stalled:
            return fail(
                "The same action was just repeated without progress. Do not try it again; re-snapshot, "
                    + "try a different route, or tell the user what is blocking.",
                "ax_act(\(appName): \(displayTarget)) · stalled")
        case .proceed:
            break
        }

        let before = ComputerUseEvidence.describe(app: app)
        if let refusal = await ensureConsent(
            app: app, appName: appName, bundleID: bundleID,
            target: ComputerUseTarget(path: [displayTarget], isEnabled: true),
            reason: reason, scope: scope, perStepPrompt: true, alwaysAsk: pixel != nil,
            before: before)
        {
            return refusal
        }

        // The user may have pressed Stop while the approval card was open.
        if let stopped = stopRefusal(appName) { return stopped }
        ComputerUseSession.shared.began(appName: appName, bundleID: bundleID)

        // Pin: the elements belong to this app; make sure it is the one that receives events.
        _ = app.activate(options: [])
        try? await Task.sleep(nanoseconds: 150_000_000)

        let performed: Bool
        if let pixel {
            switch action {
            case .click, .focus:
                ComputerUseVision.click(at: pixel.point, pid: app.processIdentifier)
                performed = true
            case .type:
                guard let text, !text.isEmpty else {
                    return fail("ax_act type needs 'text'.", "ax_act(\(appName))")
                }
                await ComputerUseVision.typeText(text, at: pixel.point, pid: app.processIdentifier)
                performed = true
            }
        } else if let element {
          switch action {
        case .click:
            performed = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        case .focus:
            performed =
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                == .success
        case .type:
            guard let text, !text.isEmpty else {
                return fail("ax_act type needs 'text'.", "ax_act(\(appName))")
            }
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
                == .success
            {
                // Read back: some apps accept the call and ignore it.
                performed = AXSnapshotter.string(element, kAXValueAttribute) == text
            } else {
                performed = false
            }
        }
        } else {
            performed = false
        }

        guard performed else {
            ComputerUseSkillRecorder.shared.failed(bundleID: bundleID)
            return fail(
                "\(displayTarget) did not take effect in \(appName). Nothing is known to have changed. "
                    + "Re-snapshot and try a different element or route (operate_app for menus).",
                "ax_act(\(appName): \(displayTarget)) · failed")
        }

        if let learned = ComputerUseSkillRecorder.describe(
            action: action.rawValue, role: role, label: label, isPixel: pixel != nil)
        {
            ComputerUseSkillRecorder.shared.succeeded(
                bundleID: bundleID, appName: appName, goal: reason, step: learned)
        }

        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = ComputerUseEvidence.describe(app: app)
        let fresh = AXSnapshotter.take(app: app, bundleID: bundleID)
        let view = fresh.map { AXSnapshotter.render(appName: appName, snapshot: $0) } ?? "window no longer readable"

        return AgentToolResult(
            success: true,
            output: """
                Did: \(displayTarget) in \(appName).
                Before: \(before)
                After: \(after)

                Fresh snapshot (old ids are void):
                \(view)

                Decide from the snapshot whether the task is complete. If it is, say what changed; \
                if not, take the next single step. Do not claim success the snapshot does not show.
                """,
            displayCommand: "ax_act(\(appName): \(displayTarget))"
        ).withUserSummary("Did \(displayTarget) in \(appName).\n\nBefore: \(before)\nAfter: \(after)")
    }

    // MARK: Shared pieces

    private static func resolveApp(bundleID: String) -> (NSRunningApplication, String)? {
        guard !bundleID.isEmpty,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated && $0.processIdentifier > 0 })
        else { return nil }
        return (app, app.localizedName ?? bundleID)
    }

    /// Consent in one place: nil means go ahead, a result means stop with that answer.
    private static func ensureConsent(
        app: NSRunningApplication, appName: String, bundleID: String, target: ComputerUseTarget,
        reason: String, scope: GeneralChatScope?, perStepPrompt: Bool, alwaysAsk: Bool = false,
        before: String = ""
    ) async -> AgentToolResult? {
        let store = ComputerUseConsentStore.shared
        let mode = store.effectiveMode(for: bundleID)
        let hadOneShot = store.consumeOneShotGrant(for: bundleID)

        if !mode.canOperate && !hadOneShot {
            let ok = await ComputerUseApproval.requestFirstUse(
                appName: appName, bundleID: bundleID, target: target, reason: reason,
                before: before, chatScope: scope)
            guard ok else {
                return AgentToolResult(
                    success: false,
                    output: "The user did not allow DoraX to operate \(appName). Do not try again; "
                        + "give them the steps to do it themselves.",
                    displayCommand: "ax(\(appName)) · not allowed"
                ).withUserSummary("You didn't allow DoraX to operate \(appName).")
            }
            store.grantFromChat(for: bundleID)
        } else if perStepPrompt && (mode.requiresApprovalPerStep || alwaysAsk) {
            let ok = await ComputerUseApproval.request(
                appName: appName, bundleID: bundleID, target: target, reason: reason,
                before: before, chatScope: scope)
            guard ok else {
                return AgentToolResult(
                    success: false,
                    output: "The user declined \(target.display). Do not try another route to the same thing.",
                    displayCommand: "ax(\(appName): \(target.display)) · declined"
                ).withUserSummary("You declined \(target.display).")
            }
        }
        return nil
    }

    private static func stopRefusal(_ appName: String) -> AgentToolResult? {
        guard ComputerUseSession.shared.isStopped else { return nil }
        return AgentToolResult(
            success: false,
            output: "The user pressed Stop. Do not take any more steps in \(appName). Say what was "
                + "done so far and what is left, and ask whether to continue.",
            displayCommand: "ax(\(appName)) · stopped by user"
        ).withUserSummary("Stopped. DoraX won't take more steps in \(appName) unless you ask again.")
    }

    private static func fail(_ output: String, _ display: String) -> AgentToolResult {
        AgentToolResult(success: false, output: output, displayCommand: display)
            .withUserSummary(output)
    }
}

// MARK: - Registration

extension AgentToolRegistry {

    func registerComputerUseAXTools() {
        register(
            AgentTool(
                name: "ax_snapshot",
                description: "Read the front window of the app this chat is scoped to as a list of "
                    + "elements with ids (e1, e2…). Use after operate_app / run_menu_command cannot do the "
                    + "job and the work is in the window itself (a button, a field, a tab). Then act "
                    + "with ax_act, one step at a time.",
                properties: [
                    "reason": [
                        "type": "string",
                        "description": "One line the user may read on an approval card.",
                    ],
                    "mode": [
                        "type": "string", "enum": ["elements", "screen"],
                        "description": "elements (default) reads the Accessibility tree. screen reads "
                            + "pixels with OCR, only for apps that expose no elements (canvas apps).",
                    ],
                ],
                required: []
            ) { arguments, context in
                guard let bundleID = AgentToolRegistry.scopedBundleID(for: context.chatScope),
                    !bundleID.isEmpty
                else {
                    return AgentToolResult(
                        success: false,
                        output: "This conversation is not scoped to one app; ask in that app's own chat.",
                        displayCommand: "ax_snapshot")
                }
                let reason = (arguments["reason"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return await ComputerUseAXRunner.snapshot(
                    bundleID: bundleID, reason: reason, scope: context.chatScope,
                    screen: (arguments["mode"] as? String)?.lowercased() == "screen")
            })

        register(
            AgentTool(
                name: "ax_act",
                description: "Do ONE thing to an element from the latest ax_snapshot: click it, type "
                    + "text into it, or focus it. Returns before/after and a fresh snapshot — read it "
                    + "to verify the result before the next step. Destructive and outbound controls "
                    + "(Send, Delete, Pay…) are refused. Stops after repeated identical attempts or "
                    + "25 steps.",
                properties: [
                    "action": [
                        "type": "string", "enum": ["click", "type", "focus"],
                        "description": "What to do to the element.",
                    ],
                    "id": ["type": "string", "description": "Element id from the latest snapshot, e.g. \"e7\"."],
                    "text": ["type": "string", "description": "Text to enter, for action=type."],
                    "reason": ["type": "string", "description": "One line the user may read on an approval card."],
                ],
                required: ["action", "id"]
            ) { arguments, context in
                guard let bundleID = AgentToolRegistry.scopedBundleID(for: context.chatScope),
                    !bundleID.isEmpty
                else {
                    return AgentToolResult(
                        success: false,
                        output: "This conversation is not scoped to one app; ask in that app's own chat.",
                        displayCommand: "ax_act")
                }
                guard let action = ComputerUseAXRunner.Action(
                    rawValue: (arguments["action"] as? String ?? "").lowercased()),
                    let id = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespaces),
                    !id.isEmpty
                else {
                    return AgentToolResult(
                        success: false, output: "ax_act needs action (click|type|focus) and id.",
                        displayCommand: "ax_act")
                }
                return await ComputerUseAXRunner.act(
                    action: action, id: id, text: arguments["text"] as? String,
                    reason: (arguments["reason"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    bundleID: bundleID, scope: context.chatScope)
            })
    }
}
