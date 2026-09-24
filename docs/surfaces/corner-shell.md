# Corner shell — behaviour log

> **Status: current.** One line per Corner behaviour fix: what now holds, and the test that pins it.
> Spec: [`docs/master/00-DOCK-AND-CORNER.md`](../master/00-DOCK-AND-CORNER.md) ·
> parity list: [`docs/master/00-DOCK-PARITY-INVENTORY.md`](../master/00-DOCK-PARITY-INVENTORY.md).

- 2026-09-24 · Clicking a running app whose windows are minimised restores them, as the Dock does (`AppActivation.raiseSteps` → `WindowManagementService.restoreAfterActivate`) · `CornerAppActivationTests`
- 2026-09-24 · A pinned folder's preview card fills its slot (no side gutters); its header has expand (360×320 → 560×480) and pin (stays up while the pointer moves on) · `CornerPinPreviewCardTests`
- 2026-09-24 · Opening Global Context's field keeps the strip's pins and plugin tiles beside it at field height; the shell widens by them, apps stay in the field's own pill, tools are not shown twice · `CornerStripBesideFieldTests`
