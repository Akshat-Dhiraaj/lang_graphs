"""Phase 5 - small node-caching demo."""
from typing import TypedDict

from langgraph.cache.memory import InMemoryCache
from langgraph.graph import END, START, StateGraph
from langgraph.types import CachePolicy


class CacheState(TypedDict):
    x: int
    result: int


def build_cached_graph(call_counter: dict[str, int] | None = None, *, ttl: int = 60):
    """Return a graph whose only node is cacheable."""
    counter = call_counter if call_counter is not None else {"n": 0}

    def expensive_node(state: CacheState):
        counter["n"] = counter.get("n", 0) + 1
        return {"result": state["x"] * 2}

    builder = StateGraph(CacheState)
    builder.add_node("expensive", expensive_node, cache_policy=CachePolicy(ttl=ttl))
    builder.add_edge(START, "expensive")
    builder.add_edge("expensive", END)
    return builder.compile(cache=InMemoryCache())


def cache_roundtrip(x: int = 5):
    """Invoke twice and return ``(first, second, calls)`` for tests/reports."""
    counter = {"n": 0}
    graph = build_cached_graph(counter)
    first = graph.invoke({"x": x}, stream_mode="updates")
    second = graph.invoke({"x": x}, stream_mode="updates")
    return first, second, counter["n"]
