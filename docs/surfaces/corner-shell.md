# Corner shell — behaviour log

> **Status: current.** One line per Corner behaviour fix: what now holds, and the test that pins it.
> Spec: [`docs/master/00-DOCK-AND-CORNER.md`](../master/00-DOCK-AND-CORNER.md) ·
> parity list: [`docs/master/00-DOCK-PARITY-INVENTORY.md`](../master/00-DOCK-PARITY-INVENTORY.md).

- 2026-09-24 · Clicking a running app whose windows are minimised restores them, as the Dock does (`AppActivation.raiseSteps` → `WindowManagementService.restoreAfterActivate`) · `CornerAppActivationTests`
- 2026-09-24 · A pinned folder's preview card fills its slot (no side gutters); its header has expand (360×320 → 560×480) and pin (stays up while the pointer moves on) · `CornerPinPreviewCardTests`
- 2026-09-24 · Pins and plugin tiles stay at the trailing end while Global Context's field is open: the dock and its field are one shell (`bcdcb91`, `8143051`), which replaced #79's scaled-strip version · `AppChatPromptMetricsDockTests`
- 2026-09-24 · Navigation is the Dock's (`CornerNavigation`): ←/swipe right into General Chat from Global or the app, →/any sideways swipe back to where it came from; ↑/↓ and vertical swipes move Global ↔ app; swipes keep typed text, read momentum once, stand down while scoped into an app and over a transcript · `CornerScopeWalkTests`, `CornerChatPresentationTests`
- 2026-09-24 · → on a focused row steps in (command panel, extension, CLI tool, app scope) and never runs a one-shot row — it put the Mac to sleep from "Sleep" (inventory D4) · `CornerRightArrowTests`
- 2026-09-24 · ↑ on an empty field with nothing highlighted goes up a layer before opening a list, so the app scope reaches Global by key (inventory F2) · `CornerRightArrowTests`
- 2026-09-25 · Typing from the resting strip keeps every letter: the field's focus no longer leaves the first one selected (shared `FieldCaret`, the Dock's old fix), and keys typed before it takes focus go into it · `FieldCaretTests`
- 2026-09-25 · The Selection card lists and runs the Dock's Selection rows (less Share) above its field, through `SelectionActionProviding` on the selection it captured; ↑/↓/↩, a visible ✕, AI rows answer in the corner chat · `CornerSelectionActionsTests`
- 2026-09-25 · The Selection card opens at once and fills its rows a moment later (no Share sources built for it); it stays open while pointed at or typed into; the hotkey on a new selection replaces the card; nothing selected says so · `CornerSelectionActionsTests`
- 2026-09-25 · The Selection card answers in place (shared `CornerTranscript`), with Replace (only with Computer Use, else copies), Copy and Quick Note at the end; rows that drive an app's UI run only with Computer Use, asking Allow once / Always in the card; Writing Tools hide without it · `CornerSelectionActionsTests`
- 2026-09-25 · Share in the Selection card: "Share Selection" lists the Mac's share destinations inside the card (every share extension, the Dock's frecency order, typed to narrow) and shares the captured selection; Share at the end of an answer shares the answer; Esc steps back · `CornerSelectionActionsTests`
- 2026-09-25 · One Esc steps back one layer in the Selection card: the field no longer acts on an Esc the corner's key monitor already took (it closed the card straight from the share list) · `CornerSelectionActionsTests`
- 2026-09-25 · Typed "send to …" in the Selection card: a send command leads the list ("Send to Gokula Kannan J via Messages"), Return runs the Dock's share router on the captured selection (contact lookup, Messages/Mail), never the AI, and the card says what happened · `CornerSelectionActionsTests`
- 2026-09-25 · Filtering the Selection rows is not a send command: only text that starts with a send word (send, share, email, mail, message, text, sms, airdrop) becomes "Send to …" — "copy text" had opened a Messages compose · `CornerSelectionActionsTests`
- 2026-09-25 · The answer's actions fit the card: labelled when they fit, icons alone when not (Share was cut off and the way back hidden) · `CornerSelectionActionsTests`
- 2026-09-25 · A Selection extension with side effects asks "Run · Cancel" inside the card (Return runs, Esc cancels) instead of a system alert that the keyboard could not reach; Return also answers the Computer Use question with Allow once · `CornerSelectionActionsTests`
