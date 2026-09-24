// Context-Dock
//
// What a model is told before it writes a plugin. One reference, two readers: the Creator
// hands it to the configured provider, and "Copy prompt" hands it to a person to paste into
// any other AI. The same text either way, so a manifest written elsewhere is held to the same
// rules as one written here.
//
// The reference is built from the code, not written beside it: the component names come
// from `PluginComponentCatalog`, the built-ins and inputs from `PluginSchema`, and the two
// worked examples are the shipped plugins themselves. A reference that drifted from the
// validator would teach a format the Creator then refuses to save.

import Foundation

enum PluginAuthoringPrompt {

    /// The DSL, as a model needs it: shape, rules, the kit, two examples that validate.
    static let reference: String = {
        let containers = PluginComponentCatalog.containers.sorted().map { "`\($0)`" }
            .joined(separator: ", ")
        let leaves = PluginComponentCatalog.leaves.sorted().map { "`\($0)`" }
            .joined(separator: ", ")
        let builtIns = PluginSchema.builtInActionTypes.sorted().map { "`\($0)`" }
            .joined(separator: ", ")
        let inputs = PluginSchema.allowedInputs.sorted().map { "`\($0)`" }
            .joined(separator: ", ")
        return """
        # DoraX plugin manifest

        A plugin is ONE JSON object. It declares what it shows and what it can do; the app
        draws it with a fixed native kit. A manifest never styles anything — no colours, no
        fonts, no sizes — it picks components and binds values.

        ## Top level

        - `id` (string, kebab-case, unique), `name`, `icon` (an SF Symbol name), `description`
        - `keywords`: what a person might type to find it
        - `inputs`: which contexts it wants, from \(inputs). `[]` for a plugin that needs none.
        - `permissions`: what its scripts reach — `"network:<host>"` per host it calls, \
        `"network:local"` for loopback and LAN, `"shell"` is implied by any bash action.
        - `state`: values the plugin REMEMBERS between runs, `{ "key": "default" }`. A tap that \
        `set`s one is stored; scripts read them as `CD_STATE_<KEY>` (uppercased, non-alphanumerics \
        to `_`).
        - `data`: the one script whose output is what the views bind to: \
        `{ "type": "bash"|"applescript"|"jxa"|"shortcut"|"http", "script": "...", \
        "format": "json"|"jsonl"|"lines"|"raw", "refresh": { "widget": seconds, "panel": seconds }, \
        "timeout": seconds }`. `refresh` of `0` means never re-run. A JSON output whose top level \
        carries `"state": { ... }` patches the remembered values.
        - `sample`: example data in the shape the script prints, so the plugin can be previewed \
        and validated without running anything. Every `{{binding}}` in a view must exist in \
        `sample` or `state`.
        - `actions`: named things a tap can do (below).
        - `primaryAction`: the action choosing the plugin runs when it has no views (a one-shot).
        - `views`: any of `icon`, `widget`, `panel`, `window` (below).

        ## Actions

        `"actions": { "<name>": { "type": ..., "title": "...", "risk": "read"|"low"|"medium"|"high" } }`

        - Script types: `bash`, `applescript`, `jxa`, `scriptFile`, `shortcut`, `http`, with \
        `"script"`. The script gets the inputs as `CD_QUERY`, `CD_TEXT`, `CD_FILES`, `CD_URL`, \
        `CD_CLIP_TEXT`, the remembered values as `CD_STATE_<KEY>`, and for a tap on a row or a \
        value: `CD_ROW` (the item as JSON), `CD_ROW_ID`, `CD_ROW_TITLE`, `CD_VALUE`.
        - Built-ins: \(builtIns). `copy`/`open`/`reveal`/`paste` take `"value"` (may bind). \
        `set` writes `"value"` into `state[key]` — `"key"` may itself bind, e.g. `"{{picking}}"`.
        - Navigation: `"type": "push:panel"` or `"push:window"` opens that view. With a `"key"` \
        and `"value"` it also remembers what was tapped before opening (a picker that knows \
        which side it is choosing).
        - `risk`: `read` never asks; `low`/`medium` run when a person taps but ask an agent; \
        `high` always asks. Scripts default to `low`, built-ins to `read`. Be honest — a script \
        that changes something is at least `medium`.
        - `"success": { "title": "...", "message": "..." }` is what the app shows when it ran.

        ## Views

        Every view is a tree. A node is `{ "<component>": <props or children> }`. A container \
        takes an array of children (`{ "vstack": [ ... ] }`); a leaf takes props \
        (`{ "title": "{{result}}" }` or `{ "button": { "title": "...", "action": "name" } }`).

        - Containers: \(containers).
        - Leaves: \(leaves).
        - `grid`: `{ "columns": n, "items": "{{list}}", "cell": { ...template with {{item.x}}... } }`; \
        `list`: `{ "items": "{{list}}", "row": { "title": "{{item.title}}", "action": "name" } }`.
        - A leaf that acts names an action: `"action"`, `"submit"`, `"onTap"`, `"transport"`, \
        `"volume"`, `"edit"`. A `caption`/`title` with `"edit": "<set action>"` and `"value"` \
        becomes editable on tap (type a number, ⏎ stores it). `textField` takes `"value"` and \
        `"action"`.
        - `header` `{ "text": "...", "icon": "..." }` at the top of a panel names it — the card \
        then shows no second title.

        Presentations:
        - `icon`: `{ "capsule": [ { "thumbnail": "{{art}}" }, { "waveform": "{{playing}}" } ] }` — \
        drawn live in the dock strip in one 48pt slot: the first child fills it, the rest is a \
        badge on it.
        - `widget`: `{ "family": "bar"|"small"|"medium"|"large", "slots": 1-4, "root": ... }`. \
        `bar` is the dock-strip tile: `slots` icons wide, ONE icon (48pt) tall — at most two \
        lines (`caption` over `title`) beside chips. Keep it to an `hstack` of one or two \
        `vstack`s plus `button`/`iconButton` chips. Anything taller does not fit.
        - `panel`: the card that opens above the tile or icon, ~380pt wide, scrolls. A `header` \
        first, then rows, a `grid` of `button` cells, a `form`.
        - `window`: `{ "width": "narrow"|"regular"|"wide", "root": ... }`; when omitted the \
        panel is shown in the window.

        ## Example — a one-shot (no views, a primary action)

        ```json
        \(PluginEssentials.sleepJSON)
        ```

        ## Example — a bar tile with state, a data script and a picker panel

        ```json
        \(PluginEssentials.currencyJSON)
        ```
        """
    }()

    /// What the Creator tells the provider before the person's description.
    static let system: String = """
        You write plugins for DoraX, a macOS launcher and dock. Reply with ONE line saying \
        what you built or changed, then ONE ```json block holding the complete manifest, and \
        nothing after it. Never omit fields to save space — the block is saved as-is. Use only \
        the components and action types in the reference. Prefer a `bar` widget when the \
        person wants something in the dock, a `panel` for lists and pickers, a one-shot with \
        `primaryAction` for a single command. Put example data in `sample` so the preview \
        draws. Scripts run in zsh on the person's Mac: keep them short, quote variables, \
        exit non-zero on failure, and print JSON when `format` is `json`.

        \(reference)
        """

    /// The whole thing for another AI: the reference, the instruction and the request, so
    /// what comes back pastes into the Creator and validates the same.
    static func exportable(request: String) -> String {
        """
        \(system)

        ---

        Write a plugin: \(request)

        Reply with one line describing it, then the manifest in a single ```json block.
        """
    }

    /// The user turn for a draft: the description, and the manifest it edits when there is
    /// one — an edit is "change this", not "start again".
    static func userTurn(request: String, current: String?) -> String {
        guard let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "Write a plugin: \(request)" }
        return """
            Here is the current manifest:

            ```json
            \(current)
            ```

            Change it: \(request)

            Reply with the whole manifest after the change.
            """
    }

    /// The second turn when the first draft did not validate: the errors, verbatim, so the
    /// model fixes what the validator will check rather than what it guesses.
    static func repairTurn(errors: [PluginDiagnostic]) -> String {
        let lines = errors.map { "- \($0.path): \($0.message)" }.joined(separator: "\n")
        return """
            That manifest does not validate:

            \(lines)

            Reply with the corrected manifest in one ```json block.
            """
    }
}
