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
