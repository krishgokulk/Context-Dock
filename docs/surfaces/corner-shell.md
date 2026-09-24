# Corner shell — behaviour log

> **Status: current.** One line per Corner behaviour fix: what now holds, and the test that pins it.
> Spec: [`docs/master/00-DOCK-AND-CORNER.md`](../master/00-DOCK-AND-CORNER.md) ·
> parity list: [`docs/master/00-DOCK-PARITY-INVENTORY.md`](../master/00-DOCK-PARITY-INVENTORY.md).

- 2026-09-24 · Clicking a running app whose windows are minimised restores them, as the Dock does (`AppActivation.raiseSteps` → `WindowManagementService.restoreAfterActivate`) · `CornerAppActivationTests`
- 2026-09-24 · A pinned folder's preview card fills its slot (no side gutters); its header has expand (360×320 → 560×480) and pin (stays up while the pointer moves on) · `CornerPinPreviewCardTests`
- 2026-09-24 · Pins and plugin tiles stay at the trailing end while Global Context's field is open: the dock and its field are one shell (`bcdcb91`, `8143051`), which replaced #79's scaled-strip version · `AppChatPromptMetricsDockTests`
- 2026-09-24 · Navigation is the Dock's (`CornerNavigation`): ←/swipe right into General Chat from Global or the app, →/any sideways swipe back to where it came from; ↑/↓ and vertical swipes move Global ↔ app; swipes keep typed text, read momentum once, stand down while scoped into an app and over a transcript · `CornerScopeWalkTests`, `CornerChatPresentationTests`
