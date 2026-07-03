import os

import pytest

from pocket_agent.persistence import (
    open_postgres_graph,
    open_postgres_persistence,
    postgres_available,
)


def test_postgres_helpers_are_lazy():
    assert isinstance(postgres_available(), bool)


def test_postgres_requires_connection_string():
    with pytest.raises(ValueError):
        with open_postgres_persistence(""):
            pass


@pytest.mark.skipif(
    not postgres_available() or not os.getenv("POCKET_POSTGRES_URI"),
    reason="set POCKET_POSTGRES_URI for live Postgres check",
)
def test_postgres_builder_with_configured_database():
    with open_postgres_graph(os.environ["POCKET_POSTGRES_URI"]) as (graph, _mode):
        assert hasattr(graph, "invoke")
