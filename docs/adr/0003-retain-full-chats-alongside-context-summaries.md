# Retain full chats alongside context summaries

Sekret retains the complete local chat while separately maintaining an on-device context summary for fitting long conversations into the model's limited context. Summarization never replaces displayed history, retention reaps complete chats rather than old turns, and the UI discloses when earlier context has been summarized; this preserves user-visible history without pretending the model can reread it all on every turn.
