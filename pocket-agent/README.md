# Pocket Agent (generated)

A foundations-first LangGraph agent built incrementally (M0-M7) plus a
`create_agent` alternative track. Generated and self-verified by
`build_pocket_agent.sh`.

## Model modes
Runs in deterministic **mock mode** with no API keys (verifies all wiring:
the agent<->tools cycle, SQLite persistence, HITL interrupts, streaming).
Set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (or `POCKET_USE_OLLAMA=1`) for real
answers and the `create_agent` track.

## Run
```bash
python verify_milestones.py     # re-run the milestone self-tests -> BUILD_REPORT.md
pytest -q                       # unit tests (tools + routing)
python -m pocket_agent.cli      # interactive chat
```

> M4 deliberately uses the v3 event-streaming API as the primary driver, with
> the stable `stream_mode` / `invoke` path as an automatic fallback.
