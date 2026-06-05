# Pocket Agent — Roadmap

> **Vision:** a local-first, hand-built LangGraph agent that *exercises and verifies every core
> primitive* the Foundations Project Plan set out to teach — state, nodes, edges, the Pregel loop,
> persistence, memory, streaming, and human-in-the-loop — plus the modern high-level `create_agent`
> path, all running on **local models via LM Studio** with **zero paid APIs**. The goal is
> understanding the primitives, not shipping a product.

---

## Status at a glance

- **As of:** 2026-06-05
- **Headline:** core project **complete and self-verified** — last run **9/9 milestones PASS, 7/7 unit tests PASS, 0 failed / 0 skipped** against LM Studio `qwen/qwen3.5-9b` (real tool calls), plus an 8/8 keyless mock run.
- **Stack:** langgraph 1.2.4 · langchain 1.3.4 · langchain-openai 1.2.2 · Python 3.13 · Win11 / RTX 4060 (8 GB).

**Required project (plan's definition of done, M0–M5):**
`██████████` **100%** ✅ done — *and exceeded* (stretch M6–M7 + the `create_agent` track also pass).

**Full vision (incl. all optional tracks + polish):**
`██████░░░░` **~60%** — core + basic stretch done; depth tracks (Studio, middleware, semantic search, Postgres) remain.

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
| **2 — Stretch primitives (M6–M7)** | Long-term `Store`, time-travel | 🟡 partial |
| **3 — High-level path (§7)** | `create_agent` + middleware | 🟡 partial |
| **4 — Server & Studio (§8)** | `langgraph dev`, `langgraph.json`, Studio, SDK | ⬜ todo |
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

### Phase 2 — Stretch primitives (M6–M7) 🟡
- ✅ **M6** long-term `Store` — `InMemoryStore` put/get/prefix-search, graph compiles with `store=`
- ⬜ **M6+** semantic search — `InMemoryStore(index={embed,dims,fields})` (can use LM Studio `nomic-embed`)
- ✅ **M7** time travel — `get_state_history`, replay from a prior `checkpoint_id`
- ⬜ **M7+** `DeltaChannel` (beta) storage-growth demo

### Phase 3 — High-level path (§7) 🟡
- ✅ `create_agent` behavioral parity — `langchain.agents.create_agent` with the same tools + SQLite checkpointer
- ⬜ Prebuilt middleware showcase — `HumanInTheLoopMiddleware`, `SummarizationMiddleware`, `ModelCallLimitMiddleware`, `ToolCallLimitMiddleware`, `ToolRetryMiddleware`, `PIIMiddleware`, `LLMToolEmulator`
- ⬜ Custom middleware hook (`@before_model` / `@wrap_tool_call`) example
- ⬜ Structured output — `response_format=ToolStrategy/ProviderStrategy`

### Phase 4 — Server & Studio (§8) ⬜
- ⬜ Install `langgraph-cli[inmem]`
- ⬜ Author `langgraph.json` (graphs map, env, optional store index)
- ⬜ Run `langgraph dev`; open in Studio; confirm graph visualizes/runs
- ⬜ Call the local server via `langgraph-sdk` (`get_sync_client`, streaming run)

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

1. **Phase 4 — Server & Studio** *(highest learning value: lets you SEE the graph)*
2. **Phase 3 — middleware showcase** *(rounds out the §7 high-level track)*
3. **Phase 2 — semantic search + `DeltaChannel`** *(completes the stretch milestones)*
4. **Phase 5 — Postgres / caching / custom transformer** *(production-style depth)*
5. **Phase 6 — polish** *(interactive use, README, git, report text)*

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
