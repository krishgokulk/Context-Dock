# 00 — Product Plan: from powerful beta to product-ready DoraX

> **Status: PROPOSAL — written as if I owned this app.** Every decision below is a
> recommendation; the owner can overrule any of it. Written 2026-09-24 against `main` @ `341494a`.
> Tags: `[code]` verified in source · `[judgment]` my recommendation · `[guess]` estimate.
>
> Read this first. Docs `01`–`10` explain **how** DoraX works. This one says **what it is,
> who it is for, what "done" means, and the order to get there.**

---

## 0. The honest starting point

DoraX already has an engine most products never build: it drives other apps through their
own menus and tools, runs a plan that cannot contain invented steps, gates every risky action
behind one approval inbox, and **checks the result before claiming success**. `[code — 03, 08, 10]`

What it does not have is a **product around the engine**:

| Area | Today | Evidence |
|---|---|---|
| Promise | Six surfaces, no single sentence | README vs `PRODUCT_LAYERS.md` disagree (4 vs 6 surfaces) |
| Install | Signed with an *Apple Development* cert, not notarized; user must run `xattr -cr` | `scripts/ship.sh:95`, README "Install" |
| Updates | Downloads a DMG from `main` and opens it — **no hash or signature check** | `Services/AppUpdateService.swift:88–105` |
| CI | Builds only; the 1,167-test suite never runs on a PR | `.github/workflows/build.yml` |
| Measurement | No crash reporting, no usage counts, no aggregate eval score | `10 §5` |
| Codebase | 587 files / ~248k lines; three files over 8,000 lines each (two are settings) | `LegacySettingsContent.swift` 8,656 · `LauncherView+AIChat.swift` 8,220 · `AutomationSettingsView.swift` 8,128 |
| Focus | 10 specs + 13 plans in 3 weeks (Aug 23 – Sep 15) | `docs/superpowers/` |

**Product-ready means:** a stranger installs it without a warning, understands it in ten
seconds, succeeds at one real task in two minutes, and trusts it enough to leave it running.
None of those four is an engine problem. `[judgment]`

"Perfect" is not a target — it moves every time you polish. "Product-ready" has a checklist
(§5). Ship against the checklist.

---

## 1. Product definition

### 1.1 One sentence `[judgment]`

> **DoraX — tell your Mac what to do, in any app. It uses the app's own controls, asks before
> anything risky, and proves it worked.**

Every word maps to code that already exists:
- *in any app* → menu execution + adapters + MCP + Shortcuts (`03 §5`)
- *the app's own controls* → the tool-choice order, CLI last (`03 §5`)
- *asks before anything risky* → `ApprovalCenter`, per-route access (`08 §7, §9`)
- *proves it worked* → `CommandOutcomeVerifier`, `contradicted` status (`10 §1`)

### 1.2 One first user `[judgment]`

**Mac developers who already use Claude Code or Codex.** Why them first:
- They already feel the pain the README describes (build → screenshot → re-explain → repeat).
- They bring their own API keys and tolerate a beta.
- They are the people who post on Hacker News, X and Reddit — the launch channel.
- DoraX is itself built with this loop, so the owner is the user. `[code — README]`

The sentence stays general; the **launch audience** is narrow. Widen after 100 real users.

### 1.3 The hero moment

One workflow sells the product. Make it flawless, film it, put it at the top of everything:

```
you:   test it                → DoraX finds the project, proposes the build, runs it on approval
you:   the button is too tall → DoraX hands your agent the screenshot + build + diff + your words
agent: fixes it               → DoraX rebuilds and shows: ✓ verified
```

### 1.4 What DoraX is not (say it on the website)

Not an editor, not a browser, not a notes app, not a code-writer, not an autonomous agent
that acts without you. It carries work **between** the tools you already use.

---

## 2. Product shape: six surfaces become three verbs

Users do not think in layers. They think in verbs. Keep the layers separate **in code**
(the `PRODUCT_LAYERS.md` rule stands), but **present** them as three things:

| Verb | What the user sees | Layers underneath | Hotkey |
|---|---|---|---|
| **Find** | One search bar. "This app" commands first, then everything else. | `01` Global Context + `02` Context Dock | ⌘⌘ double-press Command (today's Global Context default) `[code]` |
| **Ask** | One chat with a scope chip: *This app · These apps · Everywhere* | `03` + `04` (already one engine, `04 §0`) | none by default — set under Settings → Hotkeys (App Chat / Chat Window) `[code]`; Tab from Find `[proposal]` |
| **Act on this** | Act on a selection or clip | `05` Selection + Clipboard | none by default — a selection auto-scopes on launch, or set Selection Scope in Settings → Hotkeys `[code]` |

This is the Unified Dock Surface rule applied to naming: one shell, modes inside it.

### 2.1 What ships in v1.0 vs later `[judgment]`

| v1.0 (on by default) | Labs (off by default, in Settings → Labs) | Cut from v1 |
|---|---|---|
| Find, Ask, Act on this | Second Brain + Dashboard (`09`) | Media Dock (`06`) — private `MediaRemote` framework, off-mission |
| Approvals, verification, receipts | Worker layer / `spawn_worker` (`08 §11`) | Drop shelf, dock strip polish |
| Providers: On-device, Anthropic, OpenAI, Ollama | L2 script extensions (`07`) | Gemini/Kimi/bridges until someone asks |
| Built-in Apple apps: Notes, Reminders, Calendar, Contacts, Finder, Mail | Plugins (`2026-09-15-plugins-design.md`) | Developer Inspector (keep as internal tool) |

"Cut" means hidden and unmaintained for v1, not deleted. Every surface you ship is a surface
you must test, document and support.

---

## 3. Architecture plan (engineering)

The engine is sound. The work is **subtraction and guardrails**, not new systems.

### 3.1 Delete one brain `[code — 04 §10 #1]`
`GeneralAIActionResolver` and the older `L2UnifiedAssistant` both route cross-app intent.
`L2UnifiedAssistant` is referenced by 5 files (`L2UnifiedAssistant`, `L2GitHubBridge`,
`L2WorkflowEngine`, `L2AIIntegrationView`, `L2GitHubToolIntegration`). Prove which is on the
hot path with the turn log, then delete the other. Dead routing code is a wrong answer
waiting to happen.

### 3.2 Break the three giant files
| File | Lines | Plan |
|---|---|---|
| `UI/LegacySettingsContent.swift` | 8,656 | "Legacy" — find what is still reachable, move it to the new settings pages, delete the rest |
| `Search/LauncherView+AIChat.swift` | 8,220 | Split by job: send, render, attachments, approvals |
| `Automation/AutomationSettingsView.swift` | 8,128 | One file per settings section |

Rule: no new code in a file over 2,000 lines.

### 3.3 Move folders to match the product `[code — PRODUCT_LAYERS.md "Future Code Organization"]`
The target already exists in your own doc. Do it **after** 3.1–3.2, one folder per PR:
`Find/` (GlobalContext + ContextDock), `Ask/` (chat), `ActOnThis/` (selection), `Engine/`,
`Capabilities/`, `SharedUI/`, `Services/`.

### 3.4 One number for "is the AI getting better?" `[code — 10 §1 "what is thinner"]`
Turn the ~135 per-case eval tests into a **golden corpus**: 200 labelled requests
(sentence → expected app → expected route → expected verified outcome). Run offline, print a
**pass-rate**, store it per release. Ship only if the number did not drop.

### 3.5 CI that protects `main`
`build.yml` builds but never tests. Add `./scripts/test.sh` to CI, run it on every PR, and
make it required. Add the golden-corpus pass-rate as a CI output.

### 3.6 Measure performance, don't assume it `[code — 10 §3 "unmeasured"]`
Add a signpost-based perf test: hotkey → first frame, keystroke → results, `test it` → first
visible step. Budgets: **<100 ms open, <16 ms per keystroke** `[guess]`. Fail CI on regression.

### 3.7 Freeze rule
From the day this plan is accepted until v1.0: **no new surface, no new spec** unless it
fixes a v1 checklist item (§5). New ideas go to `docs/IDEAS.md`, dated, untouched.

---

## 4. Trust plan (safety, security, privacy)

A tool that controls other apps must be *more* trustworthy than a normal app.

1. **Developer ID + notarization.** Replace the Apple Development identity in `ship.sh`. No
   more `xattr -cr` in the README. (Also closes the `get-task-allow` issue in `FOUND.md`.)
2. **Signed updates.** Replace the raw-DMG updater with Sparkle 2 (EdDSA-signed appcast), or
   at minimum verify a SHA-256 from the manifest **and** the Developer ID signature before
   opening. Today anyone who can push to `main` can ship code to every user.
3. **Close `FOUND.md`.** Item 5 (argv execution in `TerminalAIBridge`), item 7 escalation
   (high-risk action with `requiresApproval: false`), MCP cache key.
4. **Security review of the four sharp tools:** `run_command`, `send_keys`, `spawn_worker`,
   L2 scripts. Approval is the only gate — test that it cannot be skipped.
5. **Clipboard privacy.** Skip clips marked `org.nspasteboard.ConcealedType` (password
   managers); set a retention limit; add "Clear history".
6. **Correct the docs.** `10 §4` says the app is sandboxed — it is not (`ILauncher.entitlements`
   has no `app-sandbox` key). Say so, and say why (Accessibility control requires it).
7. **Privacy page.** One page: what stays local, what goes to which provider, when you are
   asked. It already exists in the README — publish it on the website too.

---

## 5. Definition of "product-ready" — the v1.0 checklist

Ship v1.0 when **every** box is ticked. Nothing else counts.

**Install & update**
- [ ] Developer ID signed, notarized, stapled DMG; opens with no warning on a clean Mac
- [ ] Signed updates (§4.2)
- [ ] Works on a clean user account, not just the dev Mac

**First run (target: success in under 2 minutes)**
- [ ] Welcome → Accessibility permission with a live "granted ✓" check
- [ ] Choose provider: on-device default, paste-a-key for cloud
- [ ] One guided task that succeeds and shows **✓ verified** (e.g. "make a note called Hello")
- [ ] Teaches the three hotkeys: Find, Ask, Act on this

**Quality**
- [ ] Golden-corpus pass-rate ≥ 85% `[guess]`, recorded per release
- [ ] Tests run and pass in CI on every PR
- [ ] Perf budgets met (§3.6)
- [ ] Crash-free sessions ≥ 99.5% over the private beta (opt-in crash reporting)

**Trust**
- [ ] §4 items 1–6 done
- [ ] No known issue where DoraX reports success for something that did not happen

**Clarity**
- [ ] README, `PRODUCT_LAYERS.md`, CLAUDE.md and `docs/master` use the same names and count
- [ ] 60-second hero video (§1.3) at the top of README and website
- [ ] In-app "Send feedback" (opens a prefilled GitHub issue with version + turn-log excerpt, user-approved)

---

## 6. Roadmap `[guess on durations — one person with AI agents]`

| Phase | Weeks | Goal | Done when |
|---|---|---|---|
| **0. Decide** | 1 | Owner accepts or edits §1–§2 | This doc is merged with owner's redlines |
| **1. Freeze & cut** | 2 | Labs switch, hide cut surfaces, delete the second brain (§3.1) | App launches with only Find / Ask / Act on this |
| **2. Trust** | 2–3 | §4 items 1–5, tests in CI (§3.5) | Clean Mac installs with no warning; CI green and required |
| **3. First run + hero** | 2 | §5 "First run", hero loop flawless, video recorded | 5 friends succeed in under 2 min without help |
| **4. Private beta** | 3 | 20–50 developers, opt-in telemetry, weekly fixes | Crash-free ≥ 99.5%, pass-rate tracked, top 10 complaints fixed |
| **5. Launch v1.0** | 1 | Show HN, r/macapps, X thread with the video | Checklist §5 fully ticked |
| **After** | — | Only then: split big files (§3.2), folders (§3.3), Labs → default one at a time, by usage data | — |

Roughly **10–12 weeks** to v1.0. The big-file refactor comes **after** launch on purpose:
users do not see file sizes, and refactoring before you know what users use risks polishing
code you will delete.

---

## 7. Business model (a starting position) `[judgment]`

- **Free during beta.** Bring your own key; on-device works with no key.
- **After v1.0:** free tier (Find + Act on this + on-device Ask) and a paid tier (~$8/month or
  one-time license `[guess]`) for cloud providers, saved workflows, Labs features.
- Decide pricing from beta data, not now. What matters now is that someone wants it.

---

## 8. How we work until v1.0

1. **One plan at a time.** This doc replaces the `docs/superpowers/` queue until v1.0; finish
   the Worker-layer Release-build blocker (brain issue #25) or move it to Labs, then start Phase 1.
2. **Every PR names the checklist box it ticks.** No box, no PR.
3. **Weekly one-line status** at the top of this file: phase, pass-rate, crash-free %, users.
4. **Ideas go to `docs/IDEAS.md`**, never straight into a spec.

---

## 9. Decisions only the owner can make

Answer these and the rest of the plan follows:

1. Is the one sentence in §1.1 right? If not, what is?
2. Is the first user Mac developers with coding agents? If not, who?
3. Do you accept cutting Media Dock and moving Second Brain / Workers / Plugins to Labs for v1?
4. Will you pay for an Apple Developer ID ($99/year)? Without it, §5 cannot be met.
5. Opt-in telemetry and crash reporting — yes or no? Without it you are guessing in the beta.
6. Open source, source-available, or closed? (README says "All rights reserved"; the update
   notes say "open-source beta" — these conflict.)

---

*Redline this file directly. Once §9 is answered, it becomes the roadmap and `10 §5` merges
into it.*
