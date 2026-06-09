# Project Plan — "Pocket Agent": a foundations-first LangGraph build

> **Document status:** original plan, retained for reference. **It has since been fully implemented and exceeded** — see `roadmap.md` and `AI_context.md` for the current state (M0–M11 + the `create_agent`/middleware and Server/Studio tracks).
> **Intended reviewer:** a separate Claude Opus instance. This document is self-contained — it does not depend on any prior conversation.
> **Sourcing rule applied:** every technical claim, API name, import path, and signature below is taken from the official LangChain/LangGraph documentation (`docs.langchain.com`, `reference.langchain.com`) or the official PyPI listings. Third-party tutorials were not used as authorities. A "Sources" section at the end lists the exact pages.
> **Assumption rule applied:** this plan does not assume an environment, a model, or that any version number is still current at review time. Prerequisites are stated explicitly as requirements/decisions, and every version is marked "verify at review time."

---

## 0. How to review this document

Three things make this project unusual and warrant scrutiny:

1. **It is foundations-first but deliberately uses bleeding-edge surfaces.** The core track hand-builds a graph from primitives (to teach the fundamentals); the enhancement track layers in the newest LangGraph/LangChain APIs. Section 4 marks each technology's maturity (stable / experimental / beta) so nothing is presented as more settled than it is.
2. **One bleeding-edge dependency is explicitly experimental.** The v3 event-streaming API (`graph.stream_events(..., version="v3")`) is labeled by the official docs as "experimental and may change" / "in preview." This plan uses it as the primary streaming/driving API *by design*, with the stable `stream_mode` / `invoke()` path documented as the fallback. The reviewer should confirm this trade-off is acceptable for a learning project.
3. **A known constraint may bite at milestone 3:** tool calling requires a model that supports it, and the reviewer should check the model-selection decision in §3.

Open decisions requiring a reviewer opinion are collected in §11.

---

## 1. Objective and scope

Build a single, local-first **command-line agent** ("Pocket Agent") incrementally, where each milestone introduces exactly one new LangGraph concept. The end state is a tool-using conversational agent with durable memory, live streaming, and a human-approval gate. The goal is **understanding the primitives**, not shipping a product.

**In scope:** the LangGraph runtime primitives (state, nodes, edges, compilation, the Pregel execution model), persistence (checkpointers, threads, store), event streaming (v3), human-in-the-loop interrupts, and — as an explicit contrast — the high-level `create_agent` + middleware path.

**Out of scope:** RAG / vector stores, retrieval, multi-agent orchestration (mentioned only as a "where to go next"), production deployment, and any external paid API beyond an optional LangSmith key. Tools are deliberately tiny and deterministic so correctness is verifiable.

**Definition of done (whole project):** all milestones 0–5 pass their acceptance criteria (§6). Milestones 6–7 and the alternative track (§7) are optional stretch goals with their own criteria.

---

## 2. What the project demonstrates (concept coverage)

By completion the build will have exercised, with primary-source grounding:

- Graph construction: `StateGraph`, nodes as functions, normal + conditional edges, `START`/`END`, `.compile()`.
- State: `TypedDict` schema, reducers, the `add_messages` reducer, `MessagesState`.
- The Pregel execution model: super-steps, message passing (background context for *why* checkpoints land where they do).
- Conditional routing and **cycles** (the agent⇄tools loop — the defining LangGraph capability).
- Persistence: checkpointers, threads (`thread_id`), `StateSnapshot`, `get_state` / `get_state_history`, `update_state`, replay, durability modes.
- Short-term vs long-term memory: thread state vs the `Store` (cross-thread), incl. semantic search.
- Event streaming (v3): typed projections (`messages`, `values`, `output`, `interrupts`, `subgraphs`).
- Human-in-the-loop: the `interrupt()` function and `Command(resume=...)`; static breakpoints for debugging.
- The modern high-level path: `create_agent` and middleware (`HumanInTheLoopMiddleware`, etc.) — as a contrast to the hand-built version.

---

## 3. Prerequisites stated explicitly (no assumptions)

These are requirements/decisions, not assumptions. The builder must satisfy or decide each before milestone 0.

- **Python:** LangGraph requires Python `>=3.10` (current `langgraph` 1.2.x metadata; the older 3.9 floor was dropped); the official install/quickstart pages recommend **3.11+**. *Decision:* pin a specific 3.11/3.12/3.13 interpreter in the repo.
- **OS:** any (Linux/macOS/Windows). One documented caveat: the LangSmith Studio web UI cannot connect to a `localhost` server from **Safari** without the `langgraph dev --tunnel` flag (official local-server page). No other OS assumption is made. `SqliteSaver` connections in multi-threaded contexts use `sqlite3.connect(path, check_same_thread=False)` per the official example.
- **Model (critical decision):** the agent needs a chat model. The official `create_agent` docs note that with an **empty tool list the agent is a single LLM node with no tool-calling**; conversely, milestones 3+ require a model that **supports tool/function calling**. *Decision the reviewer should weigh in on:* which model.
  - Any LangChain chat-model integration works (LangGraph is model-agnostic; nodes are plain functions).
  - A model instance can be configured with provider-specific settings including `base_url` (official models docs), which is the supported way to point at a local OpenAI-compatible server.
  - **Requirement:** whatever model is chosen, verify it supports tool calling before milestone 3. Milestones 0–2 work with any chat model. This plan does **not** assume a specific provider or local runtime.
- **Packages (exact official names, latest at review time):**

| Package | Why | Install |
|---|---|---|
| `langgraph` | core runtime (bundles `langgraph-checkpoint`, `langgraph-prebuilt`, `langgraph-sdk`) | `pip install -U langgraph` |
| `langchain` | `create_agent`, middleware, `@tool`, `init_chat_model` | `pip install -U langchain` |
| a chat-model integration | the model (provider-specific; chosen per the decision above) | per provider |
| `langgraph-checkpoint-sqlite` | `SqliteSaver` (local durable persistence) | `pip install -U langgraph-checkpoint-sqlite` |
| `langgraph-cli[inmem]` | local Agent Server + Studio (milestone-B / optional) | `pip install -U "langgraph-cli[inmem]"` |
| `langgraph-checkpoint-postgres` (optional) | `PostgresSaver` (production-style persistence stretch) | `pip install -U langgraph-checkpoint-postgres` (+ `psycopg[binary]`) |

- **LangSmith key (optional):** free; only required for the local Agent Server path (milestone B / Studio). Set `LANGSMITH_API_KEY`. Tracing is otherwise optional. (Official local-server + persistence pages.)

---

## 4. Bleeding-edge technologies introduced — with maturity flags

The instruction was to introduce current/bleeding-edge technology. Each item below is real and documented; the **status column is load-bearing** so the reviewer is not misled about stability.

| Technology | What it is | Status per official docs | Used in |
|---|---|---|---|
| **LangGraph 1.x** | first stable major line; GA 2025-10-22; "no breaking changes until 2.0" | **Stable** | whole project |
| **Event streaming v3** (`graph.stream_events(..., version="v3")`) | typed projections (`messages`/`values`/`output`/`interrupts`/`subgraphs`) over one event flow | **Experimental / preview — "may change"** | M4, M5 (primary driver) |
| **Custom stream transformers** (`StreamTransformer`, `StreamChannel`, `required_stream_modes`) | build your own typed projection under `stream.extensions` | Experimental (part of v3 stack) | M4 (stretch) |
| **`create_agent` + middleware** (`langchain.agents`, `langchain.agents.middleware`) | production agent factory built on LangGraph; behavior extended via middleware hooks | **Stable** (langchain 1.0) | Alternative track (§7) |
| **`HumanInTheLoopMiddleware`** | prebuilt approve/edit/reject gate on tool calls; requires a checkpointer | **Stable** (prebuilt middleware) | Alternative track |
| **`DeltaChannel`** | stores incremental deltas to shrink checkpoint growth on long threads | **Beta — requires `langgraph>=1.2`** | M7 (stretch, optional) |
| **Durability modes** (`durability="exit"|"async"|"sync"`) | tune persistence-vs-performance per run | Stable | M2 (discussed), M7 |
| **Node caching** (`CachePolicy`, `InMemoryCache`) | cache a node's output keyed on its input | Stable | M3 (stretch) |
| **Long-term memory `Store` + semantic search** (`InMemoryStore` w/ embeddings index) | cross-thread memory, optionally vector-searchable | Stable | M6 (stretch) |
| **Agent Streaming Protocol / `langchain-protocol`** | wire-level event & command formats behind v3 | Preview | reference only |

> The reviewer should note: items marked Experimental/Beta are intentionally included to satisfy "bleeding edge," but the **core foundations track (M0–M3) depends only on Stable APIs** except for the streaming driver in M4, which has a documented stable fallback (`stream_mode` / `invoke`).

---

## 5. Architecture — the graph

The end-state core graph is the canonical ReAct loop. Two real nodes, one conditional edge, one back-edge forming the cycle:

```
        START
          │
          ▼
       ┌───────┐   no tool call   ┌─────┐
       │ agent │ ───────────────► │ END │
       └───────┘                  └─────┘
        ▲   │ tool call
        │   ▼
       ┌─────────┐
       │  tools  │   (human approval gate lives here in M5)
       └─────────┘
   (tools → agent: returns result, loops)
```

- **`agent` node:** calls the model (model is bound to the tools). Returns the model's message into state.
- **`should_continue` (conditional edge):** routes to `tools` if the last AI message contains tool calls, else to `END`.
- **`tools` node:** executes the requested tool(s), appends tool results to state, loops back to `agent`.
- **State:** a `TypedDict` carrying a `messages` channel (via `MessagesState` or an `Annotated[list, add_messages]` field).

This topology is taken directly from the official Interrupts page's end-to-end example (which hand-writes `agent_node`, `tool_node`, and `should_continue` and compiles with a `SqliteSaver`).

---

## 6. Milestone plan (core track, M0–M5)

Each milestone is independently runnable and has explicit acceptance criteria. APIs and imports are verified against the cited official pages.

### M0 — The empty graph
- **Objective:** prove the graph mechanics with one echo node.
- **Concepts/APIs:** `from langgraph.graph import StateGraph, START, END`; `TypedDict` state; `add_node`, `add_edge`; `.compile()`; `.invoke()`.
- **Acceptance:** `graph.invoke({...})` returns state showing the input flowed `START → node → END` (one super-step boundary).
- **Source:** Graph API overview; Overview (hello-world).

### M1 — Model + chat memory
- **Objective:** replace the echo with the chosen chat model; switch state to messages.
- **Concepts/APIs:** `from langgraph.graph import MessagesState`; `from langgraph.graph.message import add_messages`; model `.invoke(state["messages"])` inside the node.
- **Acceptance:** a single user question yields a real AI answer; state holds both the human and AI message; the `messages` channel accumulates (does not overwrite) across nodes.
- **Source:** Graph API ("Working with messages", `MessagesState`, `add_messages`).

### M2 — Durable, multi-turn memory
- **Objective:** persist state across turns.
- **Concepts/APIs:** `from langgraph.checkpoint.sqlite import SqliteSaver`; `SqliteSaver(sqlite3.connect("pocket.db", check_same_thread=False))`; compile with `checkpointer=...`; pass `config={"configurable": {"thread_id": "..."}}`.
- **Acceptance:** "my name is X" on one turn, then "what's my name?" on a later turn with the **same** `thread_id`, returns X; a new `thread_id` starts empty.
- **Discuss (no code change required):** durability modes `durability="exit"|"async"|"sync"` and what each guarantees.
- **Source:** Persistence (threads, checkpoints, checkpointer libraries, durability modes).

### M3 — Tools and the loop (the heart)
- **Objective:** add tools, the `tools` node, the conditional edge, and the back-edge — making it a true agent.
- **Tools (deterministic, local):** `calculator(expression: str)`, `get_time()`, `save_note(text: str)` / `read_notes()`. Define with `from langchain.tools import tool`.
- **Concepts/APIs:** bind tools to the model (`model.bind_tools([...])`); hand-write `tool_node` that iterates `state["messages"][-1].tool_calls`, invokes each tool, and returns `ToolMessage`s; `should_continue` returns `"tools"` or `END`; `add_conditional_edges("agent", should_continue, ["tools", END])`; `add_edge("tools", "agent")`.
- **Note (pedagogy):** the tool-execution node is hand-written on purpose (this is the learning core). The prebuilt `ToolNode` (`from langgraph.prebuilt import ToolNode`) is the shortcut and may be swapped in afterward for comparison.
- **Hard requirement:** the model must support tool calling (see §3). With an empty tool list the graph degrades to a single LLM node.
- **Stretch:** add `CachePolicy(ttl=...)` + `InMemoryCache()` on a node to demonstrate node caching.
- **Acceptance:** "what is 47 × 89 plus the current hour?" triggers `calculator` (and/or `get_time`), the loop runs the tool, feeds the result back, and the agent produces a correct final answer; the `messages` history shows the AI tool-call message → `ToolMessage` → final AI message.
- **Source:** Graph API (conditional edges, `add_messages`); Interrupts (full hand-built `agent`/`tool_node`/`should_continue` example); Agents ("Tool use in the ReAct loop", empty-tool-list behavior).

### M4 — Stream the run (v3 event streaming) — *experimental surface*
- **Objective:** stream tokens and observe state live.
- **Concepts/APIs:** `stream = graph.stream_events(input, config=config, version="v3")`; iterate `stream.messages` then `for token in message.text: ...`; await `stream.output`; observe `stream.values`; `message.output.usage_metadata` for token usage; `stream.interleave("values","messages")` for strict arrival order.
- **Constraints (documented):** under `version="v3"`, `stream_mode` and `subgraphs` arguments are **not** accepted (raise `TypeError`); v3 requires a recent `langgraph`.
- **Stable fallback (must document in the repo):** `graph.stream(input, config, stream_mode="messages")` / `"updates"` / `"values"`, and `graph.invoke(...)`. The repo README should state that M4 deliberately uses an experimental API and show the fallback.
- **Stretch (bleeding edge):** write a custom `StreamTransformer` exposing a projection under `stream.extensions` (e.g. a token counter), registered via `transformers=[...]` at call or compile time; or register the built-in `ToolCallTransformer` (`from langgraph.prebuilt import ToolCallTransformer`) to get `stream.tool_calls` on a plain `StateGraph`.
- **Acceptance:** answers render token-by-token; `stream.values` shows per-step state; the optional transformer projection yields the expected derived values.
- **Source:** Event streaming (projections, `interleave`, transformers, `ToolCallTransformer`, `required_stream_modes`); Streaming (stable `stream_mode` list).

### M5 — Human approval gate (HITL)
- **Objective:** pause before `save_note` writes; resume on approval.
- **Concepts/APIs:** `from langgraph.types import interrupt, Command`; call `interrupt({...})` inside the write path (or inside the `save_note` tool); resume with `graph.stream_events(Command(resume=...), config=config, version="v3")` (the resume value becomes the return of `interrupt()`); inspect `stream.interrupted` and `stream.interrupts`.
- **Mandatory interrupt rules (from official "Rules of interrupts") — the reviewer should verify these are honored:**
  - A **checkpointer and `thread_id` are required**; the node **re-runs from the beginning** on resume.
  - **Do not** wrap `interrupt()` in a bare `try/except` (it raises a control exception).
  - **Do not** conditionally skip or reorder `interrupt()` calls within a node (resume matching is strictly index-based).
  - Pass only **JSON-serializable** values to `interrupt()`.
  - Any side effect **before** an `interrupt()` must be **idempotent** (place side effects after the interrupt, or in a separate node).
- **Alternative (note only):** static breakpoints `interrupt_before=[...]` / `interrupt_after=[...]` exist for debugging but the docs explicitly say they are **not** recommended for HITL — use `interrupt()`.
- **Acceptance:** the run pauses at the gate, surfaces the approval payload on `stream.interrupts`, and on `Command(resume=True/edited)` either writes (possibly with edited args) or cancels; the same flow works after process restart given the SQLite checkpointer (durability).
- **Source:** Interrupts (the entire page, incl. "interrupts in tools" and "rules of interrupts").

---

## 6b. Stretch milestones (optional, M6–M7)

### M6 — Long-term memory across sessions (`Store`)
- **Objective:** remember user facts across *different* threads.
- **Concepts/APIs:** `from langgraph.store.memory import InMemoryStore`; compile with `store=...`; access via `runtime.store` in a node; `store.put(namespace, key, value)`, `store.search(namespace, query=..., limit=...)`; namespaces are tuples (e.g. `(user_id, "memories")`). Optional **semantic search**: configure `InMemoryStore(index={"embed": ..., "dims": ..., "fields": [...]})`.
- **Production note:** swap `InMemoryStore` for `PostgresStore` / `RedisStore` / `MongoDBStore` (all extend `BaseStore`).
- **Acceptance:** a fact saved under a user namespace on thread A is retrievable on thread B for the same user.
- **Source:** Persistence ("Memory store", semantic search, store backends).

### M7 — Inspect, time-travel, and optimize storage
- **Objective:** debugging and storage-growth control.
- **Concepts/APIs:** `graph.get_state_history(config)` (most-recent first), filter by `StateSnapshot.next` / `metadata["step"]`; replay by invoking with a prior `checkpoint_id`; `update_state` to fork. Optional storage optimization: `DeltaChannel` (**beta, requires `langgraph>=1.2`**) for append-heavy channels.
- **Acceptance:** can enumerate checkpoints, replay from an earlier one, and (optional) demonstrate reduced checkpoint size with `DeltaChannel`.
- **Source:** Persistence ("Get/Update state", "Replay", `DeltaChannel`); Time travel.

---

## 7. Alternative track — `create_agent` + middleware (modern high-level path)

Build the *same* agent with the high-level factory, to contrast "from scratch" against "production abstraction." This is fully stable (langchain 1.0).

- **Core:** `from langchain.agents import create_agent`; `agent = create_agent(model, tools=[...], system_prompt=..., checkpointer=..., store=...)`. Invocation: `agent.invoke({"messages": [...]})`; streams via the same v3 `stream_events` / `stream_mode`.
- **State constraint (must flag):** custom state schemas **must be `TypedDict` extending `AgentState`**; **Pydantic models and dataclasses are not supported** as of langchain 1.0. Define custom state via middleware (preferred) or `state_schema=`.
- **Bleeding-edge middleware to demonstrate** (all from `langchain.agents.middleware`, all verified in the official prebuilt-middleware catalog):
  - `HumanInTheLoopMiddleware(interrupt_on={"save_note": {"allowed_decisions": ["approve","edit","reject"]}, "read_notes": False})` — the prebuilt equivalent of M5; **requires a checkpointer**.
  - `SummarizationMiddleware(model=..., trigger=("tokens", N), keep=("messages", M))` — auto-summarize long histories (`fraction` triggers need `langchain>=1.1` model profiles).
  - `ModelCallLimitMiddleware(thread_limit=..., run_limit=..., exit_behavior="end")` and `ToolCallLimitMiddleware(...)` — cost/loop guards.
  - `ToolRetryMiddleware(...)` / `ModelRetryMiddleware(...)` — exponential backoff resilience.
  - `PIIMiddleware("email", strategy="redact")` — input/output sanitization.
  - `LLMToolEmulator(...)` — emulate tools for testing without executing them (useful for CI on this very project).
  - Custom hooks: `@before_model`, `@after_model`, `@wrap_model_call`, `@wrap_tool_call`, `@dynamic_prompt`, or an `AgentMiddleware` subclass.
- **Structured output (optional):** `response_format=ToolStrategy(Schema)` or `ProviderStrategy(Schema)` from `langchain.agents.structured_output`; as of langchain 1.0, passing a bare schema defaults to `ProviderStrategy` if the model supports native structured output, else falls back to `ToolStrategy`.
- **Acceptance:** behavioral parity with the hand-built agent on the M3/M5 acceptance prompts, plus at least one middleware demonstrably active (e.g. the HITL gate, or `LLMToolEmulator` short-circuiting a tool in a test).
- **Source:** Agents; Prebuilt middleware.

---

## 8. Local Agent Server + Studio (optional milestone B)

Run the graph behind the local dev server and the visual debugger.
- **Setup (official):** `pip install -U "langgraph-cli[inmem]"`; scaffold `langgraph new <path> --template new-langgraph-project-python`; `pip install -e .`; create `.env` (`LANGSMITH_API_KEY=...`); `langgraph dev`.
- **Endpoints:** API at `http://127.0.0.1:2024`, API docs at `/docs`, Studio UI URL printed by the command. `--tunnel` required for Safari. Docker variants: `langgraph up` (default port 8123), `langgraph build`, `langgraph dockerfile`.
- **`langgraph.json`:** declares `dependencies`, the `graphs` map (assistant name → import path; that name is the `assistant_id` used by the SDK/REST), `env`, optional `store.index` for semantic search.
- **Acceptance:** the graph is visible/runnable in Studio; the SDK (`langgraph-sdk`, `get_sync_client`) can stream a run against the local server.
- **Source:** Run a local server; `langgraph-cli` PyPI.

---

## 9. Proposed repository structure

```
pocket-agent/
├── pyproject.toml            # pinned deps (see §3); single source of truth
├── .env.example              # documents LANGSMITH_API_KEY and any model env
├── README.md                 # states M4 uses experimental v3 + the stable fallback
├── pocket_agent/
│   ├── state.py              # M1: State (MessagesState subclass)
│   ├── tools.py              # M3: calculator, get_time, save_note, read_notes
│   ├── graph.py              # M0→M5: build_graph(checkpointer, store) -> compiled
│   ├── stream.py             # M4: v3 driver + stable fallback
│   └── cli.py                # terminal loop; thread_id management
├── alt_create_agent/
│   └── agent.py              # §7: create_agent + middleware version
└── tests/
    └── test_tools.py         # §10
```
*One git repo; commit per milestone* (clean rollback points; matches the incremental design).

---

## 10. Testing and validation

- **Deterministic tools** are unit-tested directly (`calculator`, `get_time` formatting, note round-trip) — no model needed.
- **Graph wiring** tested by asserting `should_continue` routing on synthetic states (AI message with/without `tool_calls`).
- **Agent behavior without burning tokens:** in the alternative track, `LLMToolEmulator` can stand in for tools; the hand-built track can stub the model node. (`LLMToolEmulator` is an official prebuilt middleware.)
- **Persistence** tested by writing on thread A, reading on thread B, and asserting cross-thread isolation; HITL tested by asserting `stream.interrupted` then resuming.
- **Tracing (optional):** set `LANGSMITH_TRACING=true` + key to inspect runs in LangSmith / Studio.

---

## 11. Open decisions for the reviewer

1. **Model choice (§3).** Which chat model, and does it reliably support tool calling for M3+? This is the single biggest risk; a weak local model will make M3 flaky regardless of correct graph code.
2. **Experimental streaming (§4, M4).** Accept v3 `stream_events` as the primary teaching surface (with documented stable fallback), or invert and teach stable `stream_mode` first with v3 as the stretch?
3. **Scope of stretch.** Are M6 (`Store`) and M7 (time-travel/`DeltaChannel`) in or out for the first pass?
4. **Hand-built vs `create_agent` emphasis.** Is the alternative track (§7) a required deliverable or an optional appendix?
5. **Version drift.** All versions below are marked "verify at review time" — confirm none have moved in a way that changes an API (esp. anything tagged Experimental/Beta).

---

## 12. Version pins (verify at review time)

- `langgraph`: **1.x line; latest observed 1.2.4** at planning time. 1.0 GA: 2025-10-22. Commitment: no breaking changes until 2.0.
- Event streaming **v3**: experimental/preview per official docs ("may change").
- `DeltaChannel`: **beta**, requires `langgraph>=1.2`.
- `langchain`: 1.x; `create_agent` state requires `TypedDict` (no Pydantic/dataclass as of 1.0); summarization `fraction` triggers need `langchain>=1.1` (model profiles).
- Default recursion limit: **1000** (since `langgraph` v1.0.6).
- Python: `>=3.10` (3.11+ recommended).

> **Action for the implementer/reviewer:** before building, re-check the official changelog (`docs.langchain.com/oss/python/releases/changelog`) and PyPI for any movement, especially on the Experimental/Beta items.

---

## 13. Sources (official documentation only)

- LangGraph overview — https://docs.langchain.com/oss/python/langgraph/overview
- Graph API — https://docs.langchain.com/oss/python/langgraph/graph-api
- Persistence — https://docs.langchain.com/oss/python/langgraph/persistence
- Event streaming (v3) — https://docs.langchain.com/oss/python/langgraph/event-streaming
- Streaming (stable `stream_mode`) — https://docs.langchain.com/oss/python/langgraph/streaming
- Interrupts (HITL + rules) — https://docs.langchain.com/oss/python/langgraph/interrupts
- Time travel — https://docs.langchain.com/oss/python/langgraph/use-time-travel
- Memory — https://docs.langchain.com/oss/python/langgraph/add-memory
- Run a local server — https://docs.langchain.com/oss/python/langgraph/local-server
- Agents (`create_agent`) — https://docs.langchain.com/oss/python/langchain/agents
- Prebuilt middleware — https://docs.langchain.com/oss/python/langchain/middleware/built-in
- Custom middleware — https://docs.langchain.com/oss/python/langchain/middleware/custom
- API reference (signatures) — https://reference.langchain.com/python/langgraph and https://reference.langchain.com/python/langchain
- Changelog — https://docs.langchain.com/oss/python/releases/changelog
- PyPI — https://pypi.org/project/langgraph/ · https://pypi.org/project/langgraph-cli/ · https://pypi.org/project/langgraph-prebuilt/
