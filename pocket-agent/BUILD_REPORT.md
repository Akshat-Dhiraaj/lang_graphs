# Pocket Agent — overnight build report

- Python: `3.13.13`
- Model mode: **mock**  _(mock: structural verification only — set a provider key for real answers)_
- Result: **11 passed, 1 failed, 1 skipped**  (required failures: 0)

## Milestones

| Milestone | Status | Detail | Req | Secs |
|---|---|---|---|---|
| M0 empty graph | PASS | START -> echo -> END returns input unchanged | yes | 0.02 |
| M1 model + chat memory | PASS | 2 messages; final is an AI answer | yes | 0.01 |
| M2 durable multi-turn memory | PASS | recall on same thread_id; isolation across a new thread_id | yes | 0.06 |
| M3 tools + the cycle | PASS | agent -> tool(calculator=5929288761) -> final answer (the cycle) | yes | 0.01 |
| M4 streaming (v3 + fallback) | PASS | streamed a final answer via path='stream_mode+invoke' |  | 0.0 |
| M5 human-approval gate (HITL) | PASS | interrupt pauses before write; resume=True writes, resume=False cancels | yes | 0.07 |
| M6 long-term Store | PASS | Store put/get/prefix-search works; graph compiles with store= |  | 0.01 |
| M7 time travel | PASS | 6 checkpoints enumerated; replayed from 1f162da5... |  | 0.05 |
| M8 server graph (langgraph dev / Studio / SDK) | PASS | langgraph.json OK; compiled graphs: pocket_agent, pocket_agent_hitl; SDK client importable |  | 0.01 |
| M9 middleware showcase + structured output | PASS | custom hooks OK; create_agent compiled with 6 middleware + structured output (live run skipped: mock mode) |  | 33.29 |
| M10 Store semantic search | PASS | semantic store (mock embeddings, dims=64): query ranked 'd3' first of 3 |  | 0.05 |
| M11 DeltaChannel (beta) diff-based checkpoints | FAIL | ModuleNotFoundError: No module named 'langgraph.channels.delta' |  | 0.0 |
| ALT create_agent track | SKIP | no live model in mock mode |  | 0.0 |

## Installed versions

| Package | Version |
|---|---|
| langgraph | 1.1.6 |
| langchain | 1.2.15 |
| langchain-core | 1.2.28 |
| langgraph-checkpoint | 4.1.1 |
| langgraph-checkpoint-sqlite | 3.1.0 |
| langgraph-sdk | 0.3.13 |
| langgraph-cli | - |
| langgraph-prebuilt | 1.0.9 |
| langchain-anthropic | - |
| langchain-openai | 1.1.12 |
| langchain-ollama | - |

## Next steps (need a human / a model)

- Provide a tool-calling model for *real* answers: set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (or `POCKET_USE_OLLAMA=1` with `ollama serve` + a tool-capable model) and re-run.
- Try it interactively: `python -m pocket_agent.cli`
- Optional Studio/server track: install `langgraph-cli[inmem]`, add a `langgraph.json`, run `langgraph dev`.
