# Pocket Agent (generated)

A foundations-first LangGraph agent built incrementally (M0-M14) plus a
`create_agent` alternative track. Generated and self-verified by
`scripts/build_pocket_agent.sh`.

## Model modes
Runs in deterministic **mock mode** with no API keys (verifies all wiring:
the agent<->tools cycle, SQLite persistence, HITL interrupts, streaming).
For local real answers, use LM Studio with the validated model:
`qwen/qwen3.5-9b`, `ctx=4096`, `gpu=max`, `parallel=1`. The repo root
`lmstudio.cmd` launcher applies those defaults through `scripts/overnight_lmstudio.sh`.
Provider keys also work: set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (or
`POCKET_USE_OLLAMA=1`) for real answers and the `create_agent` track.

## Run
```powershell
python verify_milestones.py     # re-run the milestone self-tests -> BUILD_REPORT.md
pytest -q                       # unit tests (tools + routing)
python -m pocket_agent.cli      # interactive chat
```

CLI prompts validated manually:
```text
what is 1234 * 5678?
my name is Ada
what is my name?
save this note: LangGraph state is checkpointed
y
read my notes
```

## Server / Studio (section 8)
`langgraph.json` exposes two graphs: `pocket_agent` (plain) and
`pocket_agent_hitl` (human-approval gate on `save_note`). The dev server
supplies its own persistence, so the graphs are compiled without a checkpointer
(HITL `interrupt()` still works — the server provides the checkpointer at run time).
```powershell
$env:PYTHONIOENCODING='utf-8'      # avoids Windows console encoding issues
pip install "langgraph-cli[inmem]"   # already installed by the builder
langgraph dev --no-browser           # serves http://127.0.0.1:2024
```
Drive the running server from Python via the SDK:
```python
from langgraph_sdk import get_sync_client
client = get_sync_client(url="http://127.0.0.1:2024")
thread = client.threads.create()
for chunk in client.runs.stream(
        thread["thread_id"], "pocket_agent",
        input={"messages": [{"role": "user", "content": "what is 21 * 2?"}]},
        stream_mode="values"):
    print(chunk.data)
```

See `docs/project/manual_validation.md` for the recorded CLI + server walkthrough.

## Middleware & structured output (create_agent track, §7+)
`alt_create_agent/middleware_showcase.py` builds the same agent on the
high-level `create_agent` with a provider-agnostic middleware stack (PII
redaction, tool/model call limits, summarization, human-approval gate) plus a
custom `NoteGuardMiddleware` (`before_model` + `wrap_tool_call` guardrail) and a
Pydantic `response_format`. The custom-hook logic and keyless compilation are
verified in mock mode (**M9**); the structured answer + live middleware
behaviour run when a model is configured.

> M4 deliberately uses the v3 event-streaming API as the primary driver, with
> the stable `stream_mode` / `invoke` path as an automatic fallback.

## Stretch features (Phase 2)
- **Semantic search (M10)** — `pocket_agent/semantic.py`: an `InMemoryStore` with
  a vector `index={dims, embed, fields}`, so `store.search(ns, query=...)` returns
  scored matches. Keyless by default (a deterministic hashing embedder); set
  `POCKET_EMBED_MODEL` (+ provider env, optional `POCKET_EMBED_DIMS`) for real
  embeddings (LM Studio / Ollama / OpenAI). `pip install numpy` for faster vectors.
- **DeltaChannel (M11, beta)** — `pocket_agent/delta_demo.py`: attach
  `Annotated[list, DeltaChannel(reducer)]` to a state key; the channel stores only
  a sentinel per checkpoint and replays writes, so blob size stays ~constant as the
  value grows (vs the full snapshot a normal reducer channel stores each step).

## Production-style depth (Phase 5)
- **Postgres persistence/store (M12)** — `pocket_agent/persistence.py` keeps
  Postgres optional and explicit. Install with `pip install .[postgres]`, set
  `POCKET_POSTGRES_URI`, and optionally set `POCKET_POSTGRES_SETUP=1` to create
  LangGraph tables before running the verifier. Live validation passed against
  Docker Postgres; use `open_postgres_graph(...)` as a context manager so handles
  stay open while the graph runs.
- **Node caching (M13)** — `pocket_agent/cache_demo.py` shows a single
  `CachePolicy(ttl=...)` node compiled with `InMemoryCache`.
- **Custom stream projection (M14)** — `pocket_agent/stream_projection.py`
  defines a v3 `StreamTransformer` that projects node progress into a named
  `custom:progress` stream channel.
