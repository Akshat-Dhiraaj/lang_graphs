"""Phase 5 - optional Postgres persistence helpers.

The core project stays keyless and SQLite-first. These helpers only import the
Postgres packages when requested, so normal mock-mode tests do not need a
running database or the optional dependencies.
"""
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from typing import Iterator


@dataclass(frozen=True)
class PostgresPersistence:
    """Opened Postgres-backed persistence handles."""

    checkpointer: object
    store: object


def postgres_available() -> bool:
    """Return whether the optional LangGraph Postgres packages import."""
    try:
        from langgraph.checkpoint.postgres import PostgresSaver  # noqa: F401
        from langgraph.store.postgres import PostgresStore  # noqa: F401
    except Exception:
        return False
    return True


@contextmanager
def open_postgres_persistence(
    conn_string: str,
    *,
    setup: bool = False,
) -> Iterator[PostgresPersistence]:
    """Open Postgres checkpointer + store handles for graph compilation.

    ``setup=True`` creates or migrates LangGraph tables. Keep it explicit so a
    demo run never mutates a database schema by accident.
    """
    if not conn_string:
        raise ValueError("conn_string is required")
    from langgraph.checkpoint.postgres import PostgresSaver
    from langgraph.store.postgres import PostgresStore

    with ExitStack() as stack:
        store = stack.enter_context(PostgresStore.from_conn_string(conn_string))
        checkpointer = stack.enter_context(
            PostgresSaver.from_conn_string(conn_string)
        )
        if setup:
            store.setup()
            checkpointer.setup()
        yield PostgresPersistence(checkpointer=checkpointer, store=store)


def build_postgres_graph(conn_string: str, *, setup: bool = False, hitl: bool = False):
    """Compile the canonical graph against Postgres saver/store handles."""
    from .graph import build_graph

    with open_postgres_persistence(conn_string, setup=setup) as persistence:
        graph, mode = build_graph(
            checkpointer=persistence.checkpointer,
            store=persistence.store,
            hitl=hitl,
        )
        return graph, mode
