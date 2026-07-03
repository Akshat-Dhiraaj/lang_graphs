# Sandbox Module

This directory contains the localhost app launched by the root
`launch_sandbox.ps1` file.

## Files

- `server.py` - Python stdlib HTTP server and sandbox API endpoints.
- `static/index.html` - browser markup.
- `static/styles.css` - browser styles.
- `static/app.js` - browser state, chat, tools, HITL, streaming, and docs UI.

## Boundary

The sandbox imports the committed generated package under `pocket-agent/`, but it
does not replace it. Durable generated-code changes still belong in
`scripts/build_pocket_agent.sh` first.

The launcher remains the user-facing entry point:

```powershell
.\launch_sandbox.ps1
```

Use this module for localhost UI/API changes only.
