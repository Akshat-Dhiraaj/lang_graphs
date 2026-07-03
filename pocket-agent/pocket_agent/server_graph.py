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
