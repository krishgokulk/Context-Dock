# Runbook — diagnose an AI turn

Status: current · Last checked: 2026-09-24 · Describes: the turn log in the app's chat pipeline

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
