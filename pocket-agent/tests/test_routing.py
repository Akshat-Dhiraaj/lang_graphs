from langchain_core.messages import AIMessage, ToolMessage
from langgraph.graph import END
from pocket_agent.graph import ensure_final_content, route_after_agent


def test_routes_to_tools_on_tool_call():
    s = {"messages": [AIMessage(content="", tool_calls=[{
        "name": "calculator", "args": {"expression": "1+1"},
        "id": "x", "type": "tool_call"}])]}
    assert route_after_agent(s) == "tools"


def test_routes_to_end_on_plain_answer():
    s = {"messages": [AIMessage(content="all done")]}
    assert route_after_agent(s) == END


def test_empty_final_answer_falls_back_to_tool_result():
    msg = ensure_final_content(
        AIMessage(content=""),
        [ToolMessage(content="1. Manual validation note", tool_call_id="read")],
    )
    assert msg.content == "1. Manual validation note"
