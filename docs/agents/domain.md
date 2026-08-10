# Domain docs

This is a single-context repository.

## Before exploring

Read these when they exist:

- `CONTEXT.md` at the repository root
- Relevant ADRs under `docs/adr/`

If they do not exist, proceed silently. Domain-modeling workflows create them
when terminology or architectural decisions are actually resolved.

## Layout

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
└── lib/
```

## Vocabulary

Use terminology defined in `CONTEXT.md`. Avoid synonyms that its glossary
explicitly rejects.

If a required concept is absent, reconsider whether new language is necessary
or record the gap for domain modeling.

## ADR conflicts

Explicitly identify proposals that contradict an existing ADR rather than
silently overriding the decision.
