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
