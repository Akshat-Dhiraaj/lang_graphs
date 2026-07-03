# Manual Validation

Manual user-facing validation completed on 2026-07-03 with LM Studio
`qwen/qwen3.5-9b` loaded at `ctx=4096`, `gpu=max`, `parallel=1`.

## CLI Walkthrough

Command:

```powershell
cd D:\lang_graphs\pocket-agent
$env:POCKET_USE_LMSTUDIO='1'
$env:POCKET_MODEL='qwen/qwen3.5-9b'
python -m pocket_agent.cli
```

Validated prompts:

```text
what is 1234 * 5678?
my name is Ada
what is my name?
save this note: LangGraph state is checkpointed
y
read my notes
```

Observed result:

- calculator tool returned `7,006,652`
- thread memory recalled `Ada`
- HITL paused before `save_note` and resumed after approval
- `read_notes` returned `1. LangGraph state is checkpointed`

## Server And Studio

Command:

```powershell
cd D:\lang_graphs\pocket-agent
$env:POCKET_USE_LMSTUDIO='1'
$env:POCKET_MODEL='qwen/qwen3.5-9b'
$env:PYTHONIOENCODING='utf-8'
langgraph dev --no-browser
```

Validated:

- server started at `http://127.0.0.1:2024`
- API docs responded at `http://127.0.0.1:2024/docs`
- Studio URL was emitted for `https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024`
- assistants listed through `langgraph-sdk`: `pocket_agent`, `pocket_agent_hitl`
- `pocket_agent` answered `47 * 89` as `4183`
- `pocket_agent_hitl` interrupted before `save_note`
- SDK resume with `command={"resume": True}` completed the save-note run

## Fix From Manual Testing

Manual CLI testing exposed a local-model edge case: after a tool result, Qwen
sometimes emitted an empty final assistant message. The graph now applies a
small fallback via `ensure_final_content(...)`: when the model returns an empty
final answer immediately after a tool result, the latest tool result is surfaced
as the final assistant content.

This keeps the CLI and server useful without special-casing any individual tool.
A regression test covers the fallback in `tests/test_routing.py`.

## Notes

`langgraph dev --help` can hit Windows `cp1252` output encoding issues because
the help text includes Unicode. Set `PYTHONIOENCODING=utf-8` for CLI help/server
commands when needed.
