# Pocket Agent — overnight build report

- Python: `3.13.13`
- Model mode: **lmstudio**
- Result: **9 passed, 0 failed, 0 skipped**  (required failures: 0)

## Milestones

| Milestone | Status | Detail | Req | Secs |
|---|---|---|---|---|
| M0 empty graph | PASS | START -> echo -> END returns input unchanged | yes | 0.0 |
| M1 model + chat memory | PASS | 2 messages; final is an AI answer | yes | 8.76 |
| M2 durable multi-turn memory | PASS | recall on same thread_id; isolation across a new thread_id | yes | 7.26 |
| M3 tools + the cycle | PASS | agent -> tool(calculator=5929288761) -> final answer (the cycle) | yes | 3.69 |
| M4 streaming (v3 + fallback) | PASS | streamed a final answer via path='v3' |  | 2.32 |
| M5 human-approval gate (HITL) | PASS | interrupt pauses before write; resume=True writes, resume=False cancels | yes | 5.27 |
| M6 long-term Store | PASS | Store put/get/prefix-search works; graph compiles with store= |  | 0.01 |
| M7 time travel | PASS | 6 checkpoints enumerated; replayed from 1f16054d... |  | 4.28 |
| ALT create_agent track | PASS | create_agent reached behavioral parity (6*7=42) |  | 2.26 |

## Installed versions

| Package | Version |
|---|---|
| langgraph | 1.2.4 |
| langchain | 1.3.4 |
| langchain-core | 1.4.0 |
| langgraph-checkpoint | 4.1.1 |
| langgraph-checkpoint-sqlite | 3.1.0 |
| langgraph-sdk | 0.4.2 |
| langgraph-prebuilt | 1.1.0 |
| langchain-anthropic | - |
| langchain-openai | 1.2.2 |
| langchain-ollama | - |

## Next steps (need a human / a model)

- Provide a tool-calling model for *real* answers: set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (or `POCKET_USE_OLLAMA=1` with `ollama serve` + a tool-capable model) and re-run.
- Try it interactively: `python -m pocket_agent.cli`
- Optional Studio/server track: install `langgraph-cli[inmem]`, add a `langgraph.json`, run `langgraph dev`.
