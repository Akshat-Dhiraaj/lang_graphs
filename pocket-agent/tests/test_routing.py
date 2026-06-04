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
