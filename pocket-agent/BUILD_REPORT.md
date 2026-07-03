# Pocket Agent — overnight build report

- Python: `3.13.14`
- Model mode: **lmstudio**
- Result: **16 passed, 0 failed, 0 skipped**  (required failures: 0)

## Milestones

| Milestone | Status | Detail | Req | Secs |
|---|---|---|---|---|
| M0 empty graph | PASS | START -> echo -> END returns input unchanged | yes | 0.0 |
| M1 model + chat memory | PASS | 2 messages; final is an AI answer | yes | 3.01 |
| M2 durable multi-turn memory | PASS | recall on same thread_id; isolation across a new thread_id | yes | 6.9 |
| M3 tools + the cycle | PASS | agent -> tool(calculator=5929288761) -> final answer (the cycle) | yes | 3.57 |
| M4 streaming (v3 + fallback) | PASS | streamed a final answer via path='v3' |  | 2.29 |
| M5 human-approval gate (HITL) | PASS | interrupt pauses before write; resume=True writes, resume=False cancels | yes | 5.4 |
| M6 long-term Store | PASS | Store put/get/prefix-search works; graph compiles with store= |  | 0.0 |
| M7 time travel | PASS | 6 checkpoints enumerated; replayed from 1f17699b... |  | 4.43 |
| M8 server graph (langgraph dev / Studio / SDK) | PASS | langgraph.json OK; compiled graphs: pocket_agent, pocket_agent_hitl; SDK client importable |  | 0.01 |
| M9 middleware showcase + structured output | PASS | custom hooks OK; compiled; live structured_response present (mode=lmstudio) |  | 2.07 |
| M10 Store semantic search | PASS | semantic store (mock embeddings, dims=64): query ranked 'd3' first of 3 |  | 0.0 |
| M11 DeltaChannel (beta) diff-based checkpoints | PASS | DeltaChannel reconstructs == full snapshot over 8 writes; checkpoint stores a sentinel (vs full list len 8); graph accumulated 5 steps |  | 0.01 |
| M12 Postgres persistence/store | PASS | Postgres helpers import; live DB run skipped (set POCKET_POSTGRES_URI) |  | 0.06 |
| M13 node caching | PASS | CachePolicy + InMemoryCache reused the second node result |  | 0.0 |
| M14 custom StreamTransformer | PASS | StreamTransformer projected custom progress as custom:progress |  | 0.0 |
| ALT create_agent track | PASS | create_agent reached behavioral parity (6*7=42) |  | 2.21 |

## Installed versions

| Package | Version |
|---|---|
| langgraph | 1.2.7 |
| langchain | 1.3.11 |
| langchain-core | 1.4.8 |
| langgraph-checkpoint | 4.1.1 |
| langgraph-checkpoint-sqlite | 3.1.0 |
| langgraph-sdk | 0.4.2 |
| langgraph-cli | 0.4.30 |
| langgraph-prebuilt | 1.1.0 |
| langgraph-checkpoint-postgres | 3.1.0 |
| psycopg | 3.3.4 |
| langchain-anthropic | - |
| langchain-openai | 1.2.2 |
| langchain-ollama | - |

## Next steps

- Live model mode is already active (`lmstudio`). Use `POCKET_FORCE_MOCK=1` when you want deterministic keyless checks.
- Optional live Postgres check: set `POCKET_POSTGRES_URI` and `POCKET_POSTGRES_SETUP=1` when you want the verifier to create or migrate tables.
- Try it interactively: `python -m pocket_agent.cli`
- Optional Studio/server track: run `langgraph dev` from `pocket-agent/`.
