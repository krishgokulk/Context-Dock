# Corner UI/UX plan — adapted from Claude Code's desktop redesign (2026-10-26)

> **Status: DRAFT / design proposal for the owner.** Planning only — no tasks created, no code
> changed. The owner reads this, decides what becomes `ready` issues, and in what order. Nothing
> here overrides `00-DOCK-AND-CORNER.md`, `UNIFIED_DOCK_SURFACE.md`, or the live #318 work; where it
> touches them it says so.
> Tags: `[source]` from the Claude Code desktop redesign article · `[ours]` our current code/rules ·
> `[proposal]` my recommendation · `[guess]` inference, verify before building · `[owner]` needs a decision.

Source read: `https://claude.com/resources/articles/claude-code-desktop-redesign` (high-level; it
covers structure, not pixels — no colours, materials, animations, corner radii, or tab behaviour).
I could not watch the YouTube video; this plan is built from that article + our own UI truth files,
not from frames. Anything that would need the frames is marked `[guess]`.

---

## 0. The one decision that shapes everything else

**Claude Code's desktop app is a multi-pane IDE. DoraX is a one-shell ambient dock. These are
opposite shapes, and copying the layout would break our core rule.** `[proposal]`

- Claude Code redesign `[source]`: a **session sidebar** + a **drag-and-drop workspace grid** that
  holds terminal, file editor, diff viewer, preview pane and chat, arranged however the user likes.
  Many surfaces, one resizable window.
- DoraX `[ours]`: **one shared `UnifiedDockShell`**, modes are *content inside it*, "Do not build new
  floating panels with custom visual containers" (`UNIFIED_DOCK_SURFACE.md` line 178). The Dock
  window is deleted (#257); the Corner is the only shell; new states are *phases*, never new windows.

So "make it perfect for our app" is **not** "rebuild the IDE." It is: take the *principles* Claude's
redesign is built on — manage many conversations, disclose tool detail progressively, branch a side
question, keep usage visible, stream — and express each one as a **mode/phase of the single Corner
shell**. Every feature below is tagged **Adopt / Adapt / Reject**, and every Reject names the rule it
would break.

If the owner wants the literal multi-pane IDE instead, that is a different product and a blueprint
change, not a Corner task — say so and I will plan that separately.

---

## 1. Feature-by-feature map

| # | Claude Code desktop `[source]` | Verdict | DoraX form `[proposal]` |
|---|---|---|---|
| A | **Session sidebar** — every active/recent session in one place | **Adapt** | A **Conversations board** — a phase above the input, not a persistent side rail (a rail is a second container). Lists recent chats across scopes. §2.1 |
| B | **Filter by status / project / environment; group by project** | **Adapt** | Filter/group the Conversations board by **scope** (Global / per-app / General) and state, not project/env. §2.1 |
| C | **Auto-archive on PR merge/close** | **Adapt** | Auto-fold/clear an idle chat (we already auto-hide after idle); add "archived, not deleted" so it is recoverable from the Conversations board. §2.1 |
| D | **Drag-and-drop workspace grid** (terminal/editor/diff/preview/chat) | **Reject** | Breaks "one shell, no second floating box" (`UNIFIED_DOCK_SURFACE.md` 178, Unified Dock Surface rule in `CLAUDE.md`). The *content types* come back as result cards (row F), not as rearrangeable panes. |
| E | **Integrated terminal / in-app file editor / SSH / local-or-cloud sessions** | **Reject (v1)** | DoraX is a local macOS assistant that *drives other apps*; it is not an IDE host. Terminal already exists as a CLI scope + Computer Use lane. No editor pane. Revisit only if the blueprint changes. `[owner]` |
| F | **Diff viewer / preview pane** (HTML, PDF, local servers) | **Adapt** | We already open results as cards (Open / Reveal / Quick Look, file preview, `CornerLivePanel`). Keep that; a preview opens **above the input** and stands down — never a persistent pane. §2.4 |
| G | **Side chat** `⌘;` — branches off the main thread, pulls its context, adds nothing back | **Adopt (new)** | Strong fit and genuinely new for us: a **Side Thread** phase for a throwaway question scoped to the current chat's context that does not pollute the transcript. §2.2 |
| H | **Usage button** — context window + session usage at a glance | **Adapt** | A small **usage chip** in the shell footer; multi-provider, so it shows active provider + context use, not one vendor's quota. §2.3 |
| I | **View modes: Verbose / Normal / Summary** (how much tool-call detail shows) | **Adopt** | Direct fit onto `CornerLivePanel`: a three-way detail toggle on the live/progress panel. §2.5 |
| J | **`⌘/` full shortcut list** | **Adopt** | A **Keys overlay** listing the Dock Key Map + swipes in-shell (we have many hotkeys and no in-app cheat sheet). §2.6 |
| K | **Streaming responses** | **Verify** `[guess]` | Likely already streaming via `ScopedTurnRunner`; confirm, and make sure it streams identically in every scope. No new UI if already done. |
| L | **Plugins work in desktop same as terminal** | **Already ours** | = **App Packs** (`docs/architecture/PLUGINS.md`). Naming parity only; nothing to build. |

---

## 2. The surfaces, specified against the shell

All of these are **content inside `UnifiedDockShell`** (Header · Input Bar · Context Chips · Content
Area · Footer/Hints). None adds a window. All reuse the one input, one row, one animation system, and
the stable size rules. Each spec says what it borrows from Claude and where it must stay DoraX.

### 2.1 Conversations board (rows A–C) — Adapt

- **Opens as a phase**, the way the clipboard board and selection card already open above the input
  (`CornerBoardLayout`). Not a left/right rail. `[proposal]`
- **Shows** recent + active chats: one row each, with scope chip (Global / app icon / General),
  first line of the last turn, relative time, and a live dot if a turn is running.
- **Filter/group by scope and state** (running / idle / archived), mirroring Claude's filter-by-status
  but on our axes. Reuse the same row family and keyboard rules (↑/↓ highlight, ↩ resume, Esc back).
- **Archive, don't delete:** idle chats fold out of the board (we already auto-hide); archived ones
  stay recoverable. Claude archives on PR merge; our analog `[guess]` is "the task the chat was about
  finished" — needs an owner definition of what counts as done. `[owner]`
- **Open question:** do we even keep history across launches today, or are turns ephemeral per scope?
  If ephemeral, this feature needs a persistence decision first. `[owner]`

### 2.2 Side Thread (row G) — Adopt, new

- Hotkey `[proposal]` in the Corner's own map (not `⌘;`, which may clash with a macOS global — pick in
  the recorder that already requires a modifier, per the §4a hotkey-recorder fix). `[owner]`
- Opens a **lightweight chat phase** seeded with the current chat's context (scope, last turn,
  attached chips) that **writes nothing back** to the main transcript — exactly Claude's "branches
  off, pulls context, adds nothing back."
- Reuses the General Chat engine; it is *not* a new scope in the layer sense — it is a transient view.
  Closing it returns to the exact phase you left (stable-state rule).
- Why it fits DoraX: the "ask a quick aside without derailing the main chat" need is real in an
  ambient assistant; this is the one redesign idea worth adopting wholesale.

### 2.3 Usage chip (row H) — Adapt

- Lives in the shell **Footer/Hints** row, far side from the key hints.
- Shows **active provider** + a compact context-use indicator (e.g. a thin meter). Tap → a small
  popover with provider, context window used, and any session/rate state we track.
- Multi-provider is the difference from Claude's single-vendor usage button; the chip must read from
  whatever provider the current scope uses, and say so.

### 2.4 Result preview (row F) — Adapt, mostly already built

- No new pane. Keep opening Open / Reveal / Quick Look / file-preview cards **above the input**, which
  grow as far as the content needs and then stand down (compact-first rule, `00-DOCK-AND-CORNER.md` §3.5).
- The redesign's "diff viewer / preview pane" maps to: a richer in-card preview for files an answer
  produces (we already write to `~/Documents/DoraX Outputs/`). `[proposal]` A code/diff card is a
  nice-to-have, not v1.

### 2.5 Live panel detail modes (row I) — Adopt

- Add **Verbose / Normal / Summary** to `CornerLivePanel` (the panel already renders the whole trace:
  reasoning Understood→Lane→Chose→Shortcut→Gate + the tool steps, per P5/#199).
  - **Summary** = result rows only.
  - **Normal** = steps + outcomes (today's default `[guess]`).
  - **Verbose** = full trace incl. reasoning lines.
- One control, persisted per user, same in every scope. This is the cleanest 1:1 borrow — our panel is
  already structured for it.

### 2.6 Keys overlay (row J) — Adopt

- An in-shell overlay (a phase, dimmed behind) listing the **Dock Key Map + swipes** (⌘ tap, →, ↩,
  Esc, ←/→ General Chat toggle, the vertical swipes from §4b). `[ours]`
- Opens from a key `[owner]` and from a `?` hint in the Footer. Closes on Esc. No window.

### 2.7 Expand → open in the full window, + Raycast-comfortable compact size (owner decision 2026-10-26)

**Decision, from the owner's screenshots + words (2026-10-26):** *"keep same size window that fits
like centre window like Raycast — now it's smaller; show an expand icon at the bottom next to settings
and the open/pin icon; when the user clicks it, open that app chat in a window; both corner and centre
launcher, same side panels."* This **overrides** the earlier grow-in-place draft of this section:
expand **opens the existing full window**, it does not grow the panel in place.

Two changes, applied **identically to the corner dock and the centre launcher** (parity is explicit):

1. **Compact size — make it Raycast-comfortable.** The compact App Chat panel is too small today
   (owner screenshots 4–5). Grow the default compact size so it "fits like the centre window" — roomy
   enough to read without expanding, like Raycast's centred panel. Same shell, **same size in corner
   and centre** (one-size rule, owner 2026-09-25). This is a size change, not a new window.
2. **Expand control in the footer.** Put the expand glyph (⤢) in the **footer bar, beside the gear
   (settings) and the pin/open icon** — consistent in every scope. Today it sits top-right in App Chat
   (screenshot 4) while Global and Finder show gear/pin in the footer (screenshots 1–2); unify the
   placement. Clicking it **opens the current conversation in the full window** (the tabbed
   Chat/Work/Dashboard window, screenshot 3), on its **Chat tab**.

**The real work is parity of the side panels, not the button.** `[proposal]` The compact App Chat
shows a right panel — **Progress / Connectors / Can do here** — plus the running-app strip
(screenshots 4–5). The full window today opens on "What are we working on?" and does **not** render
that same panel (screenshot 3). "Same side panels etc." means: expand lands on the Chat tab, carries
the live conversation, and shows the **identical** right panel — the full window already has a
right-panel toggle, so it must host the **same component**, never a second design. Reuse the one
panel; do not build a parallel one.

**Feasibility: yes, perfectly — the pieces already exist.** `[proposal]`
- The full window exists (tabbed Chat/Work/Dashboard, screenshot 3) and has a right-panel toggle.
- The expand control exists (top of App Chat, screenshot 4).
- So the task is: (a) bump compact size, (b) move/standardise the expand control into the footer across
  scopes, (c) route expand → the full window's Chat tab with the live conversation + the shared right
  panel.
- **One thing to verify in code first** `[guess]`: that the compact App Chat and the full window share
  one chat model (likely `AppScopedChatService`), so the conversation survives the hand-off. If they
  don't, that wiring is the actual work; if they do, this is mostly placement + size + panel reuse.

**What stays:** ⌃C still opens the full window from a hotkey; expand is the same destination via a
click, carrying the current chat. Esc / collapse returns focus to the compact shell. Global Context
search does not expand into a chat — only chat scopes (General Chat, App Chat) do (layer rule).

---

## 3. What stays DoraX (the non-negotiables this plan keeps)

1. **One shell, modes as content.** Everything above plugs into `UnifiedDockShell`; nothing recreates
   the window or adds a floating container. (`UNIFIED_DOCK_SURFACE.md`.)
2. **Same shell size/field/strip style across every scope** (owner 2026-09-25). A Conversations board
   in Global looks identical to one in an app scope.
3. **Layer jobs stay separate even as #318 merges the shell.** #318 merges Global + Context Dock into
   one *surface/state*; it keeps job separation via query intent + lane. This plan does not re-merge
   General Chat, Media, or Selection into that surface. (`CLAUDE.md` layer rule, as #318 rewords it.)
4. **Liquid Glass + Glass Darkness slider** already own the material; no new material system. The
   article gives us no colour/material guidance anyway.
5. **Checked by eye.** Any of these, when built, ships with screenshots of the changed phase **and its
   reference scope**, per AGENTS.md.

---

## 4. Conflicts / things I need the owner to settle

1. **IDE or dock?** (§0) Confirm we adopt principles, not the multi-pane layout. If you actually want
   panes, that is a blueprint change. `[owner]`
2. **#318 overlap.** A builder is unifying the dock surface right now. The Conversations board (§2.1)
   and usage chip (§2.3) touch the same shell. **Recommendation:** these land *after* #318 merges, as
   issues sequenced behind it — not in parallel, or they will fight over `CornerBoardLayout`. `[proposal]`
3. **History/persistence.** §2.1 and the archive model assume chats persist across launches. If turns
   are ephemeral today, decide persistence before the board. `[owner]`
4. **Hotkeys.** Side Thread (§2.2) and Keys overlay (§2.6) need keys that don't clash; assign them in
   the recorder that requires a modifier. `[owner]`
5. **Expand → full window: resolved** (owner 2026-10-26, §2.7) — expand opens the current chat in the
   existing full window; not grow-in-place. **Still open:** the full window must render the *same*
   right panel (Progress / Connectors / Can do here) as the compact App Chat, or "same side panels"
   isn't met. Confirm that is in scope. `[owner]`
6. **Scope of v1.** My ranked recommendation if you want the highest ratio of Claude-feel to effort:
   **(1) Compact-size + expand-to-full-window §2.7** (the owner's explicit ask; biggest felt change),
   **(2) Live panel detail modes §2.5** (already-structured, pure win), **(3) Keys overlay §2.6**
   (cheap, discoverability), **(4) Side Thread §2.2** (the one new idea worth it), then **(5)
   Conversations board §2.1** and **(6) usage chip §2.3** after #318. `[proposal]`

---

## 5. Explicitly rejected (so no agent builds them by reading the article)

- Drag-and-drop workspace grid / rearrangeable panes (row D) — breaks one-shell rule.
- Integrated terminal pane, in-app file editor, SSH, local-vs-cloud session hosting (row E) — DoraX is
  not an IDE host.
- A persistent left/right session sidebar — a sidebar is a second container; use the Conversations
  board phase instead.
