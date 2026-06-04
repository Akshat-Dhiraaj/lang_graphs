"""Interactive CLI. Run with: python -m pocket_agent.cli  (not used by the
overnight verifier, which drives the graph programmatically)."""
import sqlite3
import uuid
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import Command
from .graph import build_graph


def main():
    conn = sqlite3.connect("pocket.db", check_same_thread=False)
    graph, mode = build_graph(checkpointer=SqliteSaver(conn), hitl=True)
    tid = str(uuid.uuid4())
    cfg = {"configurable": {"thread_id": tid}}
    print(f"Pocket Agent [mode={mode}] thread={tid}. Ctrl-D to exit.")
    while True:
        try:
            user = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user:
            continue
        res = graph.invoke({"messages": [{"role": "user", "content": user}]}, cfg)
        if "__interrupt__" in res:
            ans = input(f"[approve? y/n] {res['__interrupt__']} > ")
            res = graph.invoke(
                Command(resume=ans.strip().lower().startswith("y")), cfg)
        print("bot>", res["messages"][-1].content)


if __name__ == "__main__":
    main()
