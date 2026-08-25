# Retrieval baseline — 2026-08-25

The first physical-device baseline passes the recall@4 target and supports retaining Apple's embedding implementation.

## Run

- UTC time: `2026-08-25T15:58:55.587495Z`
- Device: physical iPhone, iOS 26.6
- Corpus: `synthetic-contract-and-policy-v1`
- Fixtures: 6 entirely fictional documents, 30 labeled questions, no real personal data
- Embedding: Apple Natural Language, English, 512 dimensions, revision 1
- Token counter: deterministic whitespace counter
- Compared in one run: hybrid and dense-only retrieval over identical fixtures and question strings

## Production configuration

- Chunk target: 250 tokens
- Chunk overlap: 38 tokens
- Boundaries: sections, paragraphs, and whole sentences
- Embedding input: heading prepended to chunk text
- Candidate limit: 20
- Hybrid ranking: SQLite FTS5/BM25 plus dense cosine with reciprocal-rank fusion
- Reciprocal-rank constant: 60
- Dense-only ranking: dense cosine
- Context admission: top 4 whole passages
- Context budget: 4,096 tokens with 512 reserved for the answer

## Recall@4

| Category | Questions | Hybrid | Dense-only |
| --- | ---: | ---: | ---: |
| Amount | 6 | 6/6 (100%) | 5/6 (83.3%) |
| Deadline | 6 | 6/6 (100%) | 6/6 (100%) |
| Exact term | 6 | 6/6 (100%) | 6/6 (100%) |
| Obligation | 6 | 6/6 (100%) | 6/6 (100%) |
| Paraphrase | 6 | 6/6 (100%) | 6/6 (100%) |
| **Overall** | **30** | **30/30 (100%)** | **29/30 (96.7%)** |

Dense-only missed `juniper-hotel`, whose relevant passage is `HOTEL LIMIT`. Hybrid retrieval admitted that passage in first position, demonstrating a useful lexical contribution rather than merely matching dense-only behavior.

## Decision

Retain Apple Natural Language embeddings. Hybrid recall@4 exceeds the gate, every labeled relevant passage survives the production top four, and no fallback embedder is warranted by this evidence.

The previously provisional 0.80 hybrid recall@4 threshold is confirmed as the initial regression gate. The 1.00 baseline leaves meaningful headroom while allowing for future corpus expansion. Revisit the threshold when the benchmark gains broader document structures or categories; do not weaken it solely to accommodate a regression.
