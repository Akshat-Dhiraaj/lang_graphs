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
