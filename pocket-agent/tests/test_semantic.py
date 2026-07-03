from pocket_agent.semantic import MockHashingEmbeddings, make_semantic_store


def test_mock_embeddings_dims_and_norm():
    emb = MockHashingEmbeddings(64)
    v = emb.embed_query("hello world")
    assert len(v) == 64
    assert abs(sum(x * x for x in v) - 1.0) < 1e-6  # L2-normalized


def test_semantic_search_ranks_relevant_first():
    store = make_semantic_store(MockHashingEmbeddings(64), 64)
    store.put(("docs",), "d1", {"text": "python programming language tutorial"})
    store.put(("docs",), "d2", {"text": "italian pasta and pizza recipes"})
    store.put(("docs",), "d3", {"text": "guide to the rust programming language"})
    res = store.search(("docs",), query="programming language", limit=3)
    assert res and res[0].key in {"d1", "d3"}
    assert all(getattr(r, "score", None) is not None for r in res)
