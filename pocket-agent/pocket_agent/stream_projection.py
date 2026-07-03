"""Phase 5 - custom v3 stream projection demo."""
from typing import TypedDict

from langgraph.config import get_stream_writer
from langgraph.graph import END, START, StateGraph
from langgraph.stream import ProtocolEvent, StreamChannel, StreamTransformer


class ProgressState(TypedDict):
    text: str


class ProgressTransformer(StreamTransformer):
    """Project custom node progress into a named stream channel."""

    required_stream_modes = ("custom",)

    def __init__(self, scope: tuple[str, ...] = ()) -> None:
        super().__init__(scope)
        self.progress = StreamChannel("progress")

    def init(self):
        return {"progress": self.progress}

    def process(self, event: ProtocolEvent) -> bool:
        if event["method"] == "custom":
            self.progress.push(event["params"]["data"])
        return True


def build_progress_graph():
    """Return a tiny graph that emits one custom progress event."""

    def node(state: ProgressState):
        get_stream_writer()({"stage": "node", "text": state["text"]})
        return {"text": state["text"].upper()}

    builder = StateGraph(ProgressState)
    builder.add_node("node", node)
    builder.add_edge(START, "node")
    builder.add_edge("node", END)
    return builder.compile()


def collect_progress_events(text: str = "ok"):
    """Run the graph and return named progress-channel payloads."""
    graph = build_progress_graph()
    stream = graph.stream_events(
        {"text": text},
        version="v3",
        transformers=[ProgressTransformer],
    )
    events = list(stream)
    return [
        event["params"]["data"]
        for event in events
        if event["method"] == "custom:progress"
    ]
