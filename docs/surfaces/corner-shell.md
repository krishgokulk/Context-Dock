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
