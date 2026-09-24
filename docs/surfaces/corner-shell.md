# Corner shell — behaviour log

> **Status: current.** One line per Corner behaviour fix: what now holds, and the test that pins it.
> Spec: [`docs/master/00-DOCK-AND-CORNER.md`](../master/00-DOCK-AND-CORNER.md) ·
> parity list: [`docs/master/00-DOCK-PARITY-INVENTORY.md`](../master/00-DOCK-PARITY-INVENTORY.md).

- 2026-09-24 · Clicking a running app whose windows are minimised restores them, as the Dock does (`AppActivation.raiseSteps` → `WindowManagementService.restoreAfterActivate`) · `CornerAppActivationTests`
