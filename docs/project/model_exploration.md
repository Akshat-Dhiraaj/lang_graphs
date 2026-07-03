# Model Exploration

Local model exploration was run on 2026-07-03 through LM Studio's
OpenAI-compatible API. The project goal was tool-calling reliability for the
hand-built LangGraph agent and the `create_agent` alternate path.

## Current Default

`qwen/qwen3.5-9b` remains the default model in `scripts/overnight_lmstudio.sh`.
It has already passed the full live verifier and manual CLI/server validation.

## Candidates Tested

| Model | Load Settings | Result | Notes |
|---|---|---|---|
| `qwen/qwen3.5-9b` | `ctx=4096`, `gpu=max`, `parallel=1` | Full verifier pass | Current default and most exercised model. |
| `meta-llama-3.1-8b-instruct` | `ctx=4096`, `gpu=max`, `parallel=1` | Full verifier pass | Lightest passing LLM tested; loaded size reported by LM Studio was `4.58 GiB`. |
| `google/gemma-4-e4b` | `ctx=4096`, `gpu=max`, `parallel=1` | Core graph pass; ALT parity failed | Raw tool calling worked and M0-M14 passed, but `create_agent` ALT final answer did not satisfy parity. |

## Raw Tool-Call Probe

Both `meta-llama-3.1-8b-instruct` and `google/gemma-4-e4b` returned an
OpenAI-compatible `tool_calls` response for the calculator probe:

```text
Use the calculator tool to compute 1234 * 5678.
```

## Recommendation

Keep `qwen/qwen3.5-9b` as the default because it has the broadest validation
history in this repo. Use `meta-llama-3.1-8b-instruct` as the lighter fallback
when GPU memory or load time matters.

Do not promote `google/gemma-4-e4b` as the default for this project unless the
ALT `create_agent` parity behavior is improved or accepted as out of scope.
