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
