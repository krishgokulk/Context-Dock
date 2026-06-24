# AI Provider Manual QA

Run before AI-related release. Record provider, model, date, and failure details.

## Provider Matrix

Test configured providers:

- [ ] Apple On-Device Intelligence
- [ ] OpenAI API
- [ ] Anthropic API
- [ ] Gemini API
- [ ] Ollama
- [ ] OpenRouter preset
- [ ] LM Studio preset
- [ ] Generic OpenAI-compatible endpoint
- [ ] Apple Shortcuts

## Required Surfaces

For every configured provider:

- [ ] AI Chat answers a text query.
- [ ] Global Context answers using selected text.
- [ ] Global Context answers using dragged file metadata.
- [ ] Context Dock receives frontmost-app context.
- [ ] Extension AI request routes through `ExtensionAIAdapter`.
- [ ] Provider errors show actionable message without crash.
- [ ] Clearing API key prevents cloud request.
- [ ] Debug log contains `[AIProviderRouter]`.

## Multimodal

For vision-capable providers:

- [ ] PNG attachment returns image-aware answer.
- [ ] JPEG attachment returns image-aware answer.
- [ ] Multiple images preserve order.
- [ ] Unsupported file/PDF contents degrade to metadata/path warning.
- [ ] Missing attachment file fails safely without crash.

## OpenAI-Compatible

- [ ] OpenRouter preset sets endpoint and model.
- [ ] LM Studio preset sets local endpoint and requires model selection.
- [ ] Connection test performs compatible chat request.
- [ ] Local endpoint works without API key.
- [ ] Remote endpoint works with API key.
- [ ] Invalid endpoint returns actionable error.
- [ ] Empty model ID blocks request.
- [ ] Discover Models loads `/v1/models`, deduplicates IDs, and allows selection.
- [ ] Discover Models failure keeps manual model-ID entry usable.

## Safety

- [ ] Unknown capability ID rejects before execution.
- [ ] Medium/high-risk capability requires explicit approval.
- [ ] Capability, terminal, and private-cloud approvals expire after 60 seconds.
- [ ] Finder rename/move/copy preview shows selected files and before/after destinations.
- [ ] Provider Tool Calls QA performs simulation only and causes no local side effects.
- [ ] Critical terminal command blocks.
- [ ] Suggested terminal command uses `TerminalAIBridge` preview.
- [ ] Direct ChatGPT Plus or Claude Pro login is not offered.
- [ ] No browser-cookie or desktop-session extraction exists.

## Build Verification

- [ ] Debug build passes.
- [ ] Release build passes.
- [ ] `git diff --check` passes.
