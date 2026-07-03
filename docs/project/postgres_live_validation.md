# Postgres Live Validation

This records the M12 live database validation run from 2026-07-03.

## Result

Live Postgres validation is complete.

```text
pytest: 20 passed, 2 warnings
verify_milestones.py: 16 passed, 0 failed, 0 skipped
M12: PostgresSaver/PostgresStore compiled and preserved thread memory
```

## Temporary Database

A disposable Docker Postgres container was used:

```powershell
docker run -d --name langgraphs-postgres-m12 `
  -e POSTGRES_PASSWORD=pocket `
  -e POSTGRES_USER=pocket `
  -e POSTGRES_DB=pocket_agent `
  -p 55432:5432 `
  postgres:16-alpine
```

Validation environment:

```powershell
$env:POCKET_USE_LMSTUDIO='1'
$env:POCKET_MODEL='qwen/qwen3.5-9b'
$env:POCKET_POSTGRES_URI='postgresql://pocket:pocket@127.0.0.1:55432/pocket_agent'
$env:POCKET_POSTGRES_SETUP='1'
Remove-Item Env:\POCKET_FORCE_MOCK -ErrorAction SilentlyContinue
.venv\Scripts\python.exe verify_milestones.py
```

## Fix Made

The first live run exposed a connection-lifetime bug: the graph was compiled
inside a Postgres context manager and returned after the saver/store connections
had already closed.

The helper is now explicit about lifetime:

- `open_postgres_persistence(...)` opens saver/store handles.
- `open_postgres_graph(...)` compiles the graph and keeps those handles open for
  the duration of the `with` block.

This keeps the code simple, avoids hidden global connections, and makes cleanup
obvious.

## Cleanup

The validation container was temporary. Remove it when finished:

```powershell
docker rm -f langgraphs-postgres-m12
```
