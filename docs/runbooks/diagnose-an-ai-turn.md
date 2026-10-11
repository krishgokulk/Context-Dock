# Runbook — diagnose an AI turn

Status: current · Last checked: 2026-10-02 · Describes: the turn log in the app's chat pipeline

**OSLog is not reliable here.** On the development Mac, notice-level logging from third-party
processes is not persisted — a marker emitted from a separate process under this app's
subsystem never reaches the store either, so every `log.notice("stage: …")` in the chat
pipeline is invisible. That is a `sudo log config` setting on the machine, not an app bug, and
chasing a chat bug without knowing it cost a day.

Use the app's own turn log instead. Off by default, because it names the apps and questions
somebody asks:

```bash
defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
tail -f ~/Library/Application\ Support/Context-Dock/turns.log
```

It records the two facts that settle most "why did it not do that" questions: the provider a
turn ran on and whether it carries native tools, and the exact tool names sent to the model.
A provider without native tools (Claude Code, Apple Intelligence) is handed none of DoraX's
tools by design — it answers, the app acts.

## The per-turn record (`turn.trace`)

Each turn also writes one line `turn.trace {json}` (`Services/TurnRecorder.swift`, #150): what
the turn cost and did. Field names follow the OpenTelemetry GenAI conventions where one exists
(`gen_ai.*`, `error.type`); DoraX's own fields are `dorax.*`.

| Field | Meaning |
|---|---|
| `gen_ai.provider.name`, `gen_ai.request.model` | Provider and model the turn ran on |
| `dorax.tools.sent`, `dorax.tools.called` | Tools offered (no repeats) and called (in order) |
| `dorax.rounds[]` | Per round: `gen_ai.usage.input_tokens` (all input, cached included), `…cache_read.input_tokens`, `…cache_creation.input_tokens`, `…output_tokens`, tool calls, finish reason, streamed, duration |
| `gen_ai.usage.*` at the top | Totals over the rounds that reported them; absent means unknown, not zero |
| `dorax.prompt.section_chars` | Characters per prompt section: `system`, `history`, `message`, `tools` (schema JSON), and the scoped sections (`identity`, `memory`, …) |
| `dorax.verifier.fires` | Answer checks that sent the model back (`evidence_sufficiency`, `answer_verifier.*`, `fresh_result_evaluator`) |
| `dorax.fallbacks` | Lesser paths taken (`stream_to_buffered`, `on_device_plain_path`) |
| `dorax.passes` | Provider calls in the turn; a verifier pass is a second one |
| `dorax.time_to_first_token`, `gen_ai.client.operation.duration` | Seconds to the first streamed fragment (or first response), and in total |

It never carries the question, the answer or any prompt text. A streamed OpenAI-shaped round
reports no usage, so its counts are absent.

```bash
python3 scripts/turn-cache-ratio.py            # cache-read ratio over the last 50 records
```
