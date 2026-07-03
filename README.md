# LangGraph Pocket Agent Workspace

This workspace contains a generated LangGraph learning project plus the planning
and reference material that explains it.

## Quick Start

```powershell
.\build.cmd --check   # regenerate generated files and syntax-check them
.\build.cmd           # full build: install deps, run tests, verify milestones
.\lmstudio.cmd        # load the validated local model, then run the full build
.\launch_sandbox.ps1  # open the local project overview + model sandbox
.\scripts\overnight_system_run.ps1 -Hours 8 -RunBuildCheck -RunTests -RunMilestones
```

Manual CLI validation:

```powershell
cd .\pocket-agent
$env:POCKET_USE_LMSTUDIO='1'
$env:POCKET_MODEL='qwen/qwen3.5-9b'
python -m pocket_agent.cli
```

Studio/server validation:

```powershell
cd .\pocket-agent
$env:PYTHONIOENCODING='utf-8'
langgraph dev --no-browser
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
| `build.cmd`, `lmstudio.cmd`, `launch_sandbox.ps1` | Windows launchers for build, LM Studio validation, and the local web sandbox. |
| `sandbox/` | Hand-maintained localhost sandbox server and browser assets. |
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
- [Manual validation](docs/project/manual_validation.md) records the CLI and
  LangGraph server walkthrough.
- [Sandbox launcher](docs/project/sandbox_launcher.md) explains the local web
  overview and provider sandbox.
- [Docs index](docs/README.md) organizes the markdown knowledge base.
