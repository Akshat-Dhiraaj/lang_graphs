# Documentation Index

The markdown files are grouped by how they should be used.

## Project State

- [AI_context.md](project/AI_context.md) — operational handoff for humans and AI
  assistants. Read this before changing code.
- [roadmap.md](project/roadmap.md) — current status, milestones, and remaining
  work.
- [overnight_system_run.md](project/overnight_system_run.md) — system snapshot,
  overnight monitor command, and log layout.
- [lmstudio_live_validation.md](project/lmstudio_live_validation.md) — verified
  local model, load settings, and live verifier result.
- [model_exploration.md](project/model_exploration.md) — local model comparison
  and recommendation.
- [postgres_live_validation.md](project/postgres_live_validation.md) — live M12
  Postgres validation result, Docker command, and connection-lifetime fix.
- [manual_validation.md](project/manual_validation.md) — CLI and LangGraph
  server/Studio walkthrough results.
- [sandbox_launcher.md](project/sandbox_launcher.md) — local localhost overview,
  provider sandbox, and latest repo gap review.

## Plans

- [LangGraph_Foundations_Project_Plan.md](plans/LangGraph_Foundations_Project_Plan.md)
  — original plan and acceptance criteria. It is historical context; the roadmap
  is the current source for status.

## Reference

- [LangGraph_Information_Bank.md](reference/LangGraph_Information_Bank.md) —
  fact-checked LangGraph notes from official docs and package sources.

## Working Rule

`pocket-agent/` is generated output. Durable code changes inside that generated
project belong in `scripts/build_pocket_agent.sh` first, then the generated tree
should be regenerated and verified. Root launchers and `docs/` are hand
maintained. The localhost sandbox app in `sandbox/` is also hand maintained and
is launched by the root `launch_sandbox.ps1` entry point.

