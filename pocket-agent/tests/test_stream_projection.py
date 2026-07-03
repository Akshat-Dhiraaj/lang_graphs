from pocket_agent.stream_projection import collect_progress_events


def test_progress_transformer_projects_custom_events():
    assert collect_progress_events("ok") == [{"stage": "node", "text": "ok"}]
