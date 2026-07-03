# Pocket Agent Sandbox Launcher

`launch_sandbox.ps1` is a single root-level launcher that opens a localhost web
page for this project.

```powershell
.\launch_sandbox.ps1
```

It starts a tiny Python stdlib HTTP server on `http://127.0.0.1:8765`, opens the
browser, and serves the modular app in `sandbox/`.

Current layout:

```text
launch_sandbox.ps1          # thin root launcher and process management
sandbox/server.py           # localhost API, graph/tool/HITL/provider endpoints
sandbox/static/index.html   # browser markup
sandbox/static/styles.css   # browser styles
sandbox/static/app.js       # browser state and interactions
```

Runtime PID and log files still live under `pocket-agent/.build_tmp/` and
`pocket-agent/logs/`, which are ignored by git.

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
- Docs/reference panel that reads local markdown files directly, so users can
  browse project capabilities, roadmap state, build results, and LangGraph
  reference notes without asking the model.
- LM Studio controls:
  - **Check Model** refreshes the local model state.
  - **Load Default Model** loads the project default model using the same
    defaults as `scripts/overnight_lmstudio.sh`: `qwen/qwen3.5-9b`,
    `ctx=4096`, `gpu=max`, `parallel=1`, `ttl=28800`.
- Capability summary: tool cycle, memory, HITL, streaming, Server/Studio, and
  depth demos.
- Sandbox area with two modes:
  - **Pocket Agent graph**: imports and runs the repo's graph locally.
  - **Direct provider chat**: calls the selected provider API directly.
- Conversation UI with browser-side message history, loading state, copy-last
  action, and thread reset. Graph mode keeps one thread id until reset so memory
  behavior is easier to observe.
- Graph-mode chat streams through `/api/agent/stream` using newline-delimited
  JSON. The browser shows graph progress updates while the run is active, then
  replaces the pending assistant message with the final answer.
- Direct tool UI for the repo's actual local tools:
  - calculator
  - current time
  - save note
  - read notes
  Tool results appear in the tool result area and are also appended to the
  conversation transcript.
- HITL save-note demo: starts the graph with the human approval gate enabled,
  pauses before `save_note`, then resumes from browser **Approve** or **Reject**
  buttons. This demo compiles the committed graph in deterministic mock mode so
  the interrupt/resume path is reliable and independent of live model behavior.
- Project-summary questions return a deterministic local summary, so the answer
  stays aligned with the repo instead of depending on provider memory or saved
  notes. These known local facts are answered before any model/provider call.
- Basic "what is LangGraph?" prompts also return a deterministic local answer,
  so the sandbox remains useful when LM Studio is offline and graph mode falls
  back to mock mode.

## Provider Paths

The sandbox keeps provider code dependency-free by using Python's standard
library HTTP client.

| Provider | Path |
|---|---|
| LM Studio | OpenAI-compatible `POST /v1/chat/completions`, default base `http://localhost:1234/v1`. |
| OpenAI / GPT | OpenAI-compatible `POST /v1/chat/completions`; the user supplies an API key and model id. |
| Anthropic / Claude | `POST https://api.anthropic.com/v1/messages`; the user supplies an API key and model id. |
| Google Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`; the user supplies an API key and model id. |
| Other OpenAI-compatible | User supplies base URL, optional API key, and model id. |

API keys are only forwarded to the localhost server for the current request and
are not written to disk by the launcher or sandbox server.

The LM Studio load action shells out to the local `lms` CLI. If the default
model is already loaded with the expected settings, it is a no-op. If the
default model is loaded with different context/parallel settings, the launcher
unloads and reloads that default model with the project settings.

The direct tool UI calls `/api/tool`, which imports the committed
`pocket_agent.tools` module and invokes only the whitelisted tools. It uses the
same sandbox notes file as graph mode: `pocket-agent/.build_tmp/sandbox_notes.json`.

The HITL UI calls `/api/hitl/start` and `/api/hitl/resume`. Approval resumes the
same interrupted graph run with `Command(resume=True)` and persists the note.
Rejection resumes with `Command(resume=False)` and leaves the note unsaved.

The streaming chat endpoint calls `graph.stream(..., stream_mode="updates")`
and emits `start`, `update`, `final`, and `error` events as NDJSON. It reuses the
same cached graph and thread id as the normal graph chat path.

The docs/reference panel calls `/api/docs/reference`. The endpoint is read-only
and uses a fixed allowlist of repo files:

- `docs/project/roadmap.md`
- `docs/project/AI_context.md`
- `docs/project/sandbox_launcher.md`
- `docs/reference/LangGraph_Information_Bank.md`
- `pocket-agent/BUILD_REPORT.md`

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

Latest review date: 2026-07-04.

Findings:

- No blocking code bugs found in the reviewed core graph, tools, CLI, provider
  selection, Postgres helpers, semantic store, server graph, or tests.
- The sandbox was refactored out of a large embedded PowerShell string and into
  modular `sandbox/` files while preserving the same root launch command.
- One stale documentation signal was found: Phase 6 was still marked partial in
  the roadmap and AI context even though its checklist was complete. This was
  corrected with the sandbox docs update.
- The generated `pocket-agent/` rule remains important: durable edits inside
  that tree must be made in `scripts/build_pocket_agent.sh`, then regenerated.

Validation performed for the launcher:

- Syntax check with PowerShell parser.
- Python compile check for `sandbox/server.py`.
- Start the sandbox without opening a browser.
- Fetch `/api/status`.
- Fetch `/api/docs/reference` and verify the browser docs panel renders.
- Exercise `/api/lmstudio/status`.
- Confirm the **Load Default Model** browser action is wired to
  `/api/lmstudio/load-default`. The 2026-07-04 cleanup pass did not invoke it
  live because `lms ps` reported no loaded models, so calling it would mutate
  the local LM Studio process.
- Exercise `/api/tool` for calculator, time, save note, and read notes.
- Exercise `/api/hitl/start` and `/api/hitl/resume` for approve and reject.
- Exercise `/api/agent/stream` and verify the browser receives start/update/final
  events.
- Exercise chat history, loading completion, copy-last readiness, and thread
  reset behavior.
- Exercise the direct LM Studio provider path.
- Exercise the Pocket Agent graph path.
- Verify that "What can this project demonstrate?" returns a grounded project
  summary instead of asking for saved notes.
- Verify that "what is langgraph" works after a prior graph request and does not
  hit a cached-graph `SYSTEM_PROMPT` scoping error.
- Stop the sandbox through the launcher.
