"""M1 - State. Subclass MessagesState so the `messages` channel uses the
`add_messages` reducer (append + dedupe-by-id)."""
from langgraph.graph import MessagesState


class State(MessagesState):
    """Chat state. Inherits: messages: Annotated[list, add_messages]."""
    pass
