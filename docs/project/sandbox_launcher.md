# Pocket Agent Sandbox Launcher

`launch_sandbox.ps1` is a single root-level launcher that opens a localhost web
page for this project.

```powershell
.\launch_sandbox.ps1
```

It starts a tiny Python stdlib HTTP server on `http://127.0.0.1:8765`, opens the
browser, and serves an embedded HTML app. The generated temporary server file is
written under `pocket-agent/.build_tmp/`, which is already ignored by git.

Stop it with:

```powershell
.\launch_sandbox.ps1 -Stop
```

Useful options:

```powershell
.\launch_sandbox.ps1 -Port 8787
.\launch_sandbox.ps1 -NoBrowser
.\launch_sandbox.ps1 -Foreground
```

## What the Page Shows

- Short project objective.
- Current local status: git cleanliness, build report result, Python version,
  and LM Studio availability.
- Capability summary: tool cycle, memory, HITL, streaming, Server/Studio, and
  depth demos.
- Sandbox area with two modes:
  - **Pocket Agent graph**: imports and runs the repo's graph locally.
  - **Direct provider chat**: calls the selected provider API directly.
- Project-summary questions return a deterministic local summary, so the answer
  stays aligned with the repo instead of depending on provider memory or saved
  notes.
- Basic "what is LangGraph?" prompts also return a deterministic local answer,
  so the sandbox remains useful when LM Studio is offline and graph mode falls
  back to mock mode.

## Provider Paths

The launcher keeps provider code dependency-free by using Python's standard
library HTTP client.

| Provider | Path |
|---|---|
| LM Studio | OpenAI-compatible `POST /v1/chat/completions`, default base `http://localhost:1234/v1`. |
| OpenAI / GPT | OpenAI-compatible `POST /v1/chat/completions`; the user supplies an API key and model id. |
| Anthropic / Claude | `POST https://api.anthropic.com/v1/messages`; the user supplies an API key and model id. |
| Google Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`; the user supplies an API key and model id. |
| Other OpenAI-compatible | User supplies base URL, optional API key, and model id. |

API keys are only forwarded to the localhost server for the current request and
are not written to disk by the launcher.

## Sources Checked

- LM Studio documents OpenAI-compatible tool use through `/v1/chat/completions`
  and local server startup from the Developer tab or `lms server start`:
  <https://lmstudio.ai/docs/developer/openai-compat/tools>
- OpenAI documents Chat Completions as returning a response from a list of
  conversation messages:
  <https://developers.openai.com/api/reference/resources/chat>
- Anthropic documents the Messages API and the required `anthropic-version`
  header:
  <https://docs.anthropic.com/en/api/messages>,
  <https://docs.anthropic.com/claude/reference/versioning>
- Google documents Gemini `generateContent` and the `x-goog-api-key` header:
  <https://ai.google.dev/api>,
  <https://ai.google.dev/api/generate-content>

## Repo Gap Review

Latest review date: 2026-07-03.

Findings:

- No blocking code bugs found in the reviewed core graph, tools, CLI, provider
  selection, Postgres helpers, semantic store, server graph, or tests.
- The repo was clean before this change at commit `8d38af7`.
- One stale documentation signal was found: Phase 6 was still marked partial in
  the roadmap and AI context even though its checklist was complete. This was
  corrected with the sandbox docs update.
- The generated `pocket-agent/` rule remains important: durable edits inside
  that tree must be made in `scripts/build_pocket_agent.sh`, then regenerated.

Validation performed for the launcher:

- Syntax check with PowerShell parser.
- Start the sandbox without opening a browser.
- Fetch `/api/status`.
- Exercise the direct LM Studio provider path.
- Exercise the Pocket Agent graph path.
- Verify that "What can this project demonstrate?" returns a grounded project
  summary instead of asking for saved notes.
- Verify that "what is langgraph" works after a prior graph request and does not
  hit a cached-graph `SYSTEM_PROMPT` scoping error.
- Stop the sandbox through the launcher.
