"""Phase 2 (stretch) - long-term Store *semantic* search.

Verified against langgraph 1.2.4 / langchain-core 1.4.x: `InMemoryStore` enables
vector search when constructed with an `index={"dims", "embed", "fields"}` config
(disabled by default); `store.search(ns, query=...)` then returns scored items.

Embeddings are keyless by default (a deterministic hashing vectorizer, so the
whole feature runs in mock mode with no model). Set `POCKET_EMBED_MODEL` (plus the
matching provider env) to use real embeddings (an LM Studio / Ollama / OpenAI
embedding model).
"""
import os
import math
import hashlib

from langchain_core.embeddings import Embeddings
from langgraph.store.memory import InMemoryStore


class MockHashingEmbeddings(Embeddings):
    """Deterministic, keyless, dependency-free embeddings.

    Hashes each lowercased alphanumeric token into a fixed-width vector and
    L2-normalizes, so cosine similarity reflects lexical overlap. Good enough to
    demonstrate semantic-style retrieval without downloading a model.
    """

    def __init__(self, dims: int = 64):
        self.dims = dims

    def _vec(self, text: str):
        v = [0.0] * self.dims
        cleaned = "".join(c.lower() if c.isalnum() else " " for c in (text or ""))
        for tok in cleaned.split():
            v[int(hashlib.md5(tok.encode()).hexdigest(), 16) % self.dims] += 1.0
        norm = math.sqrt(sum(x * x for x in v)) or 1.0
        return [x / norm for x in v]

    def embed_documents(self, texts):
        return [self._vec(t) for t in texts]

    def embed_query(self, text):
        return self._vec(text)


def make_embeddings():
    """Return ``(mode, embeddings, dims)``.

    Defaults to the keyless mock embedder (the chat provider is usually not an
    embedding model). Opt into real embeddings with ``POCKET_EMBED_MODEL`` + the
    matching provider env (``OPENAI_API_KEY``, ``POCKET_USE_LMSTUDIO=1``, or
    ``POCKET_USE_OLLAMA=1``); set ``POCKET_EMBED_DIMS`` to match the model.
    """
    model = os.getenv("POCKET_EMBED_MODEL")
    if os.getenv("POCKET_FORCE_MOCK") == "1" or not model:
        return "mock", MockHashingEmbeddings(64), 64
    dims_env = os.getenv("POCKET_EMBED_DIMS")
    try:
        if os.getenv("OPENAI_API_KEY"):
            from langchain_openai import OpenAIEmbeddings
            return "openai", OpenAIEmbeddings(model=model), int(dims_env or 1536)
        if os.getenv("POCKET_USE_LMSTUDIO") == "1":
            from langchain_openai import OpenAIEmbeddings
            base = os.getenv("POCKET_LMSTUDIO_BASE", "http://localhost:1234/v1")
            return "lmstudio", OpenAIEmbeddings(base_url=base, api_key="lm-studio",
                                                model=model), int(dims_env or 768)
        if os.getenv("POCKET_USE_OLLAMA") == "1":
            from langchain_ollama import OllamaEmbeddings
            return "ollama", OllamaEmbeddings(model=model), int(dims_env or 768)
    except Exception:
        pass
    return "mock", MockHashingEmbeddings(64), 64


def make_semantic_store(embeddings=None, dims=None):
    """An InMemoryStore with vector search enabled (semantic search is off by
    default until an index config is supplied)."""
    if embeddings is None:
        _mode, embeddings, dims = make_embeddings()
    if dims is None:
        dims = getattr(embeddings, "dims", 1536)
    return InMemoryStore(index={"dims": dims, "embed": embeddings, "fields": ["text"]})
