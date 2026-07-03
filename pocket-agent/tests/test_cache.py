from pocket_agent.cache_demo import cache_roundtrip


def test_cache_roundtrip_reuses_node_result():
    first, second, calls = cache_roundtrip(5)
    assert first == [{"expensive": {"result": 10}}]
    assert second[-1]["__metadata__"]["cached"] is True
    assert calls == 1
