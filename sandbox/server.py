"""Local web sandbox server for the Pocket Agent workspace.

The server intentionally uses only Python's standard library plus the generated
Pocket Agent package. It is launched by ../launch_sandbox.ps1.
"""
from __future__ import annotations

import json
import mimetypes
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(os.environ["POCKET_SANDBOX_ROOT"]).resolve()
PORT = int(os.environ.get("POCKET_SANDBOX_PORT", "8765"))
STATIC_DIR = Path(__file__).resolve().parent / "static"

LMSTUDIO_BASE = os.environ.get("POCKET_LMSTUDIO_URL", "http://localhost:1234/v1").rstrip("/")
DEFAULT_MODEL = os.environ.get("POCKET_MODEL", "qwen/qwen3.5-9b")
DEFAULT_CTX = int(os.environ.get("POCKET_CTX", "4096"))
DEFAULT_GPU = os.environ.get("POCKET_GPU", "max")
DEFAULT_PARALLEL = int(os.environ.get("POCKET_PARALLEL", "1"))
DEFAULT_TTL = int(os.environ.get("POCKET_TTL", "28800"))
MAX_PROMPT_CHARS = 12000
MAX_DOC_CHARS = 9000

DOC_REFERENCES = [
    {
        "id": "roadmap",
        "title": "Roadmap",
        "description": "Current milestones, completed phases, and remaining work.",
        "path": "docs/project/roadmap.md",
    },
    {
        "id": "ai_context",
        "title": "AI Context",
        "description": "Operational handoff, verification commands, stack, and gotchas.",
        "path": "docs/project/AI_context.md",
    },
    {
        "id": "sandbox",
        "title": "Sandbox Launcher",
        "description": "Localhost sandbox behavior, provider paths, and validation notes.",
        "path": "docs/project/sandbox_launcher.md",
    },
    {
        "id": "langgraph_reference",
        "title": "LangGraph Reference",
        "description": "Fact-checked LangGraph notes from official docs and package sources.",
        "path": "docs/reference/LangGraph_Information_Bank.md",
    },
    {
        "id": "build_report",
        "title": "Build Report",
        "description": "Latest generated milestone verifier result.",
        "path": "pocket-agent/BUILD_REPORT.md",
    },
]

PROJECT_CONTEXT = """Pocket Agent is a local-first LangGraph foundations project.
Objective: teach and verify LangGraph primitives rather than ship a production product.
Verified milestones M0-M14 cover graph mechanics, chat memory, SQLite persistence,
the agent-tool-agent ReAct cycle, v3 streaming, human-in-the-loop interrupts,
long-term Store, time travel, Server/Studio/SDK loading, create_agent parity,
middleware, structured output, semantic store search, DeltaChannel, optional
Postgres helpers, node caching, and custom stream projection.
Default local model path: LM Studio at http://localhost:1234/v1 with qwen/qwen3.5-9b.
The repo can run keyless in deterministic mock mode, locally through LM Studio,
or with user-supplied provider keys. It includes build/test/verifier scripts,
docs, examples, an interactive CLI, and this localhost sandbox."""

DIRECT_SYSTEM_PROMPT = (
    "You are Pocket Agent Sandbox. Be concise and practical. "
    "Use the project context below when the user asks what this project is, "
    "what it can demonstrate, what is done, or what to try next. "
    "Direct provider chat has no real tool execution; for actual tool calls, "
    "tell the user to use Pocket Agent graph mode.\n\n"
    f"{PROJECT_CONTEXT}"
)

_agent_lock = threading.Lock()
_agent_graph = None
_agent_mode = None
_hitl_lock = threading.Lock()
_hitl_graph = None
_hitl_mode = None
_hitl_pending: dict[str, dict[str, str]] = {}


def is_project_summary_question(prompt: str) -> bool:
    text = prompt.lower()
    return (
        "project" in text
        and any(
            word in text
            for word in (
                "demonstrate",
                "objective",
                "summary",
                "capable",
                "can do",
                "what all",
                "what can",
                "explain",
                "goal",
            )
        )
    )


def is_langgraph_definition_question(prompt: str) -> bool:
    text = " ".join(prompt.lower().split())
    return (
        "langgraph" in text
        and (
            text.startswith("what is")
            or text.startswith("what's")
            or text.startswith("define")
            or text == "langgraph"
        )
    )


def langgraph_answer() -> str:
    return (
        "LangGraph is a low-level orchestration framework and runtime for "
        "building long-running, stateful agents. It models workflows as graphs: "
        "nodes do work, edges control routing, and a shared state object carries "
        "information through the run. In this project, LangGraph is demonstrated "
        "through a hand-built ReAct agent with tools, memory, streaming, "
        "human approval, persistence, Server/Studio support, and advanced demos "
        "such as semantic search, DeltaChannel, caching, and stream projection."
    )


def project_summary_answer() -> str:
    return (
        "Pocket Agent can demonstrate:\n"
        "- Hand-built LangGraph graph mechanics: state, nodes, edges, and the ReAct loop.\n"
        "- Tool use with real local tools: calculator, time, save_note, and read_notes.\n"
        "- Memory and persistence through SQLite checkpoints, plus optional Postgres helpers.\n"
        "- Streaming, human-in-the-loop approval, Server/Studio loading, and SDK calls.\n"
        "- Advanced learning demos: create_agent parity, middleware, structured output, "
        "semantic search, DeltaChannel, node caching, and custom stream projection."
    )


def grounded_answer(prompt: str) -> str:
    if is_langgraph_definition_question(prompt):
        return langgraph_answer()
    if is_project_summary_question(prompt):
        return project_summary_answer()
    return ""


def normalize_project_answer(prompt: str, text: str) -> str:
    return grounded_answer(prompt) or text


def with_project_context(prompt: str) -> str:
    return f"{DIRECT_SYSTEM_PROMPT}\n\nUser question:\n{prompt}"


def http_json(
    url: str,
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 90,
) -> dict[str, Any]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers or {})
    if payload is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {body[:1800]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(str(exc.reason)) from exc
    except TimeoutError as exc:
        raise RuntimeError("request timed out") from exc


def provider_label(provider: str) -> str:
    return {
        "lmstudio": "LM Studio",
        "custom-openai": "OpenAI-compatible provider",
        "openai": "OpenAI",
        "anthropic": "Anthropic",
        "gemini": "Gemini",
    }.get(provider, provider or "provider")


def provider_base_url(provider: str, base_url: str) -> str:
    if base_url:
        return base_url
    return {
        "lmstudio": LMSTUDIO_BASE,
        "custom-openai": LMSTUDIO_BASE,
        "openai": "https://api.openai.com/v1",
        "anthropic": "https://api.anthropic.com/v1",
        "gemini": "https://generativelanguage.googleapis.com/v1beta",
    }.get(provider, "")


def provider_error_message(provider: str, exc: Exception, base_url: str, model: str) -> str:
    raw = str(exc)
    lowered = raw.lower()
    label = provider_label(provider)
    hint = "Check the provider settings and try again."

    if "connection refused" in lowered or "no connection" in lowered or "actively refused" in lowered:
        hint = f"Could not reach {label}. Check that the server/base URL is running."
    elif "timed out" in lowered or "timeout" in lowered:
        hint = f"{label} did not answer before the timeout. The model may still be loading."
    elif "http 401" in lowered or "http 403" in lowered or "unauthorized" in lowered:
        hint = f"{label} rejected the request. Check the API key and account access."
    elif "http 404" in lowered or "not found" in lowered:
        hint = f"{label} could not find the endpoint or model. Check the base URL and model id."
    elif "http 400" in lowered:
        hint = f"{label} rejected the request format. Check the model id and supported parameters."

    target = []
    if base_url:
        target.append(f"base URL: {base_url}")
    if model:
        target.append(f"model: {model}")
    target_text = f" ({'; '.join(target)})" if target else ""
    return f"{label} request failed{target_text}. {hint} Details: {raw}"


def first_lmstudio_model(base_url: str) -> str:
    try:
        data = http_json(base_url.rstrip("/") + "/models", timeout=3)
    except Exception:
        return ""
    for item in data.get("data", []):
        model_id = str(item.get("id", ""))
        if model_id and "embed" not in model_id.lower():
            return model_id
    return ""


def openai_compat_chat(
    base_url: str,
    model: str,
    messages: list[dict[str, str]],
    api_key: str | None = None,
    temperature: float = 0.2,
    max_tokens: int = 900,
) -> tuple[str, dict[str, Any]]:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    data = http_json(base_url.rstrip("/") + "/chat/completions", payload, headers)
    choices = data.get("choices") or []
    if not choices:
        return "", data
    message = choices[0].get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        text = "\n".join(
            str(part.get("text", ""))
            for part in content
            if isinstance(part, dict)
        )
    else:
        text = str(content or "")
    return text, data


def anthropic_chat(model: str, prompt: str, api_key: str, max_tokens: int = 900) -> tuple[str, dict[str, Any]]:
    payload = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": with_project_context(prompt)}],
    }
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    data = http_json("https://api.anthropic.com/v1/messages", payload, headers)
    parts = []
    for part in data.get("content", []):
        if isinstance(part, dict) and part.get("type") == "text":
            parts.append(part.get("text", ""))
    return "\n".join(parts), data


def gemini_chat(
    model: str,
    prompt: str,
    api_key: str,
    temperature: float = 0.2,
    max_tokens: int = 900,
) -> tuple[str, dict[str, Any]]:
    safe_model = urllib.parse.quote(model, safe="-_.~/")
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{safe_model}:generateContent"
    payload = {
        "contents": [{"parts": [{"text": with_project_context(prompt)}]}],
        "generationConfig": {
            "temperature": temperature,
            "maxOutputTokens": max_tokens,
        },
    }
    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": api_key,
    }
    data = http_json(url, payload, headers)
    parts = []
    for candidate in data.get("candidates", []):
        content = candidate.get("content", {})
        for part in content.get("parts", []):
            if "text" in part:
                parts.append(part["text"])
    return "\n".join(parts), data


def bounded_float(value: Any, default: float, low: float, high: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        parsed = default
    return max(low, min(high, parsed))


def bounded_int(value: Any, default: int, low: int, high: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    return max(low, min(high, parsed))


def chat(payload: dict[str, Any]) -> dict[str, Any]:
    provider = str(payload.get("provider") or "lmstudio").strip()
    prompt = str(payload.get("prompt") or "").strip()
    model = str(payload.get("model") or "").strip()
    api_key = str(payload.get("apiKey") or "").strip()
    base_url = str(payload.get("baseUrl") or "").strip()
    temperature = bounded_float(payload.get("temperature"), 0.2, 0.0, 2.0)
    max_tokens = bounded_int(payload.get("maxTokens"), 900, 1, 16384)
    if not prompt:
        raise ValueError("Prompt is required")
    if len(prompt) > MAX_PROMPT_CHARS:
        raise ValueError(f"Prompt is too long; keep it under {MAX_PROMPT_CHARS} characters")

    local = grounded_answer(prompt)
    if local:
        return {"provider": "local", "model": "", "text": local}

    messages = [
        {"role": "system", "content": DIRECT_SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]

    try:
        if provider == "lmstudio":
            base = (base_url or LMSTUDIO_BASE).rstrip("/")
            selected = model or first_lmstudio_model(base) or os.environ.get("POCKET_MODEL", "local-model")
            text, _raw = openai_compat_chat(base, selected, messages, api_key or "lm-studio", temperature, max_tokens)
            return {"provider": "lmstudio", "model": selected, "text": normalize_project_answer(prompt, text)}
        if provider == "custom-openai":
            if not base_url:
                raise ValueError("Base URL is required for an OpenAI-compatible provider")
            if not model:
                raise ValueError("Model is required for this provider")
            text, _raw = openai_compat_chat(base_url, model, messages, api_key or None, temperature, max_tokens)
            return {"provider": "custom-openai", "model": model, "text": normalize_project_answer(prompt, text)}
        if provider == "openai":
            if not api_key:
                raise ValueError("OpenAI API key is required")
            if not model:
                raise ValueError("Enter an OpenAI model id")
            text, _raw = openai_compat_chat("https://api.openai.com/v1", model, messages, api_key, temperature, max_tokens)
            return {"provider": "openai", "model": model, "text": normalize_project_answer(prompt, text)}
        if provider == "anthropic":
            if not api_key:
                raise ValueError("Anthropic API key is required")
            if not model:
                raise ValueError("Enter a Claude model id")
            text, _raw = anthropic_chat(model, prompt, api_key, max_tokens)
            return {"provider": "anthropic", "model": model, "text": normalize_project_answer(prompt, text)}
        if provider == "gemini":
            if not api_key:
                raise ValueError("Gemini API key is required")
            if not model:
                raise ValueError("Enter a Gemini model id")
            text, _raw = gemini_chat(model, prompt, api_key, temperature, max_tokens)
            return {"provider": "gemini", "model": model, "text": normalize_project_answer(prompt, text)}
    except ValueError:
        raise
    except Exception as exc:
        active_base = provider_base_url(provider, base_url)
        raise RuntimeError(provider_error_message(provider, exc, active_base, model)) from exc
    raise ValueError(f"Unknown provider: {provider}")


def ensure_pocket_agent_ready() -> None:
    notes_path = ROOT / "pocket-agent" / ".build_tmp" / "sandbox_notes.json"
    os.environ.setdefault("POCKET_NOTES_PATH", str(notes_path))
    package_root = str(ROOT / "pocket-agent")
    if package_root not in sys.path:
        sys.path.insert(0, package_root)


def invoke_tool(payload: dict[str, Any]) -> dict[str, Any]:
    name = str(payload.get("name") or "").strip()
    args = payload.get("args") or {}
    if not isinstance(args, dict):
        raise ValueError("Tool args must be an object")
    ensure_pocket_agent_ready()
    from pocket_agent.tools import ALL_TOOLS

    tools = {tool.name: tool for tool in ALL_TOOLS}
    if name not in {"calculator", "get_time", "save_note", "read_notes"}:
        raise ValueError(f"Unknown tool: {name}")
    clean_args: dict[str, str] = {}
    if name == "calculator":
        clean_args["expression"] = str(args.get("expression") or "").strip()
        if not clean_args["expression"]:
            raise ValueError("Expression is required")
    elif name == "save_note":
        clean_args["text"] = str(args.get("text") or "").strip()
        if not clean_args["text"]:
            raise ValueError("Note text is required")
    result = tools[name].invoke(clean_args)
    return {"ok": True, "tool": name, "args": clean_args, "result": str(result)}


def get_agent_graph():
    global _agent_graph, _agent_mode
    ensure_pocket_agent_ready()
    with _agent_lock:
        if _agent_graph is None:
            from langgraph.checkpoint.memory import MemorySaver
            from pocket_agent.graph import build_graph

            _agent_graph, _agent_mode = build_graph(checkpointer=MemorySaver(), hitl=False)
        return _agent_graph, _agent_mode


def message_content(msg: Any) -> str:
    content = msg.get("content", "") if isinstance(msg, dict) else getattr(msg, "content", "")
    if isinstance(content, str):
        return content
    return str(content or "")


def message_type(msg: Any) -> str:
    if isinstance(msg, dict):
        return msg.get("type") or msg.get("role") or ""
    return getattr(msg, "type", "") or getattr(msg, "role", "")


def message_tool_calls(msg: Any) -> list[Any]:
    if isinstance(msg, dict):
        return msg.get("tool_calls") or []
    return getattr(msg, "tool_calls", None) or []


def collect_messages(value: Any) -> list[Any]:
    found = []
    if isinstance(value, dict):
        messages = value.get("messages")
        if isinstance(messages, list):
            found.extend(messages)
        for child in value.values():
            if child is not messages:
                found.extend(collect_messages(child))
    elif isinstance(value, (list, tuple)):
        for child in value:
            found.extend(collect_messages(child))
    return found


def describe_stream_message(msg: Any) -> tuple[str, str]:
    calls = message_tool_calls(msg)
    if calls:
        names = []
        for call in calls:
            if isinstance(call, dict):
                names.append(str(call.get("name") or call.get("function", {}).get("name") or "tool"))
            else:
                names.append(str(getattr(call, "name", "tool")))
        return "tool_call", "agent requested " + ", ".join(names)
    text = message_content(msg).strip()
    if not text:
        return "", ""
    role = message_type(msg)
    if role == "tool":
        return "tool", "tool result: " + text
    return "message", text


def graph_prompt_payload(prompt: str) -> dict[str, Any]:
    from pocket_agent.model import SYSTEM_PROMPT

    sandbox_system = (
        SYSTEM_PROMPT
        + "\n\nUse this project context when the user asks what this project is "
        "or what it can demonstrate. Do not claim the context came from saved notes.\n\n"
        + PROJECT_CONTEXT
    )
    return {
        "messages": [
            {"role": "system", "content": sandbox_system},
            {"role": "user", "content": prompt},
        ]
    }


def run_agent(payload: dict[str, Any]) -> dict[str, Any]:
    prompt = str(payload.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("Prompt is required")
    if len(prompt) > MAX_PROMPT_CHARS:
        raise ValueError(f"Prompt is too long; keep it under {MAX_PROMPT_CHARS} characters")
    thread_id = str(payload.get("threadId") or "sandbox-" + uuid.uuid4().hex[:8])

    local = grounded_answer(prompt)
    if local:
        return {
            "mode": "local",
            "provider": "pocket-agent",
            "model": os.environ.get("POCKET_MODEL", ""),
            "thread_id": thread_id,
            "text": local,
        }

    graph, mode = get_agent_graph()
    cfg = {"configurable": {"thread_id": thread_id}}
    result = graph.invoke(graph_prompt_payload(prompt), cfg)
    messages = result.get("messages", [])
    text = str(getattr(messages[-1], "content", "")) if messages else ""
    return {
        "mode": mode,
        "provider": "pocket-agent",
        "model": os.environ.get("POCKET_MODEL", ""),
        "thread_id": thread_id,
        "text": normalize_project_answer(prompt, text),
    }


def get_hitl_graph():
    global _hitl_graph, _hitl_mode
    ensure_pocket_agent_ready()
    with _hitl_lock:
        if _hitl_graph is None:
            from langgraph.checkpoint.memory import MemorySaver
            from pocket_agent.graph import build_graph

            old_force = os.environ.get("POCKET_FORCE_MOCK")
            os.environ["POCKET_FORCE_MOCK"] = "1"
            try:
                _hitl_graph, _hitl_mode = build_graph(checkpointer=MemorySaver(), hitl=True)
            finally:
                if old_force is None:
                    os.environ.pop("POCKET_FORCE_MOCK", None)
                else:
                    os.environ["POCKET_FORCE_MOCK"] = old_force
        return _hitl_graph, _hitl_mode


def serialize_interrupt(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return value
    if isinstance(value, (list, tuple)):
        return [serialize_interrupt(v) for v in value]
    public = {}
    for name in ("value", "id", "ns", "resumable"):
        if hasattr(value, name):
            try:
                public[name] = serialize_interrupt(getattr(value, name))
            except Exception:
                public[name] = str(getattr(value, name))
    return public or str(value)


def start_hitl(payload: dict[str, Any]) -> dict[str, Any]:
    text = str(payload.get("text") or "").strip()
    if not text:
        raise ValueError("Note text is required")
    if len(text) > 4000:
        raise ValueError("Note text is too long; keep it under 4000 characters")
    thread_id = str(payload.get("threadId") or "hitl-" + uuid.uuid4().hex[:8])
    graph, mode = get_hitl_graph()
    cfg = {"configurable": {"thread_id": thread_id}}
    prompt = f"Save a note with exactly this text: {text}"
    result = graph.invoke({"messages": [{"role": "user", "content": prompt}]}, cfg)
    interrupt_value = result.get("__interrupt__")
    if not interrupt_value:
        messages = result.get("messages", [])
        final = str(getattr(messages[-1], "content", "")) if messages else ""
        return {
            "paused": False,
            "thread_id": thread_id,
            "mode": mode,
            "text": final or "The graph finished without pausing.",
        }
    _hitl_pending[thread_id] = {"text": text}
    return {
        "paused": True,
        "thread_id": thread_id,
        "mode": mode,
        "interrupt": serialize_interrupt(interrupt_value),
        "text": f"Paused before saving note: {text}",
    }


def resume_hitl(payload: dict[str, Any]) -> dict[str, Any]:
    thread_id = str(payload.get("threadId") or "").strip()
    if not thread_id:
        raise ValueError("threadId is required")
    if thread_id not in _hitl_pending:
        raise ValueError("No pending HITL approval for this thread")
    approve = bool(payload.get("approve"))
    graph, mode = get_hitl_graph()
    from langgraph.types import Command

    cfg = {"configurable": {"thread_id": thread_id}}
    result = graph.invoke(Command(resume=approve), cfg)
    pending = _hitl_pending.pop(thread_id, {})
    messages = result.get("messages", [])
    final = str(getattr(messages[-1], "content", "")) if messages else ""
    return {
        "approved": approve,
        "thread_id": thread_id,
        "mode": mode,
        "note": pending.get("text", ""),
        "text": final or ("Approved and resumed." if approve else "Rejected and resumed."),
    }


def stream_start(handler: BaseHTTPRequestHandler) -> None:
    handler.send_response(200)
    handler.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
    handler.send_header("Cache-Control", "no-cache")
    handler.send_header("Connection", "close")
    handler.end_headers()


def stream_event(handler: BaseHTTPRequestHandler, event: dict[str, Any]) -> None:
    try:
        handler.wfile.write((json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8"))
        handler.wfile.flush()
    except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
        return


def stream_agent(handler: BaseHTTPRequestHandler, payload: dict[str, Any]) -> None:
    prompt = str(payload.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("Prompt is required")
    if len(prompt) > MAX_PROMPT_CHARS:
        raise ValueError(f"Prompt is too long; keep it under {MAX_PROMPT_CHARS} characters")
    thread_id = str(payload.get("threadId") or "sandbox-" + uuid.uuid4().hex[:8])

    stream_start(handler)
    local = grounded_answer(prompt)
    if local:
        stream_event(handler, {"event": "start", "thread_id": thread_id, "mode": "local"})
        stream_event(handler, {"event": "final", "thread_id": thread_id, "mode": "local", "text": local})
        return

    try:
        graph, mode = get_agent_graph()
        cfg = {"configurable": {"thread_id": thread_id}}
        stream_event(handler, {"event": "start", "thread_id": thread_id, "mode": mode})
        final_text = ""
        step = 0
        for update in graph.stream(graph_prompt_payload(prompt), cfg, stream_mode="updates"):
            step += 1
            for msg in collect_messages(update):
                kind, text = describe_stream_message(msg)
                if not text:
                    continue
                stream_event(
                    handler,
                    {
                        "event": "update",
                        "thread_id": thread_id,
                        "mode": mode,
                        "step": step,
                        "kind": kind,
                        "text": text,
                    },
                )
                if kind == "message":
                    final_text = text
                elif not final_text:
                    final_text = text
        if not final_text:
            try:
                state = graph.get_state(cfg)
                values = getattr(state, "values", {}) or {}
                messages = values.get("messages", [])
                if messages:
                    final_text = message_content(messages[-1]).strip()
            except Exception:
                final_text = ""
        stream_event(
            handler,
            {
                "event": "final",
                "thread_id": thread_id,
                "mode": mode,
                "text": normalize_project_answer(prompt, final_text or "(empty response)"),
            },
        )
    except Exception as exc:
        stream_event(handler, {"event": "error", "thread_id": thread_id, "error": str(exc)})


def run_lms(args: list[str], timeout: int = 60) -> dict[str, Any]:
    try:
        proc = subprocess.run(
            ["lms", *args],
            cwd=str(ROOT),
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        return {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": (proc.stdout or "").strip(),
            "stderr": (proc.stderr or "").strip(),
        }
    except FileNotFoundError:
        return {"ok": False, "returncode": 127, "stdout": "", "stderr": "lms CLI was not found on PATH"}
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "returncode": 124,
            "stdout": (exc.stdout or "").strip() if isinstance(exc.stdout, str) else "",
            "stderr": "lms command timed out",
        }


def parse_lms_ps(output: str) -> list[dict[str, Any]]:
    models = []
    for raw in (output or "").splitlines():
        line = raw.strip()
        if not line or line.startswith("IDENTIFIER") or line.startswith("No models"):
            continue
        parts = line.split()
        if len(parts) < 7:
            continue
        try:
            context = int(parts[5])
            parallel = int(parts[6])
        except ValueError:
            context = None
            parallel = None
        models.append(
            {
                "identifier": parts[0],
                "model": parts[1],
                "status": parts[2],
                "size": " ".join(parts[3:5]),
                "context": context,
                "parallel": parallel,
                "device": parts[7] if len(parts) > 7 else "",
                "ttl": " ".join(parts[8:]) if len(parts) > 8 else "",
            }
        )
    return models


def lms_status() -> dict[str, Any]:
    ps = run_lms(["ps"], timeout=30)
    models = parse_lms_ps(ps["stdout"])
    default = next(
        (m for m in models if m["identifier"] == DEFAULT_MODEL or m["model"] == DEFAULT_MODEL),
        None,
    )
    settings_ok = bool(
        default
        and default.get("context") == DEFAULT_CTX
        and default.get("parallel") == DEFAULT_PARALLEL
    )
    return {
        "available": ps["returncode"] != 127,
        "ok": ps["ok"],
        "stdout": ps["stdout"],
        "stderr": ps["stderr"],
        "models": models,
        "default": default,
        "default_loaded": bool(default),
        "settings_ok": settings_ok,
    }


def lmstudio_status() -> dict[str, Any]:
    lms = lms_status()
    loaded_model = first_lmstudio_model(LMSTUDIO_BASE)
    if not loaded_model and lms["models"]:
        loaded_model = lms["models"][0]["identifier"]
    return {
        "up": bool(loaded_model),
        "base_url": LMSTUDIO_BASE,
        "model": loaded_model,
        "default_model": DEFAULT_MODEL,
        "default_context": DEFAULT_CTX,
        "default_gpu": DEFAULT_GPU,
        "default_parallel": DEFAULT_PARALLEL,
        "default_ttl": DEFAULT_TTL,
        "default_loaded": lms["default_loaded"],
        "settings_ok": lms["settings_ok"],
        "loaded": lms["models"],
        "lms_available": lms["available"],
        "lms_error": lms["stderr"],
    }


def load_default_lmstudio_model() -> dict[str, Any]:
    before = lmstudio_status()
    if not before["lms_available"]:
        raise RuntimeError("lms CLI was not found on PATH")
    actions = []
    if before["default_loaded"] and before["settings_ok"]:
        return {
            "ok": True,
            "changed": False,
            "message": "Default model is already loaded with project settings.",
            "before": before,
            "after": before,
            "actions": actions,
        }

    if before["default_loaded"] and not before["settings_ok"]:
        unload = run_lms(["unload", DEFAULT_MODEL], timeout=90)
        actions.append({"command": f"lms unload {DEFAULT_MODEL}", **unload})
        if not unload["ok"]:
            raise RuntimeError(unload["stderr"] or unload["stdout"] or "Failed to unload default model")

    load_args = [
        "load",
        DEFAULT_MODEL,
        "--gpu",
        str(DEFAULT_GPU),
        "--context-length",
        str(DEFAULT_CTX),
        "--parallel",
        str(DEFAULT_PARALLEL),
        "--ttl",
        str(DEFAULT_TTL),
        "--identifier",
        DEFAULT_MODEL,
        "-y",
    ]
    load = run_lms(load_args, timeout=300)
    actions.append(
        {
            "command": (
                f"lms load {DEFAULT_MODEL} --gpu {DEFAULT_GPU} "
                f"--context-length {DEFAULT_CTX} --parallel {DEFAULT_PARALLEL} "
                f"--ttl {DEFAULT_TTL} --identifier {DEFAULT_MODEL} -y"
            ),
            **load,
        }
    )
    if not load["ok"]:
        raise RuntimeError(load["stderr"] or load["stdout"] or "Failed to load default model")

    after = lmstudio_status()
    if not after["default_loaded"]:
        raise RuntimeError("Load command finished, but the default model is not listed as loaded")
    return {
        "ok": True,
        "changed": True,
        "message": "Default model loaded.",
        "before": before,
        "after": after,
        "actions": actions,
    }


def git_status() -> dict[str, Any]:
    try:
        proc = subprocess.run(
            ["git", "status", "--short", "--branch"],
            cwd=str(ROOT),
            text=True,
            capture_output=True,
            timeout=5,
        )
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        return {"clean": len(lines) <= 1 and proc.returncode == 0, "text": proc.stdout.strip()}
    except Exception as exc:
        return {"clean": False, "text": str(exc)}


def build_report() -> dict[str, Any]:
    path = ROOT / "pocket-agent" / "BUILD_REPORT.md"
    if not path.exists():
        return {"ok": False, "result": ""}
    try:
        result = ""
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("- Result:"):
                result = line.replace("- Result:", "").strip().replace("**", "")
                break
        return {"ok": "0 failed" in result, "result": result}
    except Exception as exc:
        return {"ok": False, "result": str(exc)}


def read_reference_docs() -> dict[str, Any]:
    items = []
    for spec in DOC_REFERENCES:
        rel = spec["path"]
        path = (ROOT / rel).resolve()
        try:
            path.relative_to(ROOT)
        except ValueError:
            continue
        try:
            content = path.read_text(encoding="utf-8")
            truncated = len(content) > MAX_DOC_CHARS
            if truncated:
                content = content[:MAX_DOC_CHARS].rstrip() + "\n\n[trimmed for browser view]"
            items.append(
                {
                    "id": spec["id"],
                    "title": spec["title"],
                    "description": spec["description"],
                    "path": rel.replace("\\", "/"),
                    "content": content,
                    "truncated": truncated,
                }
            )
        except Exception as exc:
            items.append(
                {
                    "id": spec["id"],
                    "title": spec["title"],
                    "description": spec["description"],
                    "path": rel.replace("\\", "/"),
                    "content": f"Unable to read {rel}: {exc}",
                    "truncated": False,
                }
            )
    return {"items": items}


def status() -> dict[str, Any]:
    return {
        "root": str(ROOT),
        "python": sys.version.split()[0],
        "git": git_status(),
        "build": build_report(),
        "lmstudio": lmstudio_status(),
    }


def json_response(handler: BaseHTTPRequestHandler, payload: dict[str, Any], status_code: int = 200) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status_code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    try:
        handler.wfile.write(body)
    except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
        return


def error_response(handler: BaseHTTPRequestHandler, exc: Exception, status_code: int = 400) -> None:
    json_response(handler, {"ok": False, "error": str(exc)}, status_code)


def read_json(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0") or "0")
    raw = handler.rfile.read(length).decode("utf-8") if length else "{}"
    return json.loads(raw or "{}")


def send_file(handler: BaseHTTPRequestHandler, path: Path) -> None:
    data = path.read_bytes()
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    if content_type.startswith("text/") or path.suffix in {".js", ".css"}:
        content_type += "; charset=utf-8"
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    try:
        handler.wfile.write(data)
    except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
        return


class Handler(BaseHTTPRequestHandler):
    server_version = "PocketAgentSandbox/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[sandbox] {self.address_string()} - {fmt % args}", flush=True)

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path in {"/", "/index.html"}:
            send_file(self, STATIC_DIR / "index.html")
            return
        if path.startswith("/static/"):
            requested = (STATIC_DIR / path.removeprefix("/static/")).resolve()
            try:
                requested.relative_to(STATIC_DIR)
            except ValueError:
                error_response(self, ValueError("Invalid static path"), 404)
                return
            if requested.exists() and requested.is_file():
                send_file(self, requested)
                return
            error_response(self, FileNotFoundError(path), 404)
            return
        if path == "/api/status":
            json_response(self, status())
            return
        if path == "/api/lmstudio/status":
            json_response(self, lmstudio_status())
            return
        if path == "/api/docs/reference":
            json_response(self, read_reference_docs())
            return
        error_response(self, FileNotFoundError(path), 404)

    def do_POST(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        try:
            payload = read_json(self)
            if path == "/api/chat":
                json_response(self, chat(payload))
                return
            if path == "/api/agent":
                json_response(self, run_agent(payload))
                return
            if path == "/api/agent/stream":
                stream_agent(self, payload)
                return
            if path == "/api/tool":
                json_response(self, invoke_tool(payload))
                return
            if path == "/api/hitl/start":
                json_response(self, start_hitl(payload))
                return
            if path == "/api/hitl/resume":
                json_response(self, resume_hitl(payload))
                return
            if path == "/api/lmstudio/load-default":
                json_response(self, load_default_lmstudio_model())
                return
            error_response(self, FileNotFoundError(path), 404)
        except Exception as exc:
            error_response(self, exc, 400)


def main() -> None:
    os.chdir(ROOT)
    ensure_pocket_agent_ready()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Pocket Agent sandbox serving http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
