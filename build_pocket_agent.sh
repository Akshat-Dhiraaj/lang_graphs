#!/usr/bin/env bash
# =============================================================================
# build_pocket_agent.sh
# Autonomous overnight builder for the "Pocket Agent" LangGraph project
# (see LangGraph_Foundations_Project_Plan.md).
#
# Goal: kick this off before bed; it builds AS MUCH AS POSSIBLE on its own.
#   - Scaffolds the repo, generates all source, creates a venv, installs deps.
#   - Implements milestones M0-M7 + the create_agent alternative track.
#   - SELF-VERIFIES every milestone and writes BUILD_REPORT.md.
#   - Needs NO API keys: runs in deterministic MOCK mode by default, which
#     still exercises the full graph (cycles, persistence, HITL, streaming).
#   - Auto-upgrades to a real model if it finds ANTHROPIC_API_KEY /
#     OPENAI_API_KEY, or POCKET_USE_OLLAMA=1 with a local Ollama server.
#
# Usage:
#   bash build_pocket_agent.sh            # full overnight build
#   bash build_pocket_agent.sh --check    # generate + syntax-check only (fast, no install)
#   bash build_pocket_agent.sh --clean    # wipe build dir first, then full build
#
# Config (env overrides):
#   POCKET_BUILD_DIR   target dir            (default: <script dir>/pocket-agent)
#   POCKET_MODEL       model name override   (provider default otherwise)
#   POCKET_USE_OLLAMA  =1 to use local Ollama if reachable
#   POCKET_FORCE_MOCK  =1 to force mock mode even if keys are present
#   POCKET_SKIP_CLI    =1 to skip langgraph-cli[inmem] (installed by default; Studio/server + M8 check)
#
# Runs on Linux, macOS, WSL, or Git Bash on Windows. POSIX bash.
# =============================================================================

set -uo pipefail   # NOTE: deliberately NOT 'set -e' -- we want to build as
                   # much as possible and keep going past non-fatal failures.

# ----------------------------------------------------------------------------- paths & logging
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
BUILD_DIR="${POCKET_BUILD_DIR:-$SCRIPT_DIR/pocket-agent}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$BUILD_DIR/logs"
LOG="$LOG_DIR/build_$RUN_ID.log"

MODE_CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check)  MODE_CHECK=1 ;;
    --clean)  rm -rf "$BUILD_DIR" ;;
    --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg (try --help)"; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"

say()  { printf '%s | %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
hr()   { printf '%s\n' "----------------------------------------------------------------------" | tee -a "$LOG"; }
phase(){ hr; say "PHASE: $*"; hr; }
warn() { say "WARN  $*"; }
die()  { say "FATAL $*"; say "See log: $LOG"; exit 1; }

trap 'say "interrupted (signal)"; exit 130' INT TERM

phase "Pocket Agent overnight build  (run $RUN_ID)"
say "build dir : $BUILD_DIR"
say "log file  : $LOG"
say "mode      : $([ "$MODE_CHECK" = 1 ] && echo 'CHECK (generate + syntax-check only)' || echo 'FULL')"

# ----------------------------------------------------------------------------- locate a Python >= 3.10
phase "Preflight: locate Python >= 3.10"
SYS_PY=""
for cand in python3.13 python3.12 python3.11 python3.10 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,10) else 1)' 2>/dev/null; then
      SYS_PY="$cand"; break
    fi
  fi
done
[ -n "$SYS_PY" ] || die "No Python >= 3.10 found on PATH. Install one and re-run."
say "using interpreter: $SYS_PY ($("$SYS_PY" --version 2>&1))"

# detect a 'timeout' binary so live-model calls can't hang the night
VTIMEOUT="${POCKET_VERIFY_TIMEOUT:-900}"
TIMEOUT=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT="timeout $VTIMEOUT";
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout $VTIMEOUT"; fi
[ -n "$TIMEOUT" ] || warn "no 'timeout' binary; long model calls won't be force-capped"

# ============================================================================= generate sources
generate_sources() {
  phase "Scaffold project tree + generate source"
  mkdir -p "$BUILD_DIR/pocket_agent" "$BUILD_DIR/alt_create_agent" "$BUILD_DIR/tests"
  cd "$BUILD_DIR" || die "cannot cd into build dir"

  # ---- pocket_agent/__init__.py
  cat > pocket_agent/__init__.py <<'PY'
"""Pocket Agent — a foundations-first LangGraph build (generated)."""
__all__ = ["state", "tools", "model", "graph", "stream", "server_graph",
           "semantic", "delta_demo"]
PY

  # ---- pocket_agent/state.py  (M1: MessagesState subclass)
  cat > pocket_agent/state.py <<'PY'
"""M1 - State. Subclass MessagesState so the `messages` channel uses the
`add_messages` reducer (append + dedupe-by-id)."""
from langgraph.graph import MessagesState


class State(MessagesState):
    """Chat state. Inherits: messages: Annotated[list, add_messages]."""
    pass
PY

  # ---- pocket_agent/tools.py  (M3: deterministic local tools)
  cat > pocket_agent/tools.py <<'PY'
"""M3 - deterministic, local, side-effect-tiny tools. No network, no model."""
import ast
import os
import pathlib
import datetime
import operator as _op
from langchain_core.tools import tool

# ---- safe arithmetic (no eval) ---------------------------------------------
_ALLOWED = {
    ast.Add: _op.add, ast.Sub: _op.sub, ast.Mult: _op.mul, ast.Div: _op.truediv,
    ast.Pow: _op.pow, ast.Mod: _op.mod, ast.FloorDiv: _op.floordiv,
    ast.USub: _op.neg, ast.UAdd: _op.pos,
}


def _eval(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _ALLOWED:
        return _ALLOWED[type(node.op)](_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _ALLOWED:
        return _ALLOWED[type(node.op)](_eval(node.operand))
    raise ValueError("unsupported expression")


@tool
def calculator(expression: str) -> str:
    """Evaluate a basic arithmetic expression, e.g. '47 * 89'."""
    try:
        return str(_eval(ast.parse(expression, mode="eval").body))
    except Exception as e:  # noqa: BLE001 - tools should not raise
        return f"error: {e}"


@tool
def get_time() -> str:
    """Return the current local time as an ISO-8601 string."""
    return datetime.datetime.now().isoformat(timespec="seconds")


def _notes_path() -> pathlib.Path:
    return pathlib.Path(os.getenv("POCKET_NOTES_PATH", "notes.json"))


@tool
def save_note(text: str) -> str:
    """Append a note to the local notes file. Returns a confirmation."""
    p = _notes_path()
    notes = []
    if p.exists():
        try:
            notes = __import__("json").loads(p.read_text(encoding="utf-8"))
        except Exception:
            notes = []
    notes.append(text)
    p.write_text(__import__("json").dumps(notes, indent=2), encoding="utf-8")
    return f"saved note #{len(notes)}: {text!r}"


@tool
def read_notes() -> str:
    """Return all saved notes, newest last."""
    p = _notes_path()
    if not p.exists():
        return "(no notes yet)"
    try:
        notes = __import__("json").loads(p.read_text(encoding="utf-8"))
    except Exception:
        return "(notes file unreadable)"
    return "\n".join(f"{i+1}. {n}" for i, n in enumerate(notes)) or "(no notes yet)"


ALL_TOOLS = [calculator, get_time, save_note, read_notes]
PY

  # ---- pocket_agent/model.py  (model detection + mock fallback)
  cat > pocket_agent/model.py <<'PY'
"""Model layer.

Auto-detects a provider; falls back to a deterministic MOCK that emits real
tool-call AIMessages so the ENTIRE graph (the agent<->tools cycle, persistence,
HITL, streaming) runs end-to-end with zero API keys.
"""
import os
import re
from langchain_core.messages import AIMessage


def _ollama_up() -> bool:
    try:
        import urllib.request
        urllib.request.urlopen("http://localhost:11434/api/tags", timeout=1).read()
        return True
    except Exception:
        return False


def _lmstudio_url() -> str:
    return os.getenv("POCKET_LMSTUDIO_URL", "http://localhost:1234/v1").rstrip("/")


def _lmstudio_up() -> bool:
    try:
        import urllib.request
        urllib.request.urlopen(_lmstudio_url() + "/models", timeout=2).read()
        return True
    except Exception:
        return False


def _lmstudio_first_model() -> str:
    try:
        import urllib.request
        import json
        d = json.load(urllib.request.urlopen(_lmstudio_url() + "/models", timeout=3))
        for m in d.get("data", []):
            mid = m.get("id", "")
            if mid and "embed" not in mid.lower():
                return mid
    except Exception:
        pass
    return os.getenv("POCKET_MODEL", "local-model")


SYSTEM_PROMPT = (
    "You are Pocket Agent, a concise tool-using assistant. You MUST call a tool "
    "rather than answering from memory for: arithmetic (use `calculator`), the "
    "current time (use `get_time`), saving text (use `save_note`), and listing "
    "notes (use `read_notes`). Never invent tool results. After a tool result "
    "returns, reply with a short final answer."
)


def detect_mode() -> str:
    if os.getenv("POCKET_FORCE_MOCK") == "1":
        return "mock"
    if os.getenv("POCKET_USE_LMSTUDIO") == "1" or _lmstudio_up():
        return "lmstudio"
    if os.getenv("ANTHROPIC_API_KEY"):
        return "anthropic"
    if os.getenv("OPENAI_API_KEY"):
        return "openai"
    if os.getenv("POCKET_USE_OLLAMA") == "1" and _ollama_up():
        return "ollama"
    return "mock"


def make_chat_model():
    """Return (mode, raw_model_or_None). None means mock mode."""
    mode = detect_mode()
    try:
        if mode == "lmstudio":
            from langchain_openai import ChatOpenAI
            return mode, ChatOpenAI(
                base_url=_lmstudio_url(), api_key="lm-studio",
                model=os.getenv("POCKET_MODEL") or _lmstudio_first_model(),
                temperature=0, timeout=120)
        if mode == "anthropic":
            from langchain_anthropic import ChatAnthropic
            return mode, ChatAnthropic(
                model=os.getenv("POCKET_MODEL", "claude-3-5-haiku-latest"), temperature=0)
        if mode == "openai":
            from langchain_openai import ChatOpenAI
            return mode, ChatOpenAI(
                model=os.getenv("POCKET_MODEL", "gpt-4o-mini"), temperature=0)
        if mode == "ollama":
            from langchain_ollama import ChatOllama
            return mode, ChatOllama(
                model=os.getenv("POCKET_MODEL", "qwen2.5"), temperature=0)
    except Exception as e:  # provider lib missing / misconfigured -> degrade
        print(f"[model] provider '{mode}' unavailable ({e}); using mock")
    return "mock", None


def build_model(tools):
    """Return (mode, bound_model_or_None) ready for the agent node."""
    mode, m = make_chat_model()
    if m is None:
        return "mock", None
    try:
        return mode, m.bind_tools(tools)
    except Exception:
        return mode, m


_ARITH = re.compile(
    r'(-?\d+(?:\.\d+)?\s*[-+*/]\s*-?\d+(?:\.\d+)?(?:\s*[-+*/]\s*-?\d+(?:\.\d+)?)*)')


def mock_respond(messages):
    """Deterministic stand-in for a tool-calling chat model."""
    last = messages[-1]
    role = getattr(last, "type", "")
    content = getattr(last, "content", "") or ""
    text = content if isinstance(content, str) else str(content)

    # Just got a tool result -> emit a final answer (ends the ReAct loop).
    if role == "tool":
        return AIMessage(content=f"(mock) Done. Result: {text}")

    low = text.lower()
    norm = text.replace("x", "*").replace("×", "*")

    m = _ARITH.search(norm)
    if m:
        return AIMessage(content="", tool_calls=[{
            "name": "calculator", "args": {"expression": m.group(1).strip()},
            "id": "call_calc", "type": "tool_call"}])
    if "note" in low and ":" in text:
        note = text.split(":", 1)[1].strip()
        return AIMessage(content="", tool_calls=[{
            "name": "save_note", "args": {"text": note},
            "id": "call_note", "type": "tool_call"}])
    if "time" in low or "hour" in low:
        return AIMessage(content="", tool_calls=[{
            "name": "get_time", "args": {}, "id": "call_time", "type": "tool_call"}])
    if "my name" in low:
        name = None
        for msg in messages:
            c = getattr(msg, "content", "") or ""
            mt = re.search(r"my name is (\w+)", c if isinstance(c, str) else "", re.I)
            if mt:
                name = mt.group(1)
        return AIMessage(content=(f"(mock) Your name is {name}." if name
                                  else "(mock) I don't know your name yet."))
    return AIMessage(content=f"(mock) You said: {text}")
PY

  # ---- pocket_agent/graph.py  (M0->M5: the ReAct graph)
  cat > pocket_agent/graph.py <<'PY'
"""The canonical ReAct graph: agent <-> tools cycle, one conditional edge.

build_graph(checkpointer=?, store=?, hitl=?) -> (compiled_graph, mode)
route_after_agent(state) is exposed module-level so it can be unit-tested
without constructing a model.
"""
from langgraph.graph import StateGraph, START, END
from langchain_core.messages import ToolMessage, SystemMessage

from .state import State
from .tools import ALL_TOOLS
from .model import build_model, mock_respond, SYSTEM_PROMPT

TOOLS = ALL_TOOLS
_TOOLS_BY_NAME = {t.name: t for t in TOOLS}


def route_after_agent(state):
    """Conditional edge: go to tools if the last AI message asked for one."""
    last = state["messages"][-1]
    if getattr(last, "tool_calls", None):
        return "tools"
    return END


def build_graph(checkpointer=None, store=None, hitl=False):
    mode, model = build_model(TOOLS)

    def agent_node(state):
        if model is None:
            msg = mock_respond(state["messages"])
        else:
            msgs = list(state["messages"])
            if not msgs or getattr(msgs[0], "type", "") != "system":
                msgs = [SystemMessage(content=SYSTEM_PROMPT)] + msgs
            msg = model.invoke(msgs)
        return {"messages": [msg]}

    def tool_node(state):
        last = state["messages"][-1]
        out = []
        for tc in last.tool_calls:
            name = tc["name"]
            args = dict(tc.get("args", {}) or {})
            cid = tc.get("id", name)
            # M5 human-approval gate (interrupt BEFORE the side effect so the
            # node is idempotent on resume, per the official rules of interrupts)
            if hitl and name == "save_note":
                from langgraph.types import interrupt
                decision = interrupt({"action": name, "args": args})
                if decision in (False, "reject", "no"):
                    out.append(ToolMessage(content="(cancelled by human)",
                                           tool_call_id=cid))
                    continue
                if isinstance(decision, dict):
                    args.update(decision)
            result = _TOOLS_BY_NAME[name].invoke(args)
            out.append(ToolMessage(content=str(result), tool_call_id=cid))
        return {"messages": out}

    b = StateGraph(State)
    b.add_node("agent", agent_node)
    b.add_node("tools", tool_node)
    b.add_edge(START, "agent")
    b.add_conditional_edges("agent", route_after_agent, ["tools", END])
    b.add_edge("tools", "agent")  # the cycle
    return b.compile(checkpointer=checkpointer, store=store), mode
PY

  # ---- pocket_agent/stream.py  (M4: v3 event streaming + stable fallback)
  cat > pocket_agent/stream.py <<'PY'
"""M4 - drive a run. Tries the v3 event-streaming API first, then falls back
to the stable stream_mode / invoke path. Returns (final_text, path_used)."""


def drive(graph, user_input, config=None):
    payload = {"messages": [{"role": "user", "content": user_input}]}

    # --- preferred: v3 typed-projection event streaming -------------------
    try:
        stream = graph.stream_events(payload, config=config, version="v3")
        parts = []
        for message in stream.messages:
            txt = getattr(message, "text", "")
            if isinstance(txt, str):
                parts.append(txt)
            else:
                try:
                    for tok in txt:
                        parts.append(tok)
                except TypeError:
                    parts.append(str(txt))
        final = "".join(parts).strip()
        if not final:
            raise RuntimeError("v3 produced no text")
        return final, "v3"
    except Exception:
        pass

    # --- stable fallback: stream_mode then a definitive invoke ------------
    try:
        for _ in graph.stream(payload, config, stream_mode="updates"):
            pass
        res = graph.invoke(payload, config)
        return str(res["messages"][-1].content), "stream_mode+invoke"
    except Exception:
        res = graph.invoke(payload, config)
        return str(res["messages"][-1].content), "invoke"
PY

  # ---- pocket_agent/cli.py  (terminal loop; not auto-run overnight)
  cat > pocket_agent/cli.py <<'PY'
"""Interactive CLI. Run with: python -m pocket_agent.cli  (not used by the
overnight verifier, which drives the graph programmatically)."""
import sqlite3
import uuid
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command
from .graph import build_graph


def main():
    conn = sqlite3.connect("pocket.db", check_same_thread=False)
    graph, mode = build_graph(checkpointer=SqliteSaver(conn), hitl=True)
    tid = str(uuid.uuid4())
    cfg = {"configurable": {"thread_id": tid}}
    print(f"Pocket Agent [mode={mode}] thread={tid}. Ctrl-D to exit.")
    while True:
        try:
            user = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user:
            continue
        res = graph.invoke({"messages": [{"role": "user", "content": user}]}, cfg)
        if "__interrupt__" in res:
            ans = input(f"[approve? y/n] {res['__interrupt__']} > ")
            res = graph.invoke(
                Command(resume=ans.strip().lower().startswith("y")), cfg)
        print("bot>", res["messages"][-1].content)


if __name__ == "__main__":
    main()
PY

  # ---- pocket_agent/semantic.py  (Phase 2: Store semantic search)
  cat > pocket_agent/semantic.py <<'PY'
"""Phase 2 (stretch) - long-term Store *semantic* search.

Verified against langgraph 1.2.4 / langchain-core 1.4.x: `InMemoryStore` enables
vector search when constructed with an `index={"dims", "embed", "fields"}` config
(disabled by default); `store.search(ns, query=...)` then returns scored items.

Embeddings are keyless by default (a deterministic hashing vectorizer, so the
whole feature runs in mock mode with no model). Set `POCKET_EMBED_MODEL` (plus the
matching provider env) to use real embeddings (an LM Studio / Ollama / OpenAI
embedding model).
"""
import os
import math
import hashlib

from langchain_core.embeddings import Embeddings
from langgraph.store.memory import InMemoryStore


class MockHashingEmbeddings(Embeddings):
    """Deterministic, keyless, dependency-free embeddings.

    Hashes each lowercased alphanumeric token into a fixed-width vector and
    L2-normalizes, so cosine similarity reflects lexical overlap. Good enough to
    demonstrate semantic-style retrieval without downloading a model.
    """

    def __init__(self, dims: int = 64):
        self.dims = dims

    def _vec(self, text: str):
        v = [0.0] * self.dims
        cleaned = "".join(c.lower() if c.isalnum() else " " for c in (text or ""))
        for tok in cleaned.split():
            v[int(hashlib.md5(tok.encode()).hexdigest(), 16) % self.dims] += 1.0
        norm = math.sqrt(sum(x * x for x in v)) or 1.0
        return [x / norm for x in v]

    def embed_documents(self, texts):
        return [self._vec(t) for t in texts]

    def embed_query(self, text):
        return self._vec(text)


def make_embeddings():
    """Return ``(mode, embeddings, dims)``.

    Defaults to the keyless mock embedder (the chat provider is usually not an
    embedding model). Opt into real embeddings with ``POCKET_EMBED_MODEL`` + the
    matching provider env (``OPENAI_API_KEY``, ``POCKET_USE_LMSTUDIO=1``, or
    ``POCKET_USE_OLLAMA=1``); set ``POCKET_EMBED_DIMS`` to match the model.
    """
    model = os.getenv("POCKET_EMBED_MODEL")
    if os.getenv("POCKET_FORCE_MOCK") == "1" or not model:
        return "mock", MockHashingEmbeddings(64), 64
    dims_env = os.getenv("POCKET_EMBED_DIMS")
    try:
        if os.getenv("OPENAI_API_KEY"):
            from langchain_openai import OpenAIEmbeddings
            return "openai", OpenAIEmbeddings(model=model), int(dims_env or 1536)
        if os.getenv("POCKET_USE_LMSTUDIO") == "1":
            from langchain_openai import OpenAIEmbeddings
            base = os.getenv("POCKET_LMSTUDIO_BASE", "http://localhost:1234/v1")
            return "lmstudio", OpenAIEmbeddings(base_url=base, api_key="lm-studio",
                                                model=model), int(dims_env or 768)
        if os.getenv("POCKET_USE_OLLAMA") == "1":
            from langchain_ollama import OllamaEmbeddings
            return "ollama", OllamaEmbeddings(model=model), int(dims_env or 768)
    except Exception:
        pass
    return "mock", MockHashingEmbeddings(64), 64


def make_semantic_store(embeddings=None, dims=None):
    """An InMemoryStore with vector search enabled (semantic search is off by
    default until an index config is supplied)."""
    if embeddings is None:
        _mode, embeddings, dims = make_embeddings()
    if dims is None:
        dims = getattr(embeddings, "dims", 1536)
    return InMemoryStore(index={"dims": dims, "embed": embeddings, "fields": ["text"]})
PY

  # ---- pocket_agent/delta_demo.py  (Phase 2: DeltaChannel beta)
  cat > pocket_agent/delta_demo.py <<'PY'
"""Phase 2 (stretch) - DeltaChannel (beta): diff-based checkpoint storage.

Verified against langgraph 1.2.4: ``DeltaChannel(reducer, typ, *, snapshot_frequency)``
is a beta reducer channel that stores only a sentinel in each checkpoint blob and
reconstructs state by replaying ancestor writes, so per-checkpoint storage stays
~constant instead of growing with the accumulated value (avoids O(N^2) blob growth
for append-only channels like long message/file histories).

Attach it to a state key with ``Annotated[T, DeltaChannel(reducer)]``.
"""
import functools
import operator
from typing import Annotated, TypedDict

from langgraph.channels.delta import DeltaChannel
from langgraph.channels.binop import BinaryOperatorAggregate
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.memory import InMemorySaver


# DeltaChannel reducer contract: (base_value, sequence_of_writes) -> new_value.
# This mirrors a list-concatenating BinaryOperatorAggregate(operator.add).
def append_reducer(base, writes):
    return functools.reduce(operator.add, writes, list(base))


class DeltaState(TypedDict):
    log: Annotated[list[str], DeltaChannel(append_reducer, list)]
    n: int


def build_delta_demo_graph(steps: int = 5, *, checkpointer=None):
    """A tiny loop that appends to a DeltaChannel-backed ``log`` for ``steps`` steps."""
    def step(state: DeltaState):
        i = state.get("n", 0)
        return {"log": [f"step{i}"], "n": i + 1}

    def cont(state: DeltaState):
        return END if state.get("n", 0) >= steps else "step"

    builder = (StateGraph(DeltaState)
               .add_node("step", step)
               .add_edge(START, "step")
               .add_conditional_edges("step", cont, {"step": "step", END: END}))
    return builder.compile(checkpointer=checkpointer or InMemorySaver())


def compare_channels(n: int = 8):
    """Apply the same ``n`` writes to a DeltaChannel and an equivalent
    BinaryOperatorAggregate; return
    ``(same_value, delta_blob_is_sentinel, full_snapshot_len, n)``."""
    d = DeltaChannel(append_reducer, list)
    d.key = "log"
    b = BinaryOperatorAggregate(list, operator.add)
    b.key = "log"
    for i in range(n):
        d.update([[f"e{i}"]])
        b.update([[f"e{i}"]])
    same = d.get() == b.get()
    delta_blob = d.checkpoint()          # sentinel (MISSING), NOT the list
    full_blob = b.checkpoint()           # the full growing list
    delta_is_sentinel = not isinstance(delta_blob, list)
    return same, delta_is_sentinel, len(full_blob), n
PY

  # ---- alt_create_agent/agent.py  (section 7: high-level factory)
  cat > alt_create_agent/agent.py <<'PY'
"""Section 7 - the same agent via the high-level create_agent factory.
Requires a live model (create_agent reasons with a real LLM)."""
import sqlite3
from langgraph.checkpoint.sqlite import SqliteSaver

from pocket_agent.model import make_chat_model
from pocket_agent.tools import ALL_TOOLS


def build_alt_agent(db_path="alt.db"):
    mode, model = make_chat_model()
    if model is None:
        raise RuntimeError("create_agent needs a live model (set a provider key)")
    from langchain.agents import create_agent
    cp = SqliteSaver(sqlite3.connect(db_path, check_same_thread=False))
    agent = create_agent(model, tools=ALL_TOOLS, checkpointer=cp)
    return agent, mode
PY

  # ---- alt_create_agent/middleware_showcase.py  (Phase 3: middleware + structured output)
  cat > alt_create_agent/middleware_showcase.py <<'PY'
"""Section 7+ (Phase 3) - middleware showcase + custom middleware + structured
output, all on the high-level `create_agent` track.

Verified against langchain 1.3.4: prebuilt middleware live in
`langchain.agents.middleware`; structured-output strategies in
`langchain.agents.structured_output`; a custom middleware subclasses
`AgentMiddleware` and overrides typed hooks.

Like the base ALT track, the *live* behaviour (real reasoning, summarization,
structured parsing) needs a real model; construction/compilation and the custom
guardrail logic are deterministic and verified in mock mode.
"""
import sqlite3
from typing import Any

from pydantic import BaseModel, Field
from langchain_core.messages import SystemMessage, ToolMessage
from langchain.agents import create_agent
from langchain.agents.middleware import (
    AgentMiddleware,
    ToolCallRequest,
    SummarizationMiddleware,
    ModelCallLimitMiddleware,
    ToolCallLimitMiddleware,
    PIIMiddleware,
    HumanInTheLoopMiddleware,
)
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.checkpoint.sqlite import SqliteSaver

from pocket_agent.model import make_chat_model
from pocket_agent.tools import ALL_TOOLS

_GUARD_NOTE = "Guardrail active: never save an empty note; keep answers concise."


class ShowcaseAnswer(BaseModel):
    """Structured final answer (create_agent `response_format`)."""
    answer: str = Field(description="the final answer to the user")
    tools_used: list[str] = Field(default_factory=list,
                                  description="names of tools the agent used")


class NoteGuardMiddleware(AgentMiddleware):
    """Custom middleware demonstrating two hooks:

    * ``before_model`` - inject a one-time system guardrail reminder (idempotent).
    * ``wrap_tool_call`` - block ``save_note`` when the text is empty/whitespace,
      returning a ToolMessage error *without* running the tool.
    """

    def before_model(self, state, runtime=None) -> dict[str, Any] | None:
        msgs = (state.get("messages", []) if isinstance(state, dict)
                else getattr(state, "messages", []))
        for m in msgs:
            if isinstance(m, SystemMessage) and _GUARD_NOTE in (m.content or ""):
                return None  # already injected -> idempotent
        return {"messages": [SystemMessage(content=_GUARD_NOTE)]}

    def wrap_tool_call(self, request: ToolCallRequest, handler):
        call = request.tool_call
        name = call.get("name") if isinstance(call, dict) else getattr(call, "name", None)
        args = (call.get("args") if isinstance(call, dict) else getattr(call, "args", {})) or {}
        call_id = (call.get("id") if isinstance(call, dict) else getattr(call, "id", None)) or "0"
        if name == "save_note" and not str(args.get("text", "")).strip():
            return ToolMessage(content="error: refusing to save an empty note",
                               tool_call_id=call_id, status="error")
        return handler(request)


def _middleware_stack(model):
    """Prebuilt + custom middleware (all provider-agnostic). Order = inbound order."""
    return [
        PIIMiddleware("email", strategy="redact"),                  # sanitize inbound PII
        NoteGuardMiddleware(),                                      # custom guardrail
        ToolCallLimitMiddleware(thread_limit=10),                   # cap tool calls
        ModelCallLimitMiddleware(thread_limit=10, run_limit=6),     # cap model calls
        SummarizationMiddleware(model=model,                        # compress long history
                                trigger=("tokens", 3000),
                                keep=("messages", 10)),
        HumanInTheLoopMiddleware(interrupt_on={"save_note": True}),  # human approval gate
    ]


def build_showcase_agent(model, *, checkpointer=None):
    """Compile the showcase agent. ``model`` is a BaseChatModel or provider
    string (create_agent + middleware require a model, never None)."""
    return create_agent(
        model=model,
        tools=ALL_TOOLS,
        middleware=_middleware_stack(model),
        response_format=ShowcaseAnswer,
        checkpointer=checkpointer or InMemorySaver(),
    )


def build_live_showcase_agent(db_path="showcase.db"):
    """Live variant: resolve the configured provider; needs a real model."""
    mode, model = make_chat_model()
    if model is None:
        raise RuntimeError("middleware showcase needs a live model "
                           "(set a provider key or POCKET_USE_LMSTUDIO=1)")
    cp = SqliteSaver(sqlite3.connect(db_path, check_same_thread=False))
    return build_showcase_agent(model, checkpointer=cp), mode
PY

  # ---- pocket_agent/server_graph.py  (section 8: expose graph to langgraph dev / Studio / SDK)
  cat > pocket_agent/server_graph.py <<'PY'
"""Section 8 - expose the graph to `langgraph dev` / Studio / the SDK.

`langgraph.json` can't point at `build_graph` directly: it returns a
`(compiled_graph, mode)` tuple, but the server expects a *compiled graph*
(or a zero-arg factory returning one). These factories unwrap the tuple.

Persistence is deliberately NOT compiled in: `langgraph dev` (and the deployed
platform) supply their own checkpointer/store, so the graph is compiled WITHOUT
one to avoid conflicting with server-managed persistence. HITL `interrupt()`
still works because the server provides the checkpointer at run time.
"""
from .graph import build_graph


def make_graph(config=None):
    """Plain ReAct graph (agent <-> tools cycle); server manages persistence."""
    graph, _mode = build_graph(checkpointer=None, store=None, hitl=False)
    return graph


def make_graph_hitl(config=None):
    """Same graph with the human-approval gate on `save_note` enabled, so the
    interrupt -> resume flow is visible and clickable in Studio."""
    graph, _mode = build_graph(checkpointer=None, store=None, hitl=True)
    return graph
PY

  # ---- langgraph.json  (section 8: server/Studio config)
  cat > langgraph.json <<'JSON'
{
  "$schema": "https://langgra.ph/schema.json",
  "dependencies": ["."],
  "graphs": {
    "pocket_agent": "pocket_agent.server_graph:make_graph",
    "pocket_agent_hitl": "pocket_agent.server_graph:make_graph_hitl"
  },
  "env": ".env"
}
JSON

  # ---- tests/test_tools.py
  cat > tests/test_tools.py <<'PY'
import os
import pathlib
import datetime

os.environ.setdefault("POCKET_NOTES_PATH",
                      str(pathlib.Path(".build_tmp") / "test_notes.json"))
pathlib.Path(".build_tmp").mkdir(exist_ok=True)

from pocket_agent.tools import calculator, get_time, save_note, read_notes


def test_calculator_mul():
    assert calculator.invoke({"expression": "47 * 89"}) == "4183"


def test_calculator_div():
    assert calculator.invoke({"expression": "10 / 4"}) == "2.5"


def test_calculator_rejects_code():
    assert calculator.invoke({"expression": "__import__('os')"}).startswith("error")


def test_get_time_is_iso():
    datetime.datetime.fromisoformat(get_time.invoke({}))


def test_notes_roundtrip():
    p = pathlib.Path(os.environ["POCKET_NOTES_PATH"])
    if p.exists():
        p.unlink()
    save_note.invoke({"text": "alpha"})
    save_note.invoke({"text": "beta"})
    out = read_notes.invoke({})
    assert "alpha" in out and "beta" in out
PY

  # ---- tests/test_routing.py
  cat > tests/test_routing.py <<'PY'
from langchain_core.messages import AIMessage
from langgraph.graph import END
from pocket_agent.graph import route_after_agent


def test_routes_to_tools_on_tool_call():
    s = {"messages": [AIMessage(content="", tool_calls=[{
        "name": "calculator", "args": {"expression": "1+1"},
        "id": "x", "type": "tool_call"}])]}
    assert route_after_agent(s) == "tools"


def test_routes_to_end_on_plain_answer():
    s = {"messages": [AIMessage(content="all done")]}
    assert route_after_agent(s) == END
PY

  # ---- tests/test_middleware.py  (Phase 3: custom middleware hooks, deterministic)
  cat > tests/test_middleware.py <<'PY'
import itertools
from langchain_core.messages import AIMessage, SystemMessage, HumanMessage, ToolMessage
from langchain_core.language_models.fake_chat_models import GenericFakeChatModel
from langgraph.checkpoint.memory import InMemorySaver
from langchain.agents.middleware import ToolCallRequest
from alt_create_agent.middleware_showcase import (
    NoteGuardMiddleware, build_showcase_agent)


def test_before_model_injects_once_then_idempotent():
    mw = NoteGuardMiddleware()
    out = mw.before_model({"messages": [HumanMessage(content="hi")]})
    assert out and any(isinstance(m, SystemMessage) for m in out["messages"])
    assert mw.before_model({"messages": out["messages"]}) is None


def test_wrap_tool_call_blocks_empty_note():
    mw = NoteGuardMiddleware()
    ran = {"called": False}
    def handler(req):
        ran["called"] = True
        return ToolMessage(content="saved", tool_call_id="x")
    empty = ToolCallRequest(
        tool_call={"name": "save_note", "args": {"text": "  "}, "id": "x", "type": "tool_call"},
        tool=None, state={"messages": []}, runtime=None)
    res = mw.wrap_tool_call(empty, handler)
    assert getattr(res, "status", None) == "error" and not ran["called"]


def test_wrap_tool_call_delegates_valid_note():
    mw = NoteGuardMiddleware()
    ran = {"called": False}
    def handler(req):
        ran["called"] = True
        return ToolMessage(content="saved", tool_call_id="y")
    ok = ToolCallRequest(
        tool_call={"name": "save_note", "args": {"text": "real"}, "id": "y", "type": "tool_call"},
        tool=None, state={"messages": []}, runtime=None)
    res = mw.wrap_tool_call(ok, handler)
    assert ran["called"] and res.content == "saved"


def test_showcase_agent_compiles_keyless():
    fake = GenericFakeChatModel(messages=itertools.cycle([AIMessage(content="ok")]))
    agent = build_showcase_agent(fake, checkpointer=InMemorySaver())
    assert hasattr(agent, "invoke") and hasattr(agent, "stream")
PY

  # ---- tests/test_semantic.py  (Phase 2: semantic search, deterministic mock embedder)
  cat > tests/test_semantic.py <<'PY'
from pocket_agent.semantic import MockHashingEmbeddings, make_semantic_store


def test_mock_embeddings_dims_and_norm():
    emb = MockHashingEmbeddings(64)
    v = emb.embed_query("hello world")
    assert len(v) == 64
    assert abs(sum(x * x for x in v) - 1.0) < 1e-6  # L2-normalized


def test_semantic_search_ranks_relevant_first():
    store = make_semantic_store(MockHashingEmbeddings(64), 64)
    store.put(("docs",), "d1", {"text": "python programming language tutorial"})
    store.put(("docs",), "d2", {"text": "italian pasta and pizza recipes"})
    store.put(("docs",), "d3", {"text": "guide to the rust programming language"})
    res = store.search(("docs",), query="programming language", limit=3)
    assert res and res[0].key in {"d1", "d3"}
    assert all(getattr(r, "score", None) is not None for r in res)
PY

  # ---- tests/test_delta.py  (Phase 2: DeltaChannel beta, deterministic)
  cat > tests/test_delta.py <<'PY'
from pocket_agent.delta_demo import compare_channels, build_delta_demo_graph
from langgraph.checkpoint.memory import InMemorySaver


def test_delta_reconstructs_like_full_snapshot_but_stores_sentinel():
    same, sentinel, full_len, n = compare_channels(8)
    assert same and sentinel and full_len == 8 and n == 8


def test_delta_graph_accumulates_across_steps():
    g = build_delta_demo_graph(steps=5, checkpointer=InMemorySaver())
    out = g.invoke({"log": [], "n": 0}, {"configurable": {"thread_id": "t"}})
    assert out["log"] == [f"step{i}" for i in range(5)]
PY

  # ---- verify_milestones.py  (the overnight self-test harness)
  cat > verify_milestones.py <<'PY'
"""Run every milestone, record PASS/SKIP/FAIL, write BUILD_REPORT.md.
Exit code = number of FAILED *required* milestones (0 = good)."""
import os
import sys
import time
import sqlite3
import pathlib
import traceback
import importlib.metadata as md

sys.path.insert(0, os.getcwd())

TMP = pathlib.Path(".build_tmp")
TMP.mkdir(exist_ok=True)
os.environ.setdefault("POCKET_NOTES_PATH", str(TMP / "notes.json"))
NOTES = pathlib.Path(os.environ["POCKET_NOTES_PATH"])


def fresh(name):
    p = TMP / name
    if p.exists():
        p.unlink()
    return str(p)


def clear_notes():
    if NOTES.exists():
        NOTES.unlink()


# --- imports that the whole harness depends on ------------------------------
try:
    from langgraph.checkpoint.sqlite import SqliteSaver
    from langgraph.types import Command
    from langgraph.graph import StateGraph, START, END
    from pocket_agent.graph import build_graph, route_after_agent, TOOLS
    from pocket_agent.model import detect_mode, make_chat_model
    from pocket_agent.stream import drive
except Exception as e:
    pathlib.Path("BUILD_REPORT.md").write_text(
        f"# Pocket Agent build report\n\nCATASTROPHIC import failure: {e!r}\n\n"
        f"```\n{traceback.format_exc()}\n```\n", encoding="utf-8")
    print(f"[CATASTROPHIC] {e}")
    sys.exit(2)

MODE = detect_mode()
results = []  # (id, status, detail, required, secs)


def record(mid, fn, required=False):
    t = time.time()
    try:
        detail = fn() or "ok"
        results.append((mid, "PASS", detail, required, round(time.time() - t, 2)))
        print(f"[PASS] {mid}: {detail}")
    except Exception as e:
        results.append((mid, "FAIL", f"{type(e).__name__}: {e}", required,
                        round(time.time() - t, 2)))
        print(f"[FAIL] {mid}: {e}")
        traceback.print_exc(limit=2)


def skip(mid, reason):
    results.append((mid, "SKIP", reason, False, 0.0))
    print(f"[SKIP] {mid}: {reason}")


# ============================ milestones ====================================
def m0():
    from typing import TypedDict

    class S(TypedDict):
        value: str

    b = StateGraph(S)
    b.add_node("echo", lambda s: {"value": s["value"]})
    b.add_edge(START, "echo")
    b.add_edge("echo", END)
    g = b.compile()
    assert g.invoke({"value": "ping"})["value"] == "ping"
    return "START -> echo -> END returns input unchanged"


def m1():
    g, _ = build_graph()
    res = g.invoke({"messages": [{"role": "user", "content": "hello there"}]})
    msgs = res["messages"]
    assert len(msgs) >= 2 and msgs[-1].type == "ai"
    return f"{len(msgs)} messages; final is an AI answer"


def m2():
    cp = SqliteSaver(sqlite3.connect(fresh("m2.db"), check_same_thread=False))
    g, _ = build_graph(checkpointer=cp)
    a = {"configurable": {"thread_id": "m2-a"}}
    g.invoke({"messages": [{"role": "user", "content": "my name is Ada"}]}, a)
    r = g.invoke({"messages": [{"role": "user", "content": "what is my name?"}]}, a)
    assert "Ada" in str(r["messages"][-1].content), "did not recall name on same thread"
    b = {"configurable": {"thread_id": "m2-b"}}
    r2 = g.invoke({"messages": [{"role": "user", "content": "what is my name?"}]}, b)
    assert "Ada" not in str(r2["messages"][-1].content), "leaked across threads"
    return "recall on same thread_id; isolation across a new thread_id"


def m3():
    a, b = 918273, 6457
    expected = str(a * b)
    g, _ = build_graph()
    res = g.invoke({"messages": [{"role": "user",
                    "content": f"Use the calculator tool to compute {a} * {b}."}]})
    msgs = res["messages"]
    assert any(getattr(m, "type", "") == "tool" and expected in str(m.content)
               for m in msgs), "calculator tool did not run / wrong result"
    assert msgs[-1].type == "ai" and not getattr(msgs[-1], "tool_calls", None)
    return f"agent -> tool(calculator={expected}) -> final answer (the cycle)"


def m4():
    g, _ = build_graph()
    out, path = drive(g, "what is 12 + 30?", {"configurable": {"thread_id": "m4"}})
    assert out and len(out) > 0, "no streamed output"
    return f"streamed a final answer via path='{path}'"


def m5():
    clear_notes()
    cp = SqliteSaver(sqlite3.connect(fresh("m5.db"), check_same_thread=False))
    g, _ = build_graph(checkpointer=cp, hitl=True)
    # approve path
    ca = {"configurable": {"thread_id": "m5-approve"}}
    r = g.invoke({"messages": [{"role": "user",
                  "content": "Save a note with exactly this text: overnight build OK"}]}, ca)
    assert "__interrupt__" in r, "did not pause at the HITL gate"
    g.invoke(Command(resume=True), ca)
    assert NOTES.exists() and "overnight build OK" in NOTES.read_text(encoding="utf-8")
    # reject path
    cr = {"configurable": {"thread_id": "m5-reject"}}
    r2 = g.invoke({"messages": [{"role": "user",
                   "content": "Save a note with exactly this text: should NOT persist"}]}, cr)
    assert "__interrupt__" in r2
    g.invoke(Command(resume=False), cr)
    assert "should NOT persist" not in NOTES.read_text(encoding="utf-8")
    return "interrupt pauses before write; resume=True writes, resume=False cancels"


def m6():
    from langgraph.store.memory import InMemoryStore
    st = InMemoryStore()
    ns = ("user-1", "memories")
    st.put(ns, "name", {"value": "Ada"})
    got = st.get(ns, "name")
    assert got and got.value["value"] == "Ada"
    found = st.search(("user-1",))
    assert any(it.key == "name" for it in found), "prefix search missed the item"
    g, _ = build_graph(store=st)  # graph accepts a store
    return "Store put/get/prefix-search works; graph compiles with store="


def m7():
    cp = SqliteSaver(sqlite3.connect(fresh("m7.db"), check_same_thread=False))
    g, _ = build_graph(checkpointer=cp)
    c = {"configurable": {"thread_id": "m7"}}
    g.invoke({"messages": [{"role": "user", "content": "hello"}]}, c)
    g.invoke({"messages": [{"role": "user", "content": "again"}]}, c)
    hist = list(g.get_state_history(c))
    assert len(hist) >= 2, "not enough checkpoints to time-travel"
    oldest = hist[-1]
    cid = oldest.config["configurable"]["checkpoint_id"]
    g.invoke(None, {"configurable": {"thread_id": "m7", "checkpoint_id": cid}})
    return f"{len(hist)} checkpoints enumerated; replayed from {cid[:8]}..."


def alt():
    if MODE == "mock":
        raise RuntimeError(
            "create_agent needs a live model; set ANTHROPIC_API_KEY/OPENAI_API_KEY "
            "or POCKET_USE_OLLAMA=1")
    from langchain.agents import create_agent
    _, model = make_chat_model()
    cp = SqliteSaver(sqlite3.connect(fresh("alt.db"), check_same_thread=False))
    agent = create_agent(model, tools=TOOLS, checkpointer=cp)
    r = agent.invoke({"messages": [{"role": "user", "content": "what is 6 * 7?"}]},
                     {"configurable": {"thread_id": "alt"}})
    assert "42" in str(r["messages"][-1].content)
    return "create_agent reached behavioral parity (6*7=42)"


def server_cfg():
    """§8 - the graph is exposed for `langgraph dev` / Studio / the SDK.

    Deterministic, no server boot: assert langgraph.json parses, each declared
    graph imports to a *compiled* graph (NOT the (graph, mode) tuple), and the
    SDK client entrypoint imports. Booting `langgraph dev` + a live SDK run is a
    manual step (see README)."""
    import json as _json
    import importlib
    cfgp = pathlib.Path("langgraph.json")
    if not cfgp.exists():
        raise RuntimeError("langgraph.json not found")
    cfg = _json.loads(cfgp.read_text(encoding="utf-8"))
    graphs = cfg.get("graphs", {})
    assert graphs, "no graphs declared in langgraph.json"
    loaded = []
    for name, spec in graphs.items():
        path_part, _, attr = spec.partition(":")
        assert attr, f"graph '{name}' spec missing ':attr'"
        modname = ("pocket_agent." + pathlib.Path(path_part).stem
                   if path_part.endswith(".py") else path_part)
        factory = getattr(importlib.import_module(modname), attr)
        g = factory() if callable(factory) else factory
        assert not isinstance(g, tuple), (
            f"graph '{name}' resolved to a tuple; the server needs a compiled "
            "graph (unwrap build_graph()[0])")
        assert hasattr(g, "invoke") and hasattr(g, "stream"), \
            f"graph '{name}' is not a compiled graph"
        loaded.append(name)
    from langgraph_sdk import get_sync_client  # noqa: F401  (call the live server)
    return f"langgraph.json OK; compiled graphs: {', '.join(loaded)}; SDK client importable"


def m9_middleware():
    """§7+ (Phase 3) - middleware showcase + custom middleware + structured output.

    Deterministic (mock-safe): the custom NoteGuardMiddleware hooks behave
    correctly, and create_agent compiles with the full middleware stack +
    response_format (verified with a keyless fake chat model). With a live model
    configured, additionally run the agent and assert a structured_response."""
    import itertools
    from langchain_core.messages import AIMessage, SystemMessage, HumanMessage, ToolMessage
    from langchain_core.language_models.fake_chat_models import GenericFakeChatModel
    from langgraph.checkpoint.memory import InMemorySaver
    from langchain.agents.middleware import ToolCallRequest
    from alt_create_agent.middleware_showcase import (
        NoteGuardMiddleware, build_showcase_agent, build_live_showcase_agent)

    # (1) custom before_model: inject a guardrail note once, then idempotent
    mw = NoteGuardMiddleware()
    out = mw.before_model({"messages": [HumanMessage(content="hi")]})
    assert out and any(isinstance(m, SystemMessage) for m in out["messages"]), \
        "before_model should inject a system note"
    assert mw.before_model({"messages": out["messages"]}) is None, \
        "before_model must be idempotent"

    # (2) custom wrap_tool_call: block an empty save_note WITHOUT running it
    ran = {"called": False}
    def _handler(req):
        ran["called"] = True
        return ToolMessage(content="saved", tool_call_id="x")
    empty = ToolCallRequest(
        tool_call={"name": "save_note", "args": {"text": "  "}, "id": "x", "type": "tool_call"},
        tool=None, state={"messages": []}, runtime=None)
    blocked = mw.wrap_tool_call(empty, _handler)
    assert getattr(blocked, "status", None) == "error" and not ran["called"], \
        "empty save_note must be blocked and the tool not run"
    ok = ToolCallRequest(
        tool_call={"name": "save_note", "args": {"text": "real"}, "id": "y", "type": "tool_call"},
        tool=None, state={"messages": []}, runtime=None)
    delivered = mw.wrap_tool_call(ok, _handler)
    assert ran["called"] and getattr(delivered, "content", None) == "saved", \
        "a valid save_note must be delegated to the tool"

    # (3) the whole stack + structured output COMPILES keyless (fake model)
    fake = GenericFakeChatModel(messages=itertools.cycle([AIMessage(content="ok")]))
    agent = build_showcase_agent(fake, checkpointer=InMemorySaver())
    assert hasattr(agent, "invoke") and hasattr(agent, "stream"), \
        "showcase agent did not compile"

    # (4) live behaviour only when a real model is configured
    if MODE == "mock":
        return ("custom hooks OK; create_agent compiled with 6 middleware + "
                "structured output (live run skipped: mock mode)")
    agent_live, lmode = build_live_showcase_agent(db_path=fresh("showcase.db"))
    cfg = {"configurable": {"thread_id": "m9"}}
    r = agent_live.invoke(
        {"messages": [{"role": "user", "content": "What is 6 * 7? Answer concisely."}]}, cfg)
    assert "structured_response" in r, "expected a structured_response (response_format)"
    return f"custom hooks OK; compiled; live structured_response present (mode={lmode})"


def m10_semantic():
    """§ stretch (Phase 2) - long-term Store *semantic* search.

    Mock-safe: build an InMemoryStore with a vector index (keyless deterministic
    embedder in mock mode), put docs, and assert the query ranks the relevant
    docs above the unrelated one, with scores. Uses the configured provider's
    embeddings when `POCKET_EMBED_MODEL` is set."""
    from pocket_agent.semantic import make_embeddings, make_semantic_store
    mode, emb, dims = make_embeddings()
    store = make_semantic_store(emb, dims)
    for k, t in [("d1", "python programming language tutorial"),
                 ("d2", "italian pasta and pizza recipes"),
                 ("d3", "guide to the rust programming language")]:
        store.put(("docs",), k, {"text": t})
    res = store.search(("docs",), query="programming language", limit=3)
    assert res, "semantic search returned no results"
    assert all(getattr(r, "score", None) is not None for r in res), "results should be scored"
    top = res[0].key
    assert top in {"d1", "d3"}, f"expected a programming doc ranked first, got {top}"
    return f"semantic store ({mode} embeddings, dims={dims}): query ranked '{top}' first of {len(res)}"


def m11_delta():
    """§ stretch (Phase 2) - DeltaChannel (beta): diff-based checkpoint storage.

    Deterministic & mock-safe: (1) a DeltaChannel and an equivalent
    BinaryOperatorAggregate reconstruct the SAME accumulated value, but the
    DeltaChannel's checkpoint blob is a sentinel (constant size) while the binop
    stores the full growing list; (2) a graph using a DeltaChannel field
    accumulates correctly across steps under a checkpointer."""
    from pocket_agent.delta_demo import compare_channels, build_delta_demo_graph
    from langgraph.checkpoint.memory import InMemorySaver
    same, sentinel, full_len, n = compare_channels(8)
    assert same, "DeltaChannel must reconstruct the same value as full-snapshot"
    assert sentinel, "DeltaChannel checkpoint blob should be a sentinel, not the full list"
    g = build_delta_demo_graph(steps=5, checkpointer=InMemorySaver())
    out = g.invoke({"log": [], "n": 0}, {"configurable": {"thread_id": "m11"}})
    assert out["log"] == [f"step{i}" for i in range(5)], f"unexpected delta graph log: {out['log']}"
    return (f"DeltaChannel reconstructs == full snapshot over {n} writes; checkpoint "
            f"stores a sentinel (vs full list len {full_len}); graph accumulated 5 steps")


# ============================ run ===========================================
print(f"\n=== verifying milestones (model mode: {MODE}) ===")
record("M0 empty graph", m0, required=True)
record("M1 model + chat memory", m1, required=True)
record("M2 durable multi-turn memory", m2, required=True)
record("M3 tools + the cycle", m3, required=True)
record("M4 streaming (v3 + fallback)", m4, required=False)
record("M5 human-approval gate (HITL)", m5, required=True)
record("M6 long-term Store", m6, required=False)
record("M7 time travel", m7, required=False)
try:
    import langgraph_sdk  # noqa: F401
    _HAVE_SDK = True
except Exception:
    _HAVE_SDK = False
if _HAVE_SDK and pathlib.Path("langgraph.json").exists():
    record("M8 server graph (langgraph dev / Studio / SDK)", server_cfg, required=False)
else:
    skip("M8 server graph (langgraph dev / Studio / SDK)",
         "needs langgraph.json + langgraph-sdk (pip install 'langgraph-cli[inmem]')")
record("M9 middleware showcase + structured output", m9_middleware, required=False)
record("M10 Store semantic search", m10_semantic, required=False)
record("M11 DeltaChannel (beta) diff-based checkpoints", m11_delta, required=False)
if MODE == "mock":
    skip("ALT create_agent track", "no live model in mock mode")
else:
    record("ALT create_agent track", alt, required=False)


# ============================ report ========================================
def ver(p):
    try:
        return md.version(p)
    except Exception:
        return "-"


pkgs = ["langgraph", "langchain", "langchain-core", "langgraph-checkpoint",
        "langgraph-checkpoint-sqlite", "langgraph-sdk", "langgraph-cli",
        "langgraph-prebuilt",
        "langchain-anthropic", "langchain-openai", "langchain-ollama"]

n_pass = sum(1 for r in results if r[1] == "PASS")
n_fail = sum(1 for r in results if r[1] == "FAIL")
n_skip = sum(1 for r in results if r[1] == "SKIP")
req_fail = sum(1 for r in results if r[1] == "FAIL" and r[3])

lines = []
lines.append("# Pocket Agent — overnight build report\n")
lines.append(f"- Python: `{sys.version.split()[0]}`")
lines.append(f"- Model mode: **{MODE}**"
             + ("  _(mock: structural verification only — set a provider key for"
                " real answers)_" if MODE == "mock" else ""))
lines.append(f"- Result: **{n_pass} passed, {n_fail} failed, {n_skip} skipped**"
             f"  (required failures: {req_fail})\n")
lines.append("## Milestones\n")
lines.append("| Milestone | Status | Detail | Req | Secs |")
lines.append("|---|---|---|---|---|")
for mid, status, detail, req, secs in results:
    badge = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "SKIP"}[status]
    lines.append(f"| {mid} | {badge} | {str(detail).replace('|', '/')} | "
                 f"{'yes' if req else ''} | {secs} |")
lines.append("\n## Installed versions\n")
lines.append("| Package | Version |")
lines.append("|---|---|")
for p in pkgs:
    lines.append(f"| {p} | {ver(p)} |")
lines.append("\n## Next steps (need a human / a model)\n")
lines.append("- Provide a tool-calling model for *real* answers: set "
             "`ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (or `POCKET_USE_OLLAMA=1` "
             "with `ollama serve` + a tool-capable model) and re-run.")
lines.append("- Try it interactively: `python -m pocket_agent.cli`")
lines.append("- Optional Studio/server track: install `langgraph-cli[inmem]`, "
             "add a `langgraph.json`, run `langgraph dev`.")
pathlib.Path("BUILD_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"\n=== {n_pass} passed / {n_fail} failed / {n_skip} skipped "
      f"(required failures: {req_fail}) ===")
print("report: BUILD_REPORT.md")
sys.exit(min(req_fail, 120))
PY

  # ---- requirements.txt + pyproject.toml + README + .env.example
  cat > requirements.txt <<'TXT'
langgraph>=1.2
langchain>=1.0
langgraph-checkpoint-sqlite
pytest
TXT

  cat > pyproject.toml <<'TOML'
[project]
name = "pocket-agent"
version = "0.1.0"
description = "Foundations-first LangGraph build (generated by build_pocket_agent.sh)"
requires-python = ">=3.10"
dependencies = [
  "langgraph>=1.2",
  "langchain>=1.0",
  "langgraph-checkpoint-sqlite",
]

[project.optional-dependencies]
dev = ["pytest"]
anthropic = ["langchain-anthropic"]
openai = ["langchain-openai"]
ollama = ["langchain-ollama"]
server = ["langgraph-cli[inmem]"]

[tool.setuptools.packages.find]
include = ["pocket_agent*", "alt_create_agent*"]
TOML

  cat > .env.example <<'ENV'
# Provide ONE of these for real (tool-calling) answers; otherwise mock mode runs.
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# POCKET_USE_OLLAMA=1          # plus: ollama serve, and a tool-capable model
# POCKET_MODEL=gpt-4o-mini     # optional model override
# LANGSMITH_API_KEY=lsv2_...   # optional, only for the langgraph dev / Studio track
ENV

  cat > README.md <<'MD'
# Pocket Agent (generated)

A foundations-first LangGraph agent built incrementally (M0-M11) plus a
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

## Server / Studio (section 8)
`langgraph.json` exposes two graphs: `pocket_agent` (plain) and
`pocket_agent_hitl` (human-approval gate on `save_note`). The dev server
supplies its own persistence, so the graphs are compiled without a checkpointer
(HITL `interrupt()` still works — the server provides the checkpointer at run time).
```bash
pip install "langgraph-cli[inmem]"   # already installed by the builder
langgraph dev                        # serves http://127.0.0.1:2024 + opens Studio
```
Drive the running server from Python via the SDK:
```python
from langgraph_sdk import get_sync_client
client = get_sync_client(url="http://127.0.0.1:2024")
thread = client.threads.create()
for chunk in client.runs.stream(
        thread["thread_id"], "pocket_agent",
        input={"messages": [{"role": "user", "content": "what is 21 * 2?"}]},
        stream_mode="values"):
    print(chunk.data)
```

## Middleware & structured output (create_agent track, §7+)
`alt_create_agent/middleware_showcase.py` builds the same agent on the
high-level `create_agent` with a provider-agnostic middleware stack (PII
redaction, tool/model call limits, summarization, human-approval gate) plus a
custom `NoteGuardMiddleware` (`before_model` + `wrap_tool_call` guardrail) and a
Pydantic `response_format`. The custom-hook logic and keyless compilation are
verified in mock mode (**M9**); the structured answer + live middleware
behaviour run when a model is configured.

> M4 deliberately uses the v3 event-streaming API as the primary driver, with
> the stable `stream_mode` / `invoke` path as an automatic fallback.

## Stretch features (Phase 2)
- **Semantic search (M10)** — `pocket_agent/semantic.py`: an `InMemoryStore` with
  a vector `index={dims, embed, fields}`, so `store.search(ns, query=...)` returns
  scored matches. Keyless by default (a deterministic hashing embedder); set
  `POCKET_EMBED_MODEL` (+ provider env, optional `POCKET_EMBED_DIMS`) for real
  embeddings (LM Studio / Ollama / OpenAI). `pip install numpy` for faster vectors.
- **DeltaChannel (M11, beta)** — `pocket_agent/delta_demo.py`: attach
  `Annotated[list, DeltaChannel(reducer)]` to a state key; the channel stores only
  a sentinel per checkpoint and replays writes, so blob size stays ~constant as the
  value grows (vs the full snapshot a normal reducer channel stores each step).
MD

  say "generated: pocket_agent/{__init__,state,tools,model,graph,stream,cli}.py"
  say "generated: alt_create_agent/agent.py, tests/, verify_milestones.py, pyproject.toml, README.md"
}

# ============================================================================= CHECK mode (fast)
syntax_check() {
  phase "Syntax-check generated Python (py_compile, no install)"
  cd "$BUILD_DIR" || die "cannot cd into build dir"
  if "$SYS_PY" -m py_compile \
        pocket_agent/*.py alt_create_agent/*.py tests/*.py verify_milestones.py; then
    say "py_compile OK — all generated modules parse."
    return 0
  else
    warn "py_compile reported a syntax error (see above)."
    return 1
  fi
}

# ============================================================================= FULL build
venv_and_install() {
  phase "Create virtualenv + install dependencies"
  cd "$BUILD_DIR" || die "cannot cd into build dir"
  if [ ! -d .venv ]; then
    "$SYS_PY" -m venv .venv || die "venv creation failed"
    say "created .venv"
  else
    say ".venv already exists (reusing)"
  fi
  if   [ -x .venv/Scripts/python.exe ]; then PY="$BUILD_DIR/.venv/Scripts/python.exe"
  elif [ -x .venv/bin/python ];        then PY="$BUILD_DIR/.venv/bin/python"
  else die "cannot locate venv python"; fi
  say "venv python: $PY"

  "$PY" -m pip install --disable-pip-version-check --no-input -q -U pip >>"$LOG" 2>&1 \
    && say "pip upgraded" || warn "pip self-upgrade failed (continuing)"

  install_grp() {  # name + packages; logs, never aborts the night
    local label="$1"; shift
    say "installing [$label]: $*"
    if "$PY" -m pip install --disable-pip-version-check --no-input --timeout 120 -U "$@" >>"$LOG" 2>&1; then
      say "  ok [$label]"
    else
      warn "  install failed [$label] (see log) — continuing"
    fi
  }

  install_grp core langgraph langchain langgraph-checkpoint-sqlite
  install_grp dev pytest

  # provider libs: install whichever matches detected credentials
  if [ "${POCKET_FORCE_MOCK:-}" = "1" ]; then
    say "POCKET_FORCE_MOCK=1 — skipping provider libs (mock mode)"
  else
    [ -n "${ANTHROPIC_API_KEY:-}" ] && install_grp anthropic langchain-anthropic
    [ -n "${OPENAI_API_KEY:-}" ]    && install_grp openai    langchain-openai
    [ "${POCKET_USE_OLLAMA:-}" = "1" ] && install_grp ollama langchain-ollama
    [ "${POCKET_USE_LMSTUDIO:-}" = "1" ] && install_grp lmstudio langchain-openai
  fi
  # §8 server/Studio track: langgraph-cli[inmem] also pulls langgraph-sdk +
  # langgraph-api, which the M8 server-graph check needs (else it SKIPs).
  if [ "${POCKET_SKIP_CLI:-}" = "1" ]; then
    say "POCKET_SKIP_CLI=1 — skipping langgraph-cli[inmem] (M8 will SKIP)"
  else
    install_grp cli "langgraph-cli[inmem]"
  fi
  return 0
}

run_tests() {
  phase "Unit tests (pytest)"
  cd "$BUILD_DIR" || return 1
  if "$PY" -m pytest -q >>"$LOG" 2>&1; then
    say "pytest: PASS"
  else
    warn "pytest: some tests failed (see log) — continuing to milestone verify"
  fi
}

run_milestones() {
  phase "Verify milestones M0-M11 + alt track"
  cd "$BUILD_DIR" || return 1
  set +o pipefail
  $TIMEOUT "$PY" verify_milestones.py 2>&1 | tee -a "$LOG"
  local rc="${PIPESTATUS[0]}"
  set -o pipefail
  MILESTONE_RC="$rc"
  say "milestone harness exit code: $rc (0 = all required milestones passed)"
}

# ============================================================================= main
generate_sources

if [ "$MODE_CHECK" = 1 ]; then
  if syntax_check; then
    phase "CHECK complete — sources generate & compile. Run without --check to build for real."
    exit 0
  else
    die "CHECK found a syntax error."
  fi
fi

PY=""               # set by venv_and_install
MILESTONE_RC=99
venv_and_install
run_tests
run_milestones

phase "DONE"
say "build dir : $BUILD_DIR"
say "report    : $BUILD_DIR/BUILD_REPORT.md"
say "full log  : $LOG"
if [ "${MILESTONE_RC:-99}" = "0" ]; then
  say "RESULT: all required milestones passed."
else
  say "RESULT: $MILESTONE_RC required milestone(s) failed — see BUILD_REPORT.md."
fi
say "Tip: point at LM Studio (POCKET_USE_LMSTUDIO=1) or set ANTHROPIC_API_KEY/OPENAI_API_KEY/POCKET_USE_OLLAMA=1 for real answers + the create_agent track."
exit "${MILESTONE_RC:-0}"
