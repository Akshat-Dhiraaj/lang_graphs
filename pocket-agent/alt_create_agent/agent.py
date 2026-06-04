"""Section 7 - the same agent via the high-level create_agent factory.
Requires a live model (create_agent reasons with a real LLM)."""
import sqlite3
from langgraph.checkpoint.sqlite import SqliteSaver

from pocket_agent.model import make_chat_model
from pocket_agent.tools import ALL_TOOLS


def build_alt_agent(db_path="alt.db"):
    mode, model = make_chat_model()
    if model is None:
        raise RuntimeError("create_agent needs a live model (set a provider key)")
    from langchain.agents import create_agent
    cp = SqliteSaver(sqlite3.connect(db_path, check_same_thread=False))
    agent = create_agent(model, tools=ALL_TOOLS, checkpointer=cp)
    return agent, mode
