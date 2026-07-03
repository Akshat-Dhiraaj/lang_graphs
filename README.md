# LangGraph Pocket Agent Workspace

This workspace contains a generated LangGraph learning project plus the planning
and reference material that explains it.

## Quick Start

```powershell
.\build.cmd --check   # regenerate generated files and syntax-check them
.\build.cmd           # full build: install deps, run tests, verify milestones
.\scripts\overnight_system_run.ps1 -Hours 8 -RunBuildCheck -RunTests -RunMilestones
```

From Git Bash:

```bash
bash scripts/build_pocket_agent.sh --check
bash scripts/build_pocket_agent.sh
```

## Directory Map

| Path | Purpose |
|---|---|
| `pocket-agent/` | Generated Python project. Do not hand-edit without also updating the generator. |
| `scripts/build_pocket_agent.sh` | Source-of-truth generator and verifier for `pocket-agent/`. |
| `scripts/overnight_lmstudio.sh` | LM Studio model provisioning plus full build. |
| `scripts/overnight_system_run.ps1` | 6-8 hour Windows system monitor plus optional build/test/milestone loop. |
| `build.cmd`, `lmstudio.cmd` | Windows launchers that call the scripts through Git Bash. |
| `docs/project/` | Living project context and roadmap. |
| `docs/plans/` | Original project plan retained for reference. |
| `docs/reference/` | Fact-checked LangGraph information bank. |
| `examples/` | Standalone examples not required by the generated package. |

## Read First

- [AI context](docs/project/AI_context.md) explains the source-of-truth rule,
  verification workflow, stack, and gotchas.
- [Roadmap](docs/project/roadmap.md) tracks what is implemented and what remains.
- [Overnight system run](docs/project/overnight_system_run.md) explains the
  long-running monitor/debug script.
- [Docs index](docs/README.md) organizes the markdown knowledge base.
