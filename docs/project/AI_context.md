# docs/project/AI_context.md — Pocket Agent working context

> Read this first. It tells you what this repo is, how it is built, the rules for
> changing it, and exactly how to verify your work. Keep it accurate when you make
> changes.

## What this project is

**Pocket Agent** is a foundations-first **LangGraph** learning project: a hand-built
ReAct agent (`agent <-> tools` cycle) assembled incrementally across milestones
**M0–M14**, plus a high-level **`create_agent` ("ALT") track**. The entire project is
*generated and self-verified* by a single script.

It is local-first and runs **keyless in deterministic "mock" mode**, or against a real
model (LM Studio `qwen/qwen3.5-9b` on a Win11 / RTX 4060 box, or any provider key).

## The one rule that matters: the generator is the source of truth

`scripts/build_pocket_agent.sh` emits **every** file under `pocket-agent/` from
single-quoted heredocs (`<<'PY'`, `<<'JSON'`, `<<'MD'`). The committed `pocket-agent/`
tree is its *output*.

**Therefore: never hand-edit files under `pocket-agent/` and expect it to stick.**
To change any generated file, edit its heredoc inside `scripts/build_pocket_agent.sh`, then
regenerate. Hand-edits are overwritten on the next build. (Hand-maintained files that
are NOT generated: `docs/project/*`, `docs/plans/*`, `docs/reference/*`,
`scripts/*.sh`, `examples/*`, and the root `*.cmd` launchers.)

## How to build, run, and verify

```bash
# regenerate sources + syntax-check only (no install, fast):
bash scripts/build_pocket_agent.sh --check

# full build: venv + install + pytest + milestone verifier -> BUILD_REPORT.md
bash scripts/build_pocket_agent.sh

# run the self-test harness directly (from pocket-agent/, venv active):
python verify_milestones.py            # exit code = number of FAILED *required* milestones (0 = good)
POCKET_FORCE_MOCK=1 python verify_milestones.py   # force keyless mock mode

# unit tests:
pytest -q

# serve the graph (Phase 4): from pocket-agent/, with langgraph-cli[inmem] installed
langgraph dev                          # http://127.0.0.1:2024 + opens Studio
```

Windows launchers at the repo root: `build.cmd` (full build) and `lmstudio.cmd`.
The LM Studio orchestration script lives at `scripts/overnight_lmstudio.sh`.
For 6-8 hour system monitoring plus optional repeated project checks, use
`scripts/overnight_system_run.ps1`.

Last live LM Studio setup: `qwen/qwen3.5-9b`, context `4096`, GPU `max`,
parallel `1`, TTL `28800`. It passed the raw tool-call probe and the full
verifier with **16 passed / 0 failed / 0 skipped**.

### Model selection (set before running)
- **mock** (default, keyless): `POCKET_FORCE_MOCK=1`, or simply no provider configured.
- **LM Studio**: `POCKET_USE_LMSTUDIO=1` (OpenAI-compatible server, default `http://localhost:1234/v1`).
- **Ollama**: `POCKET_USE_OLLAMA=1` with `ollama serve` + a tool-capable model.
- **Anthropic / OpenAI**: set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`.
- **Embeddings (M10)**: keyless mock embedder by default; for real embeddings set
  `POCKET_EMBED_MODEL` (+ matching provider env, optional `POCKET_EMBED_DIMS`).
- **Postgres (M12)**: optional; install `pip install .[postgres]`, set
  `POCKET_POSTGRES_URI`, and set `POCKET_POSTGRES_SETUP=1` only when you want the
  verifier to create/migrate LangGraph tables.
- Other flags: `POCKET_SKIP_CLI=1` (skip installing `langgraph-cli[inmem]`),
  `POCKET_NOTES_PATH` (where the `save_note`/`read_notes` tools persist).

## Milestones (what the harness verifies)

`verify_milestones.py` records each as PASS / SKIP / FAIL. **Required** milestones gate the
exit code; everything else is `required=False` (informational, never blocks).

| ID | Verifies | Required |
|----|----------|----------|
| M0 | empty graph: `START -> echo -> END` returns input unchanged | yes |
| M1 | model + chat memory (MessagesState) | yes |
| M2 | durable multi-turn memory across `thread_id`; isolation across threads | yes |
| M3 | tools + **the cycle** (`agent -> tool -> agent -> final`) | yes |
| M4 | streaming via the **v3 `stream_events`** path, with `stream_mode`/`invoke` fallback | yes |
| M5 | **HITL** human-approval gate: interrupt pauses before the side effect; resume writes/cancels | yes |
| M6 | long-term `Store` put/get/prefix-search; graph compiles with `store=` | no |
| M7 | time travel: `get_state_history` + replay from a prior `checkpoint_id` | no |
| M8 | **Server/Studio** (Phase 4): `langgraph.json` parses, graphs import to *compiled* graphs (not the `(graph, mode)` tuple), SDK client importable | no |
| M9 | **middleware + structured output** (Phase 3): custom-hook logic + keyless `create_agent` compile; live structured-output run when a model is present | no |
| M10 | **Store semantic search** (Phase 2): vector index + `store.search(query=...)` ranks relevant docs first, with scores | no |
| M11 | **DeltaChannel** (Phase 2, beta): reconstructs == full snapshot while its checkpoint blob is a sentinel; graph accumulates across steps | no |
| M12 | **Postgres persistence/store** (Phase 5): optional `PostgresSaver`/`PostgresStore` helpers import; live DB run when `POCKET_POSTGRES_URI` is set | no |
| M13 | **Node caching** (Phase 5): `CachePolicy(ttl=...)` + `InMemoryCache()` reuses a node result | no |
| M14 | **Custom StreamTransformer** (Phase 5): v3 transformer projects custom node progress into `custom:progress` | no |
| ALT | `create_agent` behavioral parity — **skips in mock mode** (needs a live model) | no |

## Layout

```
build.cmd / lmstudio.cmd       # Windows launchers
README.md                      # repo map + common commands
.gitignore
docs/
├── README.md                  # documentation index
├── project/
│   ├── AI_context.md          # this file
│   └── roadmap.md             # progress + remaining work
├── plans/
│   └── LangGraph_Foundations_Project_Plan.md   # original plan (reference)
└── reference/
    └── LangGraph_Information_Bank.md           # doc-sourced reference
scripts/
├── build_pocket_agent.sh      # THE GENERATOR (source of truth; edit heredocs here)
├── overnight_lmstudio.sh      # unattended build+verify against LM Studio
└── overnight_system_run.ps1   # Windows overnight monitor + optional check loop
examples/
└── delta_demo.py              # standalone DeltaChannel beta demo
pocket-agent/                  # GENERATED output of scripts/build_pocket_agent.sh
├── pocket_agent/
│   ├── __init__.py
│   ├── state.py               # MessagesState subclass
│   ├── tools.py               # calculator (safe AST eval), get_time, save_note, read_notes
│   ├── model.py               # provider detect + mock model; make_chat_model()
│   ├── graph.py               # build_graph(checkpointer, store, hitl) -> (compiled_graph, mode); route_after_agent
│   ├── stream.py              # drive(): v3 stream_events + fallback
│   ├── cli.py                 # interactive chat
│   ├── server_graph.py        # Phase 4: make_graph/make_graph_hitl factories (unwrap the tuple)
│   ├── semantic.py            # Phase 2: MockHashingEmbeddings, make_embeddings, make_semantic_store
│   ├── delta_demo.py          # Phase 2: DeltaChannel demo graph + compare_channels
│   ├── persistence.py         # Phase 5: optional PostgresSaver/PostgresStore helpers
│   ├── cache_demo.py          # Phase 5: CachePolicy + InMemoryCache demo
│   └── stream_projection.py   # Phase 5: custom v3 StreamTransformer demo
├── alt_create_agent/
│   ├── agent.py               # create_agent parity (ALT track)
│   └── middleware_showcase.py # Phase 3: middleware stack + NoteGuardMiddleware + response_format
├── tests/                     # pytest: tools, routing, middleware, semantic, delta, persistence, cache, stream projection
├── verify_milestones.py       # the self-test harness (M0–M14 + ALT)
├── langgraph.json             # Phase 4: exposes pocket_agent + pocket_agent_hitl
├── pyproject.toml / requirements.txt / .env.example
├── README.md
└── BUILD_REPORT.md            # regenerated by every verifier run
```

## Stack (pinned)

langgraph 1.2.7 · langchain 1.3.11 · langchain-core 1.4.8 · langgraph-checkpoint-sqlite 3.1.0 ·
langgraph-checkpoint-postgres 3.1.0 optional · psycopg 3.3.4 optional · langgraph-sdk 0.4.2 ·
langgraph-cli 0.4.30 · langgraph-prebuilt 1.1.0 ·
Python 3.13 (3.11+ required for `langgraph dev`).

## How to add a phase / milestone (the established pattern)

1. **Prototype first.** Verify exact APIs against the *installed* packages (introspect /
   read official docs — `docs.langchain.com`, `reference.langchain.com`). Don't assume names.
2. Add the source as a new **heredoc** in `scripts/build_pocket_agent.sh` (and any new test heredoc).
3. Add a milestone check function in the `verify_milestones.py` heredoc; register it
   `required=False` unless it's truly core. Make live-model-only checks **skip-aware** in
   mock mode (mirror the ALT track) so they never break the required set.
4. `bash scripts/build_pocket_agent.sh --check` to regenerate; run `pytest -q` and
   `POCKET_FORCE_MOCK=1 python verify_milestones.py` in mock mode.
5. Update `docs/project/roadmap.md` + this file. Commit as **one focused commit per phase**.
6. Stage precisely (never `git add -A`); restore `BUILD_REPORT.md` / scratch before staging.

## Current status

- ✅ Core (M0–M5) + stretch (M6, M7).
- ✅ **Phase 4** Server & Studio (M8) — also verified live: `langgraph dev` + SDK streaming run + HITL interrupt.
- ✅ **Phase 3** middleware + structured output (M9).
- ✅ **Phase 2** semantic search (M10) + DeltaChannel beta (M11).
- ✅ **Phase 5** — Postgres persistence/store (M12), node caching (M13), and
  custom `StreamTransformer` projection (M14) are implemented and verified. Live
  Postgres validation passed against a temporary Docker Postgres database.
- 🟡 **Phase 6** — polish: repo cleanup/docs are underway; live LM Studio
  validation now passes without skips.

Last keyless mock run: **15/15 PASS, 1 skip** (ALT) + **19/20 unit tests**
(1 skipped live Postgres test because `POCKET_POSTGRES_URI` was not set).
Last live LM Studio + Postgres run: **16/16 PASS, 0 skips** with `qwen/qwen3.5-9b`;
unit tests with live Postgres: **20/20 PASS**.
Manual CLI + LangGraph server validation passed on 2026-07-03; see
`docs/project/manual_validation.md`.
Model exploration found `meta-llama-3.1-8b-instruct` is a lighter full-pass
fallback; keep `qwen/qwen3.5-9b` as the default because it has the broadest
validation history in this repo.

## Gotchas worth remembering

- `build_graph(...)` returns a **`(compiled_graph, mode)` tuple** — `server_graph.py`
  factories unwrap it; `langgraph.json` uses the **module-form** spec
  (`pocket_agent.server_graph:make_graph`), because the file-path form breaks
  package-relative imports under the server loader.
- The server graph is compiled **without** a checkpointer — `langgraph dev` supplies
  persistence; `interrupt()` still works at run time.
- `DeltaChannel` is **beta** (API + on-disk format may change) — demo only.
- M9's live structured-output assertion needs a real model; in mock it only checks the
  custom hooks + keyless compile.
- M12's live Postgres assertion needs a reachable database via `POCKET_POSTGRES_URI`;
  keep `POCKET_POSTGRES_SETUP=1` explicit because it creates/migrates tables. Use
  `open_postgres_graph(...)` as a context manager so saver/store handles remain open
  while the graph runs.
- Local OpenAI-compatible models can emit an empty final assistant message after a
  valid tool result. `ensure_final_content(...)` falls back to the latest tool result
  so user-facing CLI/server responses do not appear blank.
- `StreamChannel` only buffers side-channel items after a consumer subscribes. The M14
  demo uses a named channel so progress is also visible on the main stream as
  `custom:progress`.
- `pip install numpy` makes `InMemoryStore` vector search faster (it falls back to pure
  Python otherwise — harmless warning).

