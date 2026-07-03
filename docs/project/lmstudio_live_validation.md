# LM Studio Live Validation

This records the local model setup that passed the live, non-mock Pocket Agent
verifier on 2026-07-03.

## Verified Local Setup

| Setting | Value |
|---|---|
| LM Studio server | `http://127.0.0.1:1234/v1` |
| Loaded model | `qwen/qwen3.5-9b` |
| Context length | `4096` |
| GPU offload | `max` / 100% |
| Parallel predictions | `1` |
| TTL | `28800` seconds / 8 hours |
| Estimated GPU memory | `6.95 GiB` |
| Actual loaded size reported by LM Studio | `6.10 GiB` |

The raw OpenAI-compatible tool-call probe returned a `tool_calls` response for
the `calculator` function. The full project verifier then passed:

```text
16 passed / 0 failed / 0 skipped
```

That run covered the regular milestones M0-M14 and the live ALT
`create_agent` parity path.

## Commands

```powershell
lms load qwen/qwen3.5-9b --gpu max --context-length 4096 --parallel 1 --ttl 28800 --identifier qwen/qwen3.5-9b -y

$env:POCKET_USE_LMSTUDIO='1'
$env:POCKET_MODEL='qwen/qwen3.5-9b'
Remove-Item Env:\POCKET_FORCE_MOCK -ErrorAction SilentlyContinue
.\.venv\Scripts\python.exe verify_milestones.py
```

From the repo root, the maintained wrapper is:

```powershell
.\lmstudio.cmd
```

## Available Local Models

LM Studio reported these downloaded models:

| Type | Model |
|---|---|
| LLM | `qwen/qwen3.5-9b` |
| LLM | `qwen/qwen3.6-35b-a3b` |
| LLM | `google/gemma-4-e4b` |
| LLM | `google/gemma-4-12b` |
| LLM | `google/gemma-4-26b-a4b` |
| LLM | `meta-llama-3.1-8b-instruct` |
| Embedding | `text-embedding-nomic-embed-text-v1.5` |

## Why This Model First

The project needs reliable OpenAI-compatible tool calling more than long context
or creative prose. `qwen/qwen3.5-9b` is already local, fits the RTX 4060 laptop
GPU with full offload at context 4096, and passed the live calculator tool-call
probe plus the whole verifier.

## References

- LM Studio documents `lms load` with context length, GPU offload, TTL, and
  related load flags: <https://lmstudio.ai/docs/cli/local-models/load>
- LM Studio documents OpenAI-compatible clients by pointing the base URL at
  `http://localhost:1234/v1`: <https://lmstudio.ai/docs/developer/openai-compat>
- LM Studio documents `/v1/models` as the OpenAI-compatible model listing
  endpoint: <https://lmstudio.ai/docs/developer/openai-compat/models>
- LM Studio documents OpenAI-compatible tool calling and the `tool_calls`
  response field: <https://lmstudio.ai/docs/developer/openai-compat/tools>
