# Apple Foundation Models — 3rd generation: adoption brief

Source article: <https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models>
Scope: what the 3rd-gen Apple Foundation Models change **for this app's on-device path**, and what to do about it. Decision doc, not a migration guide — there is no API migration to do.

> Confidence tags are used below because the primary article is unreachable from the
> environment this brief was written in (egress block on `machinelearning.apple.com`).
> Facts are reconstructed from Apple's 2025 tech report and secondary coverage.
> `[Certain]` = grounded in this repo's own code. `[Likely]` = strong inference from
> Apple's published material. `[Guessing]` = gap-filling, verify before relying on it.

---

## TL;DR

- **There is no framework migration.** `[Certain]` The app is already on the gen-3 API
  surface: `SystemLanguageModel.default`, `LanguageModelSession`, `respond(to:)`,
  `streamResponse(to:generating:)`, `Tool`. Gen-3 ships the *model*, not a new framework.
- **The one capability gap worth closing: native on-device vision.** `[Likely]` The gen-3
  ~3B on-device model is multimodal (image understanding). This app still feeds images to
  the model as **OCR-extracted text**, which was correct for a text-only model and now
  discards what the model can see (layout, objects, charts, non-text imagery).
- **Everything else is free or not worth adopting.** Multilingual quality and the server
  (PT-MoE) model are server-side — no code. Re-adopting `@Generable` structured output is a
  regression the team already reversed on purpose; leave it.

---

## What gen-3 actually is

- **On-device model:** `[Likely]` ~3B params, Apple-silicon-tuned via KV-cache sharing and
  2-bit quantization-aware training. Now **multimodal** — adds vision (image understanding).
  Apple reports image-understanding preference over the prior generation ~61% of the time.
- **Server model (Private Cloud Compute):** `[Likely]` Parallel-Track Mixture-of-Experts
  (PT-MoE) transformer; ViT-g vision backbone aligned to the LLM decoder. Not reachable as a
  developer API — surfaced through system features, not the Foundation Models framework.
- **Multilingual + multimodal training corpus.** `[Likely]` Broader language coverage than
  gen-2; improves quality on the same API with no code change.
- **Framework (Foundation Models / "Swift Foundation Models"):** `[Likely]` Same three
  developer affordances as gen-2 — **guided generation** (`@Generable` / `@Guide`),
  **tool calling** (`Tool`), and **LoRA adapter** fine-tuning. The gen-3 announcement is
  about model quality and modality, not new framework types.

**Takeaway:** for a third-party app, gen-3 is a *model upgrade the user's OS delivers*, plus
one new input modality (vision) the app must opt into. It is not a rewrite.

---

## What this app does today (grounded)

All on-device work runs through `Context-Dock/AI/AIProviderService.swift` and
`Context-Dock/Services/OnDeviceToolBridge.swift`, gated on `macOS 26.0`
(deployment target is macOS 26.1 per `CLAUDE.md`).

| Concern | Where | Today |
|---|---|---|
| Session creation | `AIProviderService.onDeviceSession(for:)` — `AIProviderService.swift:1128` | `LanguageModelSession(instructions:)`, availability-checked via `SystemLanguageModel.default`, cached per system-prompt. `[Certain]` |
| Plain response / stream | `sendToOnDevice` (`:838`), `streamOnDeviceResponse` (`:950`) | `respond(to:)` and `streamResponse(to:generating: String.self)`. `[Certain]` |
| Tool calling | `OnDeviceToolSession` — `OnDeviceToolBridge.swift` | `Tool`-conforming types (`OCRTool`, screen-capture, app-menu tools). `[Certain]` |
| **Images → model** | `onDeviceImageContentBlock` (`AIProviderService.swift:1083`); tool path `OnDeviceToolBridge.swift:1269` | **OCR only.** `VNRecognizeTextRequest` extracts text and prepends it as a string; images with no text hit the fallback `"No readable text detected. Use the image file metadata only."` (`:1113`). `[Certain]` |
| Structured output | `Services/OnDeviceStructuredStubs.swift` | `@Generable` was **removed** in favour of a deterministic keyword parser "that works on every macOS version without Apple Intelligence" (file header). `[Certain]` |

The tell: `OnDeviceToolBridge.swift:1229` documents the image path as
"*OCR text is prepended to the prompt for on-device multimodal context*." With gen-3, OCR is
**not** the multimodal context — the model's own vision is. That comment now describes a
workaround, not the capability.

---

## Adoption decisions

| gen-3 capability | Recommendation | Why |
|---|---|---|
| **Native on-device vision** | **Adopt.** Pass images as native image inputs to `LanguageModelSession`; keep OCR as fallback only. | The single real gap. OCR-only throws away everything the gen-3 vision model was added to read. `[Likely]` |
| Multilingual quality | **Nothing to do.** | Server/model-side; same API benefits automatically. `[Likely]` |
| Server PT-MoE model | **Nothing to do / not exposed.** | Not a third-party developer API. `[Likely]` |
| `@Generable` structured output | **Do NOT re-adopt.** | The team removed it on purpose for pre-macOS-26 portability (`OnDeviceStructuredStubs.swift`). Gen-3 doesn't change that trade-off. `[Certain]` on the removal; `[Likely]` on it still being the right call. |
| LoRA adapter fine-tuning | **Skip for now.** | Heavy (training + adapter shipping + per-OS compatibility). No current product need identified. `[Guessing]` |

---

## The one change worth making (described, not done)

**Goal:** when the on-device model is available *and* supports image input, hand it the image
directly instead of OCR text. Fall back to OCR when vision is unavailable (older OS, model
not downloaded, availability != `.available`).

Touch points, both currently OCR-only:

1. `AIProviderService.onDeviceImageContentBlock(from:)` — `AIProviderService.swift:1083`
   (plain + streaming paths).
2. `OnDeviceToolSession.stream(to:imageURLs:...)` image handling —
   `OnDeviceToolBridge.swift:1269`.

Shape of the change:

- Build the model prompt with the **image attached as a native input** (per the gen-3
  `LanguageModelSession` prompt/attachment API — confirm the exact type against current
  Apple docs before writing; `[Guessing]` on the precise symbol name).
- Keep `VNRecognizeTextRequest` OCR as an explicit **fallback branch**, not the default, so
  behaviour is unchanged on any OS/model where vision isn't present.
- Update the misleading comment at `OnDeviceToolBridge.swift:1229`.

**Explicitly out of scope of this brief:** writing that code. It cannot be compiled or run
in the environment this brief was produced in (Linux, no Xcode). Any implementation must be
built and tested on a macOS 26.1 machine via `./scripts/dev-run.sh` and verified by hand
against the running app (per `CLAUDE.md` — live-model behaviour is not in the test suite).

---

## Verification notes

- **Confirm the gen-3 image-input API against live Apple docs before coding.** This brief
  could not read the primary article; the vision-input symbol names are `[Guessing]`.
- **Availability is not binary "macOS 26 = vision."** `[Likely]` Check `SystemLanguageModel`
  availability/feature reporting at runtime; a user on macOS 26 without the model downloaded,
  or on hardware without vision support, must still get the OCR fallback.
- **Keep the OCR path.** It's the correct degraded mode and already handles the no-Apple-
  Intelligence case the rest of the app depends on.

---

## Sources

- [Introducing the Third Generation of Apple's Foundation Models — Apple ML Research](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models) (primary; unreachable from this environment)
- [Apple Intelligence Foundation Language Models Tech Report 2025 (arXiv 2507.13575)](https://arxiv.org/pdf/2507.13575)
- [Apple's third-generation Foundation Models explained — 9to5Mac](https://9to5mac.com/2026/06/11/apples-new-foundation-models-explained-on-device-ai-cloud-ai-and-everything-in-between/)
- This repo: `Context-Dock/AI/AIProviderService.swift`, `Context-Dock/Services/OnDeviceToolBridge.swift`, `Context-Dock/Services/OnDeviceStructuredStubs.swift`
