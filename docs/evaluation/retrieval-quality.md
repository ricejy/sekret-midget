# Retrieval quality evaluation

This benchmark measures whether a known relevant passage survives in the first four passages admitted by the production retrieval and context-assembly path. The committed `synthetic-contract-and-policy-v1` corpus contains six clearly fictional documents and 30 labeled questions. It contains no real personal data and no generated model output.

Questions are evenly divided among five meaningful categories: amounts, deadlines, exact terms, obligations, and paraphrases. Each question records the authoritative document heading or headings that count as relevant.

## Portable regression test

Run the deterministic regression test from the repository root:

```sh
flutter test test/retrieval_quality_test.dart
```

The test imports every fixture through `DocumentLibrary.importPastedText`, retrieves through `DocumentLibrary.retrieveEvidence`, and asserts that every labeled passage survives in the production top four. The test embedder is deliberately synthetic so failures isolate chunking, indexing, ranking, or context-admission regressions from changes in an operating-system embedding model.

## Apple on-device baseline

Connect and unlock an iPhone, enable Developer Mode, and run:

```sh
flutter devices
flutter run -d <iphone-device-id> --debug \
  --dart-define=RETRIEVAL_QUALITY_EVALUATION=true
```

The evaluation build uses Apple's production Natural Language embedder on iOS and an in-memory database. It does not invoke answer generation. One run imports the same fictional fixtures and uses the same question strings for both hybrid and dense-only retrieval. When complete, the app displays the two recall@4 totals and writes a compact metrics record beginning with:

```text
RETRIEVAL_QUALITY_SUMMARY_JSON=
```

It also writes the complete report in ordered, iOS-console-safe records beginning with `RETRIEVAL_QUALITY_JSON_PART=<part>/<total>:`. Concatenate the payload after each colon in part order to reconstruct the JSON. The report records the UTC run date, embedding implementation/language/dimension/revision, token counter, chunking configuration, ranking configuration, overall recall@4, category recall@4, per-question hits, and a decision against the 0.80 hybrid recall@4 target.

No private documents are required or permitted for this benchmark. The corpus is committed in `lib/evaluation/synthetic_retrieval_corpus.dart`.

## When to rerun

Run the portable regression test for every relevant code change. Repeat the physical-iPhone baseline after any change to:

- chunk boundaries or overlap;
- embedding implementation or inputs;
- lexical, dense, or fusion ranking;
- candidate limits, top-four admission, or context budgeting;
- the benchmark corpus or relevance labels.

Commit each accepted physical-device result as a dated baseline. The first result is recorded in [the 2026-08-25 baseline](retrieval-baseline-2026-08-25.md).
