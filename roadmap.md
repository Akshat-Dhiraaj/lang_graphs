# Pocket Agent — Roadmap

> **Vision:** a local-first, hand-built LangGraph agent that *exercises and verifies every core
> primitive* the Foundations Project Plan set out to teach — state, nodes, edges, the Pregel loop,
> persistence, memory, streaming, and human-in-the-loop — plus the modern high-level `create_agent`
> path, all running on **local models via LM Studio** with **zero paid APIs**. The goal is
> understanding the primitives, not shipping a product.

---

## Status at a glance

- **As of:** 2026-06-07
- **Headline:** core project + Phases **4** (Server & Studio), **3** (middleware & structured output), and **2** (semantic search + `DeltaChannel`) complete and self-verified. Milestones now **M0–M11**. Last keyless mock run: **12/12 PASS, 1 skip** (ALT `create_agent`, needs a live model) + **15/15 unit tests**. Phase 4 also verified *live* (langgraph dev + SDK streaming run + HITL interrupt). The next LM Studio overnight run will exercise **M0–M11 + ALT** against `qwen/qwen3.5-9b`.
- **Stack:** langgraph 1.2.4 · langchain 1.3.4 · langgraph-cli 0.4.27 · langgraph-sdk 0.4.2 · Python 3.13 · Win11 / RTX 4060 (8 GB).

**Required project (plan's definition of done, M0–M5):**
`██████████` **100%** ✅ done — *and exceeded* (all stretch M6–M11, the `create_agent` track + middleware, and the Server/Studio track also pass).

**Full vision (incl. all optional tracks + polish):**
`█████████░` **~90%** — core + Server/Studio + middleware/structured-output + full stretch (semantic search, `DeltaChannel`) done; remaining: Phase 5 (Postgres, node caching, custom `StreamTransformer`) and Phase 6 (polish).

Legend: ✅ done & verified · 🟡 partial (basic done, sub-features open) · ⬜ not started

---

## What "done" means (end state)

The project is **complete** when every item below is implemented **and** demonstrably exercised (a passing acceptance check or a runnable demo), on local models:

1. **Core ReAct agent (M0–M5)** — graph mechanics, chat memory, durable SQLite persistence, the tool⇄agent cycle, v3 streaming, and a human-approval gate. *(required)*
2. **Stretch primitives (M6–M7)** — cross-thread `Store` **with semantic search**, and time-travel **with the `DeltaChannel` storage demo**.
3. **High-level path (§7)** — `create_agent` parity **and** a live demonstration of the prebuilt middleware catalog.
4. **Server & Studio (§8)** — the graph running behind `langgraph dev`, visible/runnable in Studio, callable via the SDK.
5. **Depth & production-style** — Postgres persistence, node caching, and a custom `StreamTransformer`.
6. **Polish** — driven interactively, a real README, version pins, and git history.

---

## Roadmap by phase

| Phase | Goal | Status |
|---|---|---|
| **0 — Foundations & harness** | Fact-checked docs; autonomous builder; local-model provisioning | ✅ done |
| **1 — Core agent (M0–M5)** | The hand-built ReAct agent, end to end | ✅ done |
| **2 — Stretch primitives (M6–M11)** | Long-term `Store` + semantic search, time-travel + `DeltaChannel` | ✅ done |
| **3 — High-level path (§7)** | `create_agent` + middleware | ✅ done |
| **4 — Server & Studio (§8)** | `langgraph dev`, `langgraph.json`, Studio, SDK | ✅ done |
| **5 — Depth & production-style** | Postgres, node caching, custom transformer | ⬜ todo |
| **6 — Polish & hands-on** | Interactive use, README, git, model exploration | 🟡 partial |

---

## Detailed checklist (concept → status)

### Phase 0 — Foundations & harness ✅
- ✅ Reference docs fact-checked vs official sources & corrected — `LangGraph_Information_Bank.md`, `LangGraph_Foundations_Project_Plan.md`
- ✅ Self-contained builder (scaffold + install + implement + self-verify) — `build_pocket_agent.sh`
- ✅ LM Studio orchestrator (hardware snapshot → load/tune model → sanity check → build) — `overnight_lmstudio.sh`
- ✅ PowerShell launchers — `build.cmd`, `lmstudio.cmd`
- ✅ Local model selected & validated for 8 GB VRAM — `qwen/qwen3.5-9b` (full GPU offload, tool calling confirmed)

### Phase 1 — Core agent (M0–M5) ✅ *(required — definition of done)*
- ✅ **M0** graph mechanics — `StateGraph`, `START`/`END`, `.compile()`, `.invoke()`
- ✅ **M1** model node + chat memory — `MessagesState`, `add_messages`
- ✅ **M2** durable multi-turn memory — `SqliteSaver`, threads, cross-thread isolation
- ✅ **M3** tools + the cycle — `bind_tools`, hand-written tool node, conditional edge, back-edge (real `calculator` call verified)
- ✅ **M4** streaming — v3 `stream_events` typed projections + stable fallback
- ✅ **M5** human-in-the-loop — `interrupt()` / `Command(resume=…)` approve & reject paths
- ✅ Unit tests — deterministic tools + routing function (`pytest` 7/7)

### Phase 2 — Stretch primitives (M6–M11) ✅
- ✅ **M6** long-term `Store` — `InMemoryStore` put/get/prefix-search, graph compiles with `store=`
- ✅ **M10** semantic search — `InMemoryStore(index={dims, embed, fields})` + `store.search(query=...)`; keyless deterministic embedder by default, real embeddings via `POCKET_EMBED_MODEL` (LM Studio / Ollama / OpenAI). Verified: query ranks the relevant docs first, with scores
- ✅ **M7** time travel — `get_state_history`, replay from a prior `checkpoint_id`
- ✅ **M11** `DeltaChannel` (beta) storage-growth demo — `Annotated[list, DeltaChannel(reducer)]`; verified deterministically that it reconstructs the same value as a full-snapshot channel while its checkpoint blob is only a sentinel, and that a DeltaChannel-backed graph accumulates correctly

### Phase 3 — High-level path (§7) ✅
- ✅ `create_agent` behavioral parity — `langchain.agents.create_agent` with the same tools + SQLite checkpointer
- ✅ Prebuilt middleware showcase — stack of `PIIMiddleware`, `ToolCallLimitMiddleware`, `ModelCallLimitMiddleware`, `SummarizationMiddleware` (`trigger`/`keep` form), `HumanInTheLoopMiddleware` (verified against the installed langchain 1.3.4 catalog, which is larger than the original 7)
- ✅ Custom middleware — `NoteGuardMiddleware(AgentMiddleware)` with `before_model` (idempotent system-note injection) + `wrap_tool_call` (blocks empty `save_note` without running the tool); deterministically unit-tested
- ✅ Structured output — `response_format=ShowcaseAnswer` (Pydantic); result surfaces under `structured_response` (`ToolStrategy`/`ProviderStrategy` available in `langchain.agents.structured_output`)
- ✅ New self-test **M9** (mock-safe: custom hooks + keyless `create_agent` compile with the full stack; live structured-output run when a model is configured)

### Phase 4 — Server & Studio (§8) ✅
- ✅ Install `langgraph-cli[inmem]` — now installed by the builder by default (opt out: `POCKET_SKIP_CLI=1`)
- ✅ Author `langgraph.json` (graphs map, env) — exposes `pocket_agent` + `pocket_agent_hitl`; module-form spec so package-relative imports resolve under the server loader
- ✅ Run `langgraph dev`; graph loads/runs in Studio — verified: server boots, both graphs load, Studio URL served
- ✅ Call the local server via `langgraph-sdk` (`get_sync_client`, streaming run) — verified end-to-end: streamed run drives the tool cycle to a final answer; the HITL graph interrupts awaiting approval
- ✅ New self-test **M8** in the harness (deterministic: langgraph.json parses, each graph imports to a *compiled* graph not the `(graph, mode)` tuple, SDK client importable)

### Phase 5 — Depth & production-style ⬜
- ⬜ Postgres persistence — `PostgresSaver` / `PostgresStore`
- ⬜ Node caching — `CachePolicy(ttl=…)` + `InMemoryCache()`
- ⬜ Custom `StreamTransformer` projection (or built-in `ToolCallTransformer`) under `stream.extensions`

### Phase 6 — Polish & hands-on 🟡
- ⬜ Drive the agent interactively — `python -m pocket_agent.cli`
- ⬜ Model exploration — try `google/gemma-4-12b`, `google/gemma-4-26b-a4b` (`POCKET_MODEL=… .\lmstudio.cmd`)
- ⬜ Real README + pinned `pyproject.toml`; `git init` with per-milestone commits
- ⬜ Fix the auto-report "Next steps" text (stale — still says "provide a model" though LM Studio is in use)

---

## Where we are today

**Working now (verified):** the full hand-built ReAct agent runs locally end-to-end — multi-turn memory, the tool loop with real tool calls, live token streaming, and a working human-approval gate — and the high-level `create_agent` reproduces it. Everything runs **keyless** (mock) for CI-style checks and against **LM Studio** for real answers.

**Run it:**
```powershell
.\build.cmd            # full build + self-verify  (auto-detects LM Studio)
.\build.cmd --check    # fast: regenerate + compile-check only
.\lmstudio.cmd         # load/tune the model first, then build
```

## Remaining work, prioritized

1. **Phase 5 — Postgres / node caching / custom `StreamTransformer`** *(production-style depth)*
2. **Phase 6 — polish** *(interactive use, README, git, report text)*

> Phases 4 (Server & Studio), 3 (middleware + structured output), and 2 (semantic search + `DeltaChannel`) are **done** and self-verified.

## Out of scope (per plan §1)

RAG / vector retrieval as a feature, multi-agent orchestration (supervisor/swarm — "where to go next" only), production deployment, and any paid external API beyond an optional LangSmith key.

---

## Artifacts

| File | Role |
|---|---|
| `roadmap.md` | this document |
| `LangGraph_Information_Bank.md` | fact-checked LangGraph reference |
| `LangGraph_Foundations_Project_Plan.md` | the source plan (milestones + acceptance) |
| `build_pocket_agent.sh` | self-contained builder + self-verifier |
| `overnight_lmstudio.sh` | LM Studio provisioning + build orchestrator |
| `build.cmd` / `lmstudio.cmd` | PowerShell launchers (call Git Bash) |
| `pocket-agent/` | the generated, working project (source, tests, venv) |
| `pocket-agent/BUILD_REPORT.md` | latest verification report |
