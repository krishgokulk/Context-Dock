# Scopes you can step into: extensions, CLI tools, and one input field

**Status: plan only. No code written for phases 1–4.**

## What is being asked for

The dock can *descend into* a result. Type `currency`, press Return, and the field becomes the
Currency Converter's own field with the converter drawn above it. Type `tailscale`, and the
field becomes that CLI tool's scope with its terminal attached. The corner cannot do either:
it finds those rows and then hands them to the dock (`GlobalContextRow.run`, the
`.cliScope` / `.systemCommandScope` cases).

The corner should do the same, in the corner's shape:

- **One input field.** Not a field per scope — the same field, meaning something different.
- **The scope's own board above it**, where the command list and the window snapshot already
  go.
- **A terminal beside it**, the way the clipboard sits beside the field when centred.
- **Usable without expanding.** Running `tailscale status` should not require opening a
  terminal panel first.

## Why this is not another small change

Everything the corner does today is *one level deep*: a scope is chosen, it answers, the field
returns to where it was. Stepping into an extension is a **stack**: Global → an extension →
possibly its own sub-scope, with a way back out of each. Three things follow, and each is a
decision rather than a detail:

1. **Who owns the field.** Today `AppChatPromptModel` is the field, and it holds one scope at
   a time (`appName`/`appBundleID`, with `returnsToGlobalScope` as a one-bit memory of where it
   came from). One bit does not describe a stack.
2. **Who owns the keyboard.** `CornerKeyboardOwner` names one of four claimants. A terminal is
   a fifth, and unlike the others it wants *every* key, including the arrows and Tab this
   surface currently spends on completion.
3. **What Return means.** In Global it takes a result. In an extension it submits that
   extension's input. In a terminal it runs a line. The key cannot mean three things by
   accident; it has to mean them by scope.

## Phase 1 — a scope stack behind the field

Replace `returnsToGlobalScope` with an explicit stack: `[CornerScope]`, where a scope is
`.global`, `.app(bundleID)`, `.extension(id)` or `.cli(command)`. The field renders the top of
the stack; backspace, `−` and left arrow pop it; entering pushes.

Everything already built keeps working because today's states are a stack of depth one or two.
The chip row becomes a breadcrumb when the stack is deeper than one, which is also how the
user sees where they are.

**Test first:** pushing and popping, that popping the last scope is a no-op rather than an
empty field, and that each scope keeps its own draft (already true, and must stay true).

## Phase 2 — extensions as a scope

Blocked on **#15**: user-added global extensions are not in `GlobalSearchService` at all, so
nothing can find them from either surface. That defect is upstream of this work and fixes both
surfaces at once, so it is done first, in its own change.

Then: an extension row pushes `.extension(id)`, the field adopts its placeholder, and its view
is drawn in the board slot. The dock already renders these (the Currency Converter card in the
user's screenshot); the corner should mount the same view rather than a second rendering of
it — the same rule that made `ContextMatchDock` shared rather than copied.

## Phase 3 — CLI tools as a scope, without a terminal

`tailscale` pushes `.cli("tailscale")`. The field runs subcommands and the board shows the
result, exactly as the dock's CLI scope does today. No terminal yet: most CLI use in this app
is one command and one answer, and shipping that first means the common case is usable while
the harder one is designed.

**Test first:** a command with an answer, a command that fails, and one that asks for input —
which must be refused rather than left hanging, since a field is not a TTY.

## Phase 4 — the terminal beside the field

A real terminal (SwiftTerm is already a dependency) in a card beside the field when centred,
above it when anchored. It takes the keyboard completely while focused, which is why
`CornerKeyboardOwner` gains it as a claimant with the highest precedence and an explicit way
out (Escape returns the caret to the field).

**Not started until phases 1–3 are used**, because a terminal that nobody has needed yet is
the most expensive way to find out the scope stack was wrong.

## What this plan does not cover

The dock's own extension and CLI surfaces stay as they are. This adds a second presentation of
them, the way the corner's chat is a second presentation of the dock's conversation — not a
migration. Retiring the dock's copies is a separate decision, and not one to take before the
corner has carried these scopes for a while.
