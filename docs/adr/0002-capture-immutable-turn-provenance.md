# Capture immutable provenance for every turn

Each turn permanently records whether it used General or Knowledge Base mode and the source scope, retrieved evidence, citations, and relevant model metadata captured when it began. Later source-selection changes affect only future turns, regeneration uses the original scope, and Knowledge Base mode never falls back to general knowledge; this makes answers explainable and prevents mutable chat state from rewriting their evidentiary meaning.
