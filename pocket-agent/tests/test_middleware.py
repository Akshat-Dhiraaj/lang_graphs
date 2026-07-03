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
