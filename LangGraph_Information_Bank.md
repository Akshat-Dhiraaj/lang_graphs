# LangGraph — Information Bank

> A factual reference compiled from official LangChain/LangGraph documentation and
> verified sources. Purpose: understand LangGraph thoroughly before building one locally.
>
> **As of:** June 2026 · **Latest release:** `langgraph` 1.2.4 · **First stable (1.0) GA:** 22 October 2025
> **License:** MIT — the open-source `langgraph` library is MIT-licensed (`Copyright (c) 2024 LangChain, Inc.`; PyPI `license_expression: MIT`). The commercial **LangSmith Deployment** (formerly LangGraph Platform) is a separate, proprietarily-licensed product. · **Built by:** LangChain Inc. (usable without LangChain)

---

## 1. What LangGraph is

LangGraph is a **low-level orchestration framework and runtime for building, managing, and deploying long-running, stateful agents**. It models an agent's workflow as a **graph** of nodes (units of work) and edges (control flow) operating over a **shared state** object.

Key framing points from the official docs:

- It is **deliberately low-level** and focused *entirely on orchestration*. It does **not** abstract prompts or agent architecture for you — it gives you primitives to build exactly the control flow you want.
- It can be used **standalone** (no LangChain required), but integrates with the LangChain ecosystem.
- Its distinguishing value over plain scripting or a simple chain is **cycles**: agent behavior usually means calling an LLM in a loop, branching, retrying, and self-correcting. LangGraph is built for loops, branches, and conditional routing — not just linear DAGs.
- It is an **agent runtime**, not just a state-machine library: durable execution, streaming, human-in-the-loop, and persistence are first-class.

**Lineage / inspiration (official acknowledgements):**
- Execution model inspired by **Google Pregel** (large-scale graph processing) and **Apache Beam**.
- Public/builder interface inspired by **NetworkX**.

**1.0 stability promise:** LangGraph 1.0 shipped with effectively zero breaking changes vs the mature 0.x line; the core primitives (state, nodes, edges) are unchanged, and LangChain has committed to **no breaking changes until 2.0**. The one notable 1.0 change was deprecation of the `langgraph.prebuilt` module, with high-level agent helpers moved into `langchain` (`langchain.agents`).

---

## 2. Where it sits — the ecosystem

LangGraph is one layer in a stack. Knowing the boundaries prevents confusion:

| Layer | What it is | Role |
|---|---|---|
| **LangChain** | High-level agent framework: model/tool integrations, `create_agent()` abstraction, middleware | Build agents *fast* with prebuilt loops. Its agents are **built on LangGraph**. |
| **LangGraph** | Low-level orchestration **runtime**: state, nodes, edges, persistence, streaming, HITL | Run agents *reliably* with fine-grained, custom control flow. |
| **Deep Agents** | An agent *harness* on top of LangGraph (planning, sub-agents, filesystem tools, context mgmt) | Opinionated complex-agent scaffolding. |
| **LangSmith** | Observability/eval platform + deployment ("LangSmith Deployment", formerly LangGraph Platform) | Trace, debug, evaluate, deploy, and scale. **Studio** is its visual debugger. |

Practical takeaway: start with LangChain's `create_agent` if you want a quick tool-calling loop; **drop down to LangGraph** when you need custom branching, durable long-running execution, human approval gates, or multi-agent orchestration. You are not locked in either direction.

---

## 3. The core mental model — graphs and "super-steps"

LangGraph runs your graph using a **message-passing / Pregel** model:

1. You define behavior with three components: **State**, **Nodes**, **Edges**. *Nodes do the work; edges decide what runs next.*
2. Execution proceeds in discrete **super-steps**. A super-step is one "tick" of the graph in which all currently-scheduled nodes run (in **parallel** if multiple are scheduled together).
3. Nodes that run **in parallel** belong to the **same** super-step; nodes that run **sequentially** belong to **separate** super-steps.
4. Lifecycle: all nodes start `inactive`. A node becomes `active` when it receives a message (a state update) on an incoming edge ("channel"). It runs, emits updates, and passes messages onward. At the end of each super-step, nodes with no incoming messages **vote to halt** (mark themselves `inactive`). Execution **terminates when all nodes are inactive and no messages are in transit**.

This super-step boundary is also the unit at which **checkpoints** are written (see §6), which is why time-travel and fault recovery resume from super-step boundaries.

---

## 4. The building blocks (Graph API)

This is the primary, most-documented way to build with LangGraph.

### 4.1 State

The **State** is a shared data structure (the current snapshot of your app). It consists of:
- a **schema** (the channels/keys), and
- **reducer** functions per key (how updates are merged).

**Schema options:**
- `TypedDict` — the main documented choice (fast).
- `dataclass` — use when you want **default values**.
- Pydantic `BaseModel` — use when you want **recursive data validation** (less performant than the above). *Note: the high-level `create_agent` factory in `langchain` does **not** support Pydantic state schemas — it expects `TypedDict` extending `AgentState`.*

**Reducers** (critical concept):
- Each key has its **own independent reducer**.
- **Default reducer** (no annotation): updates **overwrite** the key.
- **`Annotated[type, fn]`**: applies `fn` to merge. E.g. `Annotated[list[str], operator.add]` **appends** instead of overwriting.
- Nodes return **partial** updates (only changed keys); LangGraph merges them via the reducers.
- **`Overwrite`** type: bypass a reducer to force a direct overwrite of a value.

**Messages in state:**
- `add_messages` is the prebuilt reducer for message lists. It **appends new messages**, **deduplicates/overwrites by message ID** (important for human-in-the-loop edits), and **deserializes** dict-form messages into LangChain `Message` objects.
- `MessagesState` is a prebuilt state with a single `messages` channel using `add_messages`. Most chat/agent graphs **subclass** it to add fields:
  ```python
  from langgraph.graph import MessagesState
  class State(MessagesState):
      documents: list[str]
  ```

**Multiple schemas:** nodes can read/write **private** channels for internal communication, and you can define explicit **input**/**output** schemas that are subsets of an overall internal schema. A node can write to *any* channel in the overall graph state, not only those in its declared input type.

### 4.2 Nodes

Nodes are plain Python functions (sync or async) that accept up to three args:
1. `state` — the graph state.
2. `config` — a `RunnableConfig` (carries `thread_id`, tags, tracing metadata).
3. `runtime` — a `Runtime` object exposing runtime `context`, plus `store`, `stream_writer`, `execution_info`, `server_info`, etc.

Added via `builder.add_node(...)`. If you add a function without a name it takes the function's name. Behind the scenes functions become `RunnableLambda` (gaining batch/async/tracing support).

- **`START`** — virtual node representing user input; edge from `START` says which node runs first.
- **`END`** — virtual terminal node; edge to `END` ends that path.
- **Node caching** — `add_node(..., cache_policy=CachePolicy(ttl=...))` plus a cache at compile time (e.g. `InMemoryCache()`) caches a node's output keyed on its input.

### 4.3 Edges (routing)

- **Normal edge** — always go A→B: `graph.add_edge("a", "b")`.
- **Conditional edge** — a routing function decides the next node(s): `graph.add_conditional_edges("a", route_fn)`; optionally map outputs to node names with a dict.
- **Entry point** — `add_edge(START, "a")`.
- **Conditional entry point** — `add_conditional_edges(START, route_fn)`.
- A node can have **multiple outgoing edges** → all targets run **in parallel** in the next super-step.
- **Rule of thumb:** for a given node, use **either** static edges **or** dynamic routing (`Command`) — not both — to keep behavior predictable.

### 4.4 `Send` — dynamic fan-out / map-reduce

When the number of branches isn't known ahead of time (e.g. generate N items, then process each), return `Send` objects from a conditional edge. Each `Send(node_name, state)` dispatches one independent invocation of a node with its own state:
```python
from langgraph.types import Send
def continue_to_jokes(state):
    return [Send("generate_joke", {"subject": s}) for s in state["subjects"]]
```

### 4.5 `Command` — combine state update + routing

`Command` is a versatile control primitive with four params: `update`, `goto`, `graph`, `resume`. Used in three places:
- **Return from a node** — update state **and** route in one step: `return Command(update={...}, goto="next")`. Requires a return annotation listing reachable nodes, e.g. `Command[Literal["next"]]`.
- **Return from a tool** — update graph state / route from inside a tool.
- **Input to `invoke`/`stream`** — **only** `Command(resume=...)` is valid here, to resume after an interrupt. ⚠️ Do **not** pass `Command(update=...)` as input to continue a conversation — any `Command` input resumes from the latest checkpoint and the graph will look "stuck". To continue a thread, pass a **plain input dict**.
- `graph=Command.PARENT` — route from a subgraph node up to a node in the parent graph (used in **multi-agent handoffs**).

### 4.6 Compiling

You **must** call `.compile()` before use. Compilation runs structural checks (e.g. no orphaned nodes) and is where you attach runtime args like the **checkpointer**, **store**, **cache**, and **breakpoints**:
```python
graph = builder.compile(checkpointer=..., store=..., interrupt_before=[...])
```

### 4.7 Runtime context & recursion limit

- **`context_schema`** lets you inject runtime dependencies (model name, DB connection) not part of state: `StateGraph(State, context_schema=Ctx)`, passed via `graph.invoke(inputs, context={...})`, read via `runtime.context`.
- **Recursion limit** — max super-steps per run; default **1000** (since v1.0.6). Exceeding it raises `GraphRecursionError`. Set per run via `config={"recursion_limit": N}` (a **top-level** config key, not under `configurable`).
- **`RemainingSteps`** — a managed value letting a node check how many steps remain and degrade gracefully *before* hitting the limit.

---

## 5. Persistence — the durable core

LangGraph has a built-in **persistence layer**. Compile with a **checkpointer** and a **snapshot of state is saved at every super-step**, organized into **threads**. This single mechanism powers human-in-the-loop, memory, time-travel, and fault tolerance.

### 5.1 Threads & checkpoints

- A **thread** = a unique `thread_id` holding the accumulated state of a sequence of runs. You **must** pass it: `{"configurable": {"thread_id": "1"}}`.
- A **checkpoint** = a snapshot of state at one super-step, represented as a **`StateSnapshot`** with fields:

| Field | Meaning |
|---|---|
| `values` | channel values at this checkpoint |
| `next` | node names to run next; empty `()` = complete |
| `config` | `thread_id`, `checkpoint_ns`, `checkpoint_id` |
| `metadata` | `source` (`input`/`loop`/`update`), `writes`, `step` |
| `created_at` | ISO-8601 timestamp |
| `parent_config` | config of previous checkpoint (`None` for first) |
| `tasks` | tasks to run, each with `id`, `name`, `error`, `interrupts` |

- **Checkpoint namespace** (`checkpoint_ns`): `""` for the root graph; `"node:uuid"` for a subgraph (nested joined with `|`).
- **Pending writes:** if one node in a super-step fails, the **successful** nodes' writes are already persisted as task-level entries, so on resume they are **not re-run**.

### 5.2 Inspecting & editing state

- `graph.get_state(config)` → latest (or a specific `checkpoint_id`) `StateSnapshot`.
- `graph.get_state_history(config)` → full history, most-recent first (enables time-travel).
- **Replay:** invoke with a prior `checkpoint_id` to re-run nodes *after* that point (earlier nodes are skipped; LLM calls / interrupts after it **do** re-fire).
- `graph.update_state(config, values, as_node=...)` → writes a **new** checkpoint with updated values (values pass through reducers). `as_node` controls which node the update is attributed to (affects what runs next).

### 5.3 Durability modes

Set via `durability=` on any execution call — trade performance vs safety:

| Mode | Behavior | Use when |
|---|---|---|
| `"exit"` | persist only when the run exits (success/error/interrupt) | best perf; OK if you don't need mid-run crash recovery |
| `"async"` | persist asynchronously while the next step runs | good balance (small risk of loss on crash) |
| `"sync"` | persist synchronously before each next step | highest durability; some overhead |

### 5.4 Checkpointer libraries (storage backends)

All conform to `BaseCheckpointSaver` (`.put`, `.put_writes`, `.get_tuple`, `.list`, plus async `a*` variants).

| Package | Saver class | Use |
|---|---|---|
| `langgraph-checkpoint` (bundled) | `InMemorySaver` | experimentation/dev |
| `langgraph-checkpoint-sqlite` (separate install) | `SqliteSaver` / `AsyncSqliteSaver` | **local dev / single-file persistence** |
| `langgraph-checkpoint-postgres` (separate install) | `PostgresSaver` / `AsyncPostgresSaver` | **production** (also used by LangSmith) |
| `langchain-azure-cosmosdb` (separate install) | `CosmosDBSaver(Sync)` | production on Azure (Entra ID auth) |

- **Serializer:** default `JsonPlusSerializer` (ormsgpack + JSON) handles LangChain/LangGraph types, datetimes, enums. Use `pickle_fallback=True` for unsupported objects (e.g. pandas DataFrames).
- **Encryption:** wrap the serializer in `EncryptedSerializer` (AES via `from_pycryptodome_aes()`, reading key from `LANGGRAPH_AES_KEY`).
- **`DeltaChannel`** (requires `langgraph>=1.2`, **beta**): stores only incremental deltas for append-heavy channels to cut checkpoint storage growth on long threads.

> When using the managed **Agent Server / LangSmith**, checkpointing and stores are handled **automatically** — you don't configure savers by hand.

---

## 6. Memory — short-term vs long-term

LangGraph separates two memory types:

- **Short-term (working) memory** = the **thread state** persisted by the **checkpointer**. Scoped to a single conversation/thread. Follow-ups on the same `thread_id` retain prior context (e.g. conversation history in `messages`).
- **Long-term memory** = the **`Store`** interface — information shared **across threads** (e.g. user facts that should persist across all conversations). Checkpointers alone cannot share across threads; the Store fills that gap.

**Store mechanics:**
- Memories are **namespaced by a tuple**, e.g. `(user_id, "memories")` (any length, any meaning).
- API: `store.put(namespace, key, value_dict)`, `store.search(namespace, ...)`, `store.list_namespaces(...)`, plus async `a*` variants. Items have `value`, `key`, `namespace`, `created_at`, `updated_at`.
- **`search` matches namespaces by prefix**, truncates silently past `limit`, and ordering is backend-dependent (Postgres = `updated_at` desc; InMemory = insertion order) — sort client-side if order matters.
- **Semantic search:** configure the store with an embeddings index (`embed`, `dims`, `fields`) to query by meaning, not exact match.
- Compile with both: `builder.compile(checkpointer=..., store=...)`. Access in a node via `runtime.store` (and `runtime.context.user_id` for namespacing).

| Store implementation | Use |
|---|---|
| `InMemoryStore` | dev/testing |
| `PostgresStore`, `RedisStore`, `MongoDBStore` | production (all extend `BaseStore`) |

---

## 7. Streaming

Graphs expose `stream` (sync) / `astream` (async). Pass one or more **stream modes**:

| `stream_mode` | Emits |
|---|---|
| `values` | the **full state** after each step (good for "current state" UIs / debugging) |
| `updates` | only the **delta** per node (good for progress, bandwidth-light) |
| `messages` | LLM **token-level** message chunks + metadata (the "live typing" chat feel) |
| `messages-tuple` | message chunk as a tuple form |
| `custom` | arbitrary data you emit from inside a node via the stream writer (e.g. `{"progress": "50%"}`) |
| `debug` | detailed tracing for development |
| `events` | every execution event |
| `tasks` | task start/finish events |
| `checkpoints` | checkpoints as they're created |

- Use `subgraphs=True` to also stream from nested subgraphs.
- **Event streaming** is the newer **typed-projection API introduced in v1.2** — separate iterators per projection (messages, values, subgraphs, output) you consume independently, instead of branching on chunk types. Recommended for new apps.

---

## 8. Human-in-the-loop (HITL)

Requires a checkpointer (so the graph can pause, surface state, and resume).

**Dynamic interrupt (recommended):**
```python
from langgraph.types import Command, interrupt

def human_review(state):
    answer = interrupt("Do you approve?")   # pauses here, surfaces the payload
    return {"messages": [{"role": "user", "content": answer}]}

# run → hits interrupt and pauses
graph.invoke({"messages": [...]}, config)
# resume → the value becomes the return of interrupt()
graph.invoke(Command(resume="yes"), config)
```

**Static breakpoints:** compile with `interrupt_before=[...]` / `interrupt_after=[...]` (or set at runtime) to pause before/after specific nodes for inspection/approval, then resume.

**Common HITL uses:** approve/reject a tool call, edit agent state before continuing, multi-day approval flows, "review then commit" steps.

**Time travel** builds on the same persistence: list history, pick a past checkpoint, optionally `update_state` to fork an alternative trajectory, and replay.

---

## 9. Multi-agent patterns

When a single agent's prompt grows too long and tool selection degrades (the "single-agent ceiling"), split work across specialized agents. LangGraph supports several topologies; the three named patterns:

| Pattern | How control flows | Trade-offs | Helper package |
|---|---|---|---|
| **Supervisor** | A central orchestrator delegates to sub-agents; **only the supervisor replies to the user**; control returns to it after each sub-agent | Easiest to reason about and trace; one place to change routing. **More LLM calls** (extra hop per handoff) → higher latency. Makes few assumptions about sub-agents (works broadly). | `langgraph-supervisor` |
| **Swarm** | Agents **hand off directly** to each other via handoff tools; system remembers the **last-active agent** so the next turn resumes with it | **Faster, fewer LLM calls**; great when paths branch unpredictably. Harder to debug; each agent must know its peers (bad fit for third-party agents). | `langgraph-swarm` |
| **Network** | Any agent can route to any other | Most flexible, **hardest to debug** | (custom) |

- **Handoffs** are implemented with `Command(goto=..., graph=Command.PARENT)` returned from a handoff tool (built via e.g. `create_handoff_tool`), which updates parent-graph state and redirects execution.
- **General guidance from LangChain's own benchmarking:** the post recommends *choosing based on your goals and constraints* rather than a fixed default. It found **swarm slightly outperforms supervisor across the board** and uses fewer tokens (the supervisor's extra "translation" hop costs performance), while **supervisor is the most generic** (it makes the fewest assumptions about the underlying agents) — making it the safer fit when integrating third-party agents.
- **Subgraphs**: a compiled graph can be used as a node inside another graph — the basis for composition and hierarchical/multi-agent designs. Shared keys updated from a subgraph to a parent require a reducer on the parent key.

---

## 10. Graph API vs Functional API

LangGraph offers two authoring styles for the same runtime:

- **Graph API** (`StateGraph`): explicit nodes/edges/state. Best when control flow is complex, you want a visual graph, branching/parallelism, and maximum clarity. *This is the main documented API.*
- **Functional API** (`@entrypoint`, `@task` decorators): add LangGraph capabilities (persistence, HITL, streaming, durable execution) to **ordinary Python control flow** with minimal restructuring — you write normal functions and mark the entrypoint/tasks instead of drawing a graph. Best for retrofitting existing code or when the flow is naturally imperative.

Both compile down to the same **Pregel** runtime. There's an official "Choosing APIs" guide if you're unsure.

---

## 11. The Agent Server & deployment

- **Local server:** `langgraph dev` runs an **in-memory Agent Server** (dev/testing) exposing a REST API + auto-generated docs, connectable to **Studio** for visual debugging. (Details in §13.)
- **Docker:** `langgraph up` (run in Docker, default port 8123), `langgraph build` (build an image), `langgraph dockerfile` (generate a Dockerfile for custom deploys).
- **Managed:** **LangSmith Deployment** (formerly LangGraph Platform, GA 14 May 2025) provides managed, scalable infra for long-running stateful agents, handling persistence/stores automatically, with Studio for prototyping and the **Agent Chat UI** for chat frontends.
- **SDK:** `langgraph-sdk` (`get_client` / `get_sync_client`) to call a running server's assistants, threads, and streaming runs from Python (also a REST API and JS SDK).

---

## 12. What LangGraph is used for (use cases)

**Production adopters cited by LangChain:** Klarna, Uber, LinkedIn, Replit, AppFolio, Elastic.

**Representative use cases:**
- **Tool-using / ReAct agents** — call an LLM in a loop, decide and run tools, observe, repeat.
- **Conversational agents & chatbots** with durable memory across turns and sessions.
- **Customer-support automation** — triage → specialist routing, escalation, DB lookups (supervisor/swarm).
- **Research / report assistants** — search → summarize → critique → refine loops; map-reduce over many sources via `Send`.
- **RAG with control flow** — retrieve, grade relevance, conditionally re-query or regenerate, error-recover.
- **Code review / data-analysis agents** — multi-step reasoning with branching and retries.
- **Long-running / multi-day workflows** with **human approval gates** (HITL) and crash-safe **durable execution** (background jobs, approval processes).
- **Multi-agent systems** where specialized agents collaborate or hand off.

**When *not* to reach for LangGraph:** a purely linear pipeline with no loops/branches/state — a simple chain (or even a plain script / `create_agent`) is lighter. LangGraph earns its weight when you need cycles, persistence, human gates, or orchestration.

---

## 13. Building one locally — practical setup

There are **two distinct local paths**. Pick based on goal.

### Path A — Library only (fastest; pure Python, no server)
Best for learning the primitives and embedding LangGraph in your own app (scripts, FastAPI, notebooks).

```bash
# Python >= 3.10 (3.11+ recommended)
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -U langgraph

# Optional, as needed:
pip install -U langchain langchain-openai              # models/tools via LangChain
pip install -U langgraph-checkpoint-sqlite             # local persistence
pip install -U "psycopg[binary]" langgraph-checkpoint-postgres   # production-style persistence
```

**Hello world (official):**
```python
from langgraph.graph import StateGraph, MessagesState, START, END

def mock_llm(state: MessagesState):
    return {"messages": [{"role": "ai", "content": "hello world"}]}

graph = StateGraph(MessagesState)
graph.add_node(mock_llm)
graph.add_edge(START, "mock_llm")
graph.add_edge("mock_llm", END)
graph = graph.compile()

graph.invoke({"messages": [{"role": "user", "content": "hi!"}]})
```

**A more realistic local skeleton — tool-calling loop with persistence:**
```python
from typing import Annotated, Literal
from typing_extensions import TypedDict
from langgraph.graph import StateGraph, START, END, MessagesState
from langgraph.checkpoint.sqlite import SqliteSaver   # local, file-backed
import sqlite3

# 1) State (subclass MessagesState to keep chat history with add_messages)
class State(MessagesState):
    pass

# 2) Nodes (plug your own model client here — see local-LLM note below)
def call_model(state: State):
    # response = your_model.invoke(state["messages"])
    response = {"role": "ai", "content": "...(model output)..."}
    return {"messages": [response]}

def should_continue(state: State) -> Literal["tools", END]:
    last = state["messages"][-1]
    # if the model requested a tool call, route to "tools"; else finish
    return END  # placeholder

def run_tools(state: State):
    # execute the requested tool, append a tool message
    return {"messages": [{"role": "tool", "content": "...(tool result)..."}]}

# 3) Wire the graph
builder = StateGraph(State)
builder.add_node("model", call_model)
builder.add_node("tools", run_tools)
builder.add_edge(START, "model")
builder.add_conditional_edges("model", should_continue)
builder.add_edge("tools", "model")   # loop back after a tool runs

# 4) Compile WITH a checkpointer → durable, resumable, memory across turns
checkpointer = SqliteSaver(sqlite3.connect("checkpoints.db", check_same_thread=False))
graph = builder.compile(checkpointer=checkpointer)

# 5) Run on a thread (state persists under this thread_id)
config = {"configurable": {"thread_id": "demo-1"}}
for chunk in graph.stream(
    {"messages": [{"role": "user", "content": "What is LangGraph?"}]},
    config,
    stream_mode="updates",
):
    print(chunk)
```

### Path B — Local Agent Server + Studio (REST API, visual debugger)
Best when you want the full platform experience locally: an API, hot reload, and the Studio UI.

```bash
# 1) CLI (with in-memory server extras)
pip install -U "langgraph-cli[inmem]"

# 2) Scaffold a project from the official template
langgraph new path/to/your/app --template new-langgraph-project-python

# 3) Install your app in editable mode (so local edits are picked up)
cd path/to/your/app
pip install -e .

# 4) Create .env (copy from .env.example). LangSmith key is free to obtain.
#    LANGSMITH_API_KEY=lsv2...
#    (plus any model provider keys you use, e.g. OPENAI_API_KEY)

# 5) Launch the local server (in-memory; dev/testing only)
langgraph dev
#  -> API:      http://127.0.0.1:2024
#  -> Studio:   https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024
#  -> API docs: http://127.0.0.1:2024/docs
```

`langgraph dev` flags worth knowing: `--host`, `--port` (default 2024), `--no-reload`, `--no-browser`, `-c/--config` (defaults to `langgraph.json`), and `--tunnel` (needed for **Safari**, which can't hit localhost). For Docker-based local runs use `langgraph up` (default port 8123).

**`langgraph.json`** declares your app's `dependencies`, the `graphs` it exposes (assistant name → import path — that name is what you call via the SDK/REST as `assistant_id`), `env`, and optional `store` indexing for semantic search.

**Call the local server (SDK):**
```python
from langgraph_sdk import get_sync_client     # pip install langgraph-sdk
client = get_sync_client(url="http://localhost:2024")
for chunk in client.runs.stream(
    None,                 # threadless run
    "agent",              # assistant name from langgraph.json
    input={"messages": [{"role": "human", "content": "What is LangGraph?"}]},
    stream_mode="messages-tuple",
):
    print(chunk.event, chunk.data)
```

### Note for a local-LLM setup
LangGraph is **model-agnostic** — nodes are just functions, so any client works. To run fully local, point `call_model` at a local server through an OpenAI-compatible client:
- **Ollama:** `pip install langchain-ollama`, then `ChatOllama(model="qwen2.5-coder", ...)`.
- **LM Studio / any OpenAI-compatible endpoint:** use `ChatOpenAI(base_url="http://localhost:1234/v1", api_key="not-needed", model="...")`.
LangSmith tracing is **optional** for Path A and only required (free tier) for the Path B local server. You can run Path A with **no external keys at all** if your model is local.

### Suggested first build (incremental)
1. Path A hello-world → confirm the graph runs.
2. Add a real (local) model node → single-turn answer.
3. Add `MessagesState` + a SQLite checkpointer → multi-turn memory on a `thread_id`.
4. Add one tool + a conditional edge + a loop back to the model → a real ReAct agent.
5. Add an `interrupt()` before the tool node → human approval.
6. (Optional) Move to Path B for Studio visualization, then to Postgres for "production-style" persistence.

---

## 14. Version & compatibility notes

- **Latest published:** `langgraph` **1.2.4**. The 1.x line is current and stable.
- **Selected version history:** 1.0.0 (17 Oct 2025; GA announced 22 Oct 2025) → 1.0.x patches through early 2026 → 1.1.0 (10 Mar 2026) → 1.2.x.
- **Default recursion limit = 1000** since v1.0.6.
- **Event streaming** (typed projections) and **`DeltaChannel`** require **`langgraph>=1.2`** (DeltaChannel is **beta**).
- **`langgraph.prebuilt`** was deprecated in 1.0 with helpers moved to `langchain.agents`; the high-level loop is now `langchain.agents.create_agent` (note: `create_agent` requires `TypedDict` state, **not** Pydantic/dataclass). A `create_react_agent` historically lived in `langgraph-prebuilt`.
- **Python support:** `>=3.10` (docs/CLI recommend **3.11+**).
- **Backward compatibility:** committed to **no breaking changes until 2.0**. Always confirm specifics against the live changelog before relying on a recent feature.

---

## 15. Authoritative sources

Official documentation and primary sources used to compile this document (verify the live versions for anything time-sensitive):

- LangGraph overview — https://docs.langchain.com/oss/python/langgraph/overview
- Graph API — https://docs.langchain.com/oss/python/langgraph/graph-api
- Persistence — https://docs.langchain.com/oss/python/langgraph/persistence
- Streaming — https://docs.langchain.com/oss/python/langgraph/streaming
- Interrupts (HITL) — https://docs.langchain.com/oss/python/langgraph/interrupts
- Memory — https://docs.langchain.com/oss/python/langgraph/add-memory
- Subgraphs — https://docs.langchain.com/oss/python/langgraph/use-subgraphs
- Run a local server — https://docs.langchain.com/oss/python/langgraph/local-server
- Install / Quickstart — https://docs.langchain.com/oss/python/langgraph/install · /quickstart
- Runtime (Pregel) — https://docs.langchain.com/oss/python/langgraph/pregel
- API reference — https://reference.langchain.com/python/langgraph
- GitHub repo — https://github.com/langchain-ai/langgraph
- 1.0 announcement — https://www.langchain.com/blog/langchain-langgraph-1dot0 · https://changelog.langchain.com/announcements/langgraph-1-0-is-now-generally-available
- Multi-agent benchmarking — https://blog.langchain.com/benchmarking-multi-agent-architectures/
- Swarm package — https://github.com/langchain-ai/langgraph-swarm-py
- Changelog — https://changelog.langchain.com/ · https://docs.langchain.com/oss/python/releases/changelog
- PyPI — https://pypi.org/project/langgraph/ · https://pypi.org/project/langgraph-cli/
