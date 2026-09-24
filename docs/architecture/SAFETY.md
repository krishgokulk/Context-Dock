# What DoraX will and will not do

Written 2026-09-22. Two audiences, deliberately in one file so they cannot drift: the first half
is what a user needs to trust the app, the second is where each promise is enforced in code.

---

## Part one — for the person using it

**Nothing leaves your Mac except what you send to the AI provider you chose.** No DoraX server, no
telemetry, no account. Your notes, files, tabs and messages are read locally; only the part
relevant to your question goes to the model, and if you pick Apple Intelligence, nothing leaves at
all.

**A chat can only reach what it is about.** A Safari chat cannot read your Notes. If a question
needs another app, DoraX stops and offers to add it — one tap, and it says which apps it will add.
A conversation cannot widen its own scope.

**Anything that changes something asks first.** Creating a note, sending a message, running a
command, pressing a menu item, running a script: a card appears naming the app, the action and
exactly what it will do, and nothing happens until you answer it. Approval expires after a minute
of silence rather than sitting there.

**Some things are never done**, however they are asked for: sending, replying, forwarding,
deleting, emptying, trashing — these are never reached by DoraX driving your screen. They exist
only as explicit, approved actions.

**Driving your screen is off by default.** "Computer Use" — DoraX pressing menus the way you would
— has a master switch that is off, and then a per-app setting that is also off. Turn it on for one
app and the rest stay off. Off means off: no chat can talk you into it, and the switch is one
click in one place.

**Scripts an app carries are inert until you say otherwise.** If you import someone's agent pack,
its scripts arrive unable to run until you tick the box, and each run is approved separately.

**Reading is cheaper than photographing.** DoraX reads a page's text rather than screenshotting
it, because a screenshot captures whatever else is on screen. A screenshot is a last resort and
says so.

**You can see what it did.** Every answer carries the steps it took, the commands it ran and their
real output. If something says it was done, there is a receipt showing the read-back that proved
it.

---

## Part two — where each promise lives

### Scope: `GeneralChatScope` + `AppAccessPolicy`

Three levels per app, ascending: `awareness` (DoraX knows it exists), `menuOnly` (its published
menu commands), `adapter` (its tools). `AppAccessPolicy.allows(_:at:)` is asked before a route
runs — including for menus, because *a boundary that holds for tools and not for menus is not a
boundary*: a Safari chat once reached Notes by driving its menu bar, which is the same app
reached by a worse road and with no consent.

The access gate (`AppScopedChatService.appNeedingAccess`) runs **before any tool or capability
work**, so a question about an app outside the scope can never stall on a tool it was never
allowed to use. `AgentToolRegistry.capabilitiesInScope` drops other apps' capabilities from the
catalogue entirely — not ranked lower, *absent*, because a model shown a capability treats it as
available and "available but please do not use it" is an instruction, not a boundary.

### Consent: one approval centre

`AICapabilityApprovalCenter` publishes one pending request; the surface that asked draws it
inline, or a floating window appears when no surface can. Closing the window is a refusal.
Sixty seconds of silence is a refusal. One answer per request, enforced — a double-resolve used
to trap.

`ApprovalCenter` decides *where* a card is drawn so a question asked in the corner is not answered
on the dock behind it. `AdapterActionConsentStore` holds standing "always allow" grants, which
destructive actions never get.

### The denylist: `AppMenuConsentStore.isDestructive`

One list, three users: verified menus, Computer Use, and the offer filter. Local destruction
(`delete`, `empty`, `trash`) and outbound actions (`send`, `reply`, `forward`, matched as whole
words so "Shared Links" is not mistaken for sharing). Verified menus gate these behind approval;
**Computer Use refuses them outright**, because an approval card for a click resolved from a
phrase, on a tier whose whole purpose is acting where no route exists, is more trust than that
rung has earned.

`ActionReadiness` adds the intent rule: a destructive command is never *offered* for a
constructive request — "create a note" must not produce `Edit ▸ Delete Note` as a choice.

### Computer Use: two switches, then a card

`ComputerUseConsentStore` — a master switch (off) over a per-app tri-state (off / ask each step /
auto in task). Master off refuses in words and never shows a card, because a kill switch a chat
can talk you out of in one tap is not a kill switch. `ComputerUseTargetResolver` presses only what
the words name: disabled items skipped, ties refused, coverage thresholds in both directions, and
the denylist above applied first. Before and after the press, the app's windows are read and both
readings are reported, so the outcome is checked rather than claimed.

### Scripts: declared, fenced, approved

`AppAgentScript.resolve` refuses a name the app's `AGENT.md` does not declare (the folder is not a
menu), a name with a path in it, a symlink that resolves outside the folder, and a file that is
not executable. `AppAgentProfilePack.install` copies a pack's scripts **without** the executable
bit unless the importer asks for it. Each run is approved, and runs through the plugin runner:
stdin closed, pipes read before wait, timeout that terminates.

### Shell: classified, then gated

`TerminalAIBridge` classifies a command before it runs and shows it verbatim on the card. The
registry points the model at a capability when one does the same job better —
`finder.trash` over `rm`, because one of those is recoverable and reads the result back.

### Unattended runs

`AICapabilityApprovalCenter.refusesEveryApprovalUnattended` — while an external agent drives DoraX
over MCP, every approval is refused without being shown and what was asked is recorded. An agent
looping over fifty eval questions cannot send mail because a sheet resolved on its own with nobody
at the keyboard. It also makes evaluation better: the question becomes "was the right approval
requested?", which DoraX owns, rather than "did the side effect happen?", which depends on a
person.

### Privacy at the provider boundary

`AIPrivacyApprovalCenter` asks before private context is sent to a provider. `AIContextBudget`
decides how much reference material a turn may carry at all (1 500 characters on-device, 12 000
for cloud), and compaction is query-relevant rather than "the first N bytes", so less is sent and
what is sent is the part that matters. `AITokenLedger` records what each turn actually cost.

### Honesty as a safety property

`AgentAnswerVerifier` checks an answer against what ran and refuses claims of work nobody did.
Receipts carry the read-back. `EvidenceSufficiency` decides whether a turn has enough to answer
at all. This is in the safety document deliberately: **an app that quietly reports work it did not
do is unsafe in the way that matters most**, because every other protection here assumes the user
can believe what they are told.

---

## What is not protected, and should be known

- **A profile narrows; it cannot widen.** An `AGENT.md` cannot grant an app a capability
  `AppAccessPolicy` denies. It can, however, tell the model to prefer a route — so a badly written
  profile is a quality problem, not a permission one.
- **The provider sees what the prompt carries.** Scoping decides what goes in; once it is in, it
  is in that provider's hands.
- **A page is untrusted input.** Text read from a web page is data, never instructions. This holds
  today because the page text is placed as evidence rather than as a system instruction — but
  there is no parser enforcing it, and any browser-driving feature must keep that boundary
  explicit. (See the open browser-automation work.)
- **Screen Recording and Accessibility are macOS grants**, not DoraX's. DoraX asks the system and
  reports honestly when it does not have them.
