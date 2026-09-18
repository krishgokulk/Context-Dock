# Actions that adjust instead of multiply

**Owner's ask (2026-09-18):** an action DoraX authored — "minimise after 5 min" — must be
*reused* the next time, with the new value, by both General Chat and the frontmost-app chat.
Not authored again. "Auto adjust this extension by choosing the best suited method, using its
own extension, without creating another one."

**What is true today.** `WorkflowAuthor`'s header already promises this: *"Next time the
same request resolves deterministically, through the ordinary route resolver, with no model
involved at all."* It cannot keep the promise because the runtime substitutes only
`{{query}}` — the whole sentence — and AX context. There is no `{{value}}`. "Minimise after
5 min" is saved with `sleep 300` baked in; "after 10 min" either matches by triggers and
silently sleeps 300, or authors a second action. Both are the failure.

Plugins solved this for themselves (`CD_VALUE`, `PluginEnvironment`). Adapter actions never
got it.

**Order: A, then B, then C = A+B together.** A is deterministic and testable without a
provider. B spends a model turn and belongs after A exists to fall back to. The stable-id rule
in `AdapterActionProposalInstaller.stableID` — byte-for-byte the original — is what makes B's
"replace, never duplicate" safe.

---

## A — Parameterise at authoring time (no model on reuse)

```
"minimise after 5 min"
  └─ WorkflowAuthor: "a quantity that may change → {{value}}"
       action.script       = "sleep {{value}}; osascript …"
       action.valueLabel   = "seconds"     action.valueDefault = "300"

"minimise after 10 min"
  └─ triggers match the saved action
  └─ ActionValue.extract("minimise after 10 min", label: "seconds") → "600"
  └─ inject {{value}} → sleep 600 — no model, no new action
```

- [x] **A1 `ActionValue`** — done, `5dce051`. — pure. `extract(from: sentence, label:) -> String?`: a number with
      an optional unit, normalised to the label's unit. `"10 min"`→`600` for `seconds`;
      `"2 hours"`→`7200`; `"50%"`/`"50 percent"`→`50` for `percent`; bare `"10"`→`"10"`;
      nothing → nil. Word numbers `"five"`→`5` for one..twenty. Tests first.
- [x] **A2 `AdapterAction.valueLabel` / `valueDefault`** — done, `e7fdd35`. — optional, `decodeIfPresent`, keys
      added to `CodingKeys` so the synthesised encoder writes them. Round-trip test; an
      existing JSON without the keys decodes unchanged.
- [x] **A3 `{{value}}` in `inject`** — done, `532d730`; script files get `$CD_VALUE` too. — substituted from an explicit value, else the default.
      `AppAdapterManager.execute` gains `value: String?`; `ChatRouteResolver.run` and
      `GeneralAIActionExecutor.executeAdapterRoute` pass `ActionValue.extract(query, label)`.
- [x] **A4 Authoring** — done, `d653250`. — `WorkflowAuthor`'s prompt teaches `{{value}}` + `"value":
      {"label":…,"default":…}`; `Proposal`, `ExtensionProposalData` and
      `AdapterActionProposalInstaller.action(from:)` carry it. Test: a proposal with a value
      becomes an action with `valueLabel`/`valueDefault`; one without stays exactly as before.
- [x] **A5 The confirmation says it** — done, `d653250`. — "*Minimise after a delay* saved to *Finder*. Say a
      different number next time and it uses that." Only when a value exists.

## B — Adjust on reuse, via the model (structural changes)

```
"minimise after 10 min and then mute"
  └─ triggers match the saved action; ActionValue covers "10 min"; "and then mute" does not
  └─ WorkflowAuthor.revise(existing:, request:) → new script
  └─ diff card: what changes, approve
  └─ saved under the SAME stableID → replaces, never a second one
```

- [ ] **B1 `WorkflowAuthor.revise`** — takes the existing action and the new request, returns
      a `Proposal` whose `name` is the existing name (so `stableID` matches). Prompt: change
      only what the request changes; keep `{{value}}` if present.
- [ ] **B2 The decision** — pure. `ActionReuse.decide(existing:, request:)`:
      `.run(value:)` when the sentence differs only by a value the action declares;
      `.revise` when it differs otherwise; `.author` when nothing matches. Tests are the three
      sentences above plus "minimise after 5 min" again → `.run(value: nil)`.
- [ ] **B3 Diff card** — the Install card, reused: shows old vs new script. Approving calls
      the installer, which replaces by id. Both surfaces get it for free (the corner now has
      the callback).

## C — Both wired, the resolver chooses

- [ ] **C1** `ChatRouteResolver` / the General Chat read path consult `ActionReuse.decide`
      before ever calling `WorkflowAuthor.propose`. Authoring is the last resort, as the
      header always said.
- [ ] **C2** Eval cases, from the owner's sentences: "minimise after 5 min" (author);
      "minimise after 10 min" (run, 600); "minimise after five minutes" (run, 300);
      "minimise after 10 min and then mute" (revise, same id); "minimise now" (run, default?
      — owner's call: default or ask).

## Not doing

- No second placeholder syntax. `{{value}}` matches `{{query}}`; plugins keep `CD_VALUE`.
- No unit conversion beyond seconds / minutes / hours / percent / plain count. A unit the
  extractor does not know is passed through as typed.
- No silent revise. B always shows the diff.
