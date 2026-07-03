from pocket_agent.delta_demo import compare_channels, build_delta_demo_graph
from langgraph.checkpoint.memory import InMemorySaver


def test_delta_reconstructs_like_full_snapshot_but_stores_sentinel():
    same, sentinel, full_len, n = compare_channels(8)
    assert same and sentinel and full_len == 8 and n == 8


def test_delta_graph_accumulates_across_steps():
    g = build_delta_demo_graph(steps=5, checkpointer=InMemorySaver())
    out = g.invoke({"log": [], "n": 0}, {"configurable": {"thread_id": "t"}})
    assert out["log"] == [f"step{i}" for i in range(5)]
