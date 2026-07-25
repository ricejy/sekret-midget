# Screenshot RAG — Idea One-Pager

**Date:** 2026-07-26
**Status:** Direction agreed. Supersedes the personal-admin-documents framing.

## Problem Statement

**How might we make the thousands of screenshots you will never scroll through actually answerable — entirely on-device, with a model that can only see four of them at a time?**

## Recommended Direction

A minimal iOS app over the user's real screenshot library, whose actual deliverable is a **measured comparison of on-device retrieval strategies**: `NLEmbedding` vs MiniLM, dense-only vs metadata fusion, with and without LLM reranking and index-time enrichment — reported as recall@4 and latency on an iPhone 15 Pro Max.

The app is one screen: ask a question, see the answer, see the four screenshots it used and their scores. The README leads with a results table.

This direction was chosen over "chat with your personal admin documents" for one decisive reason: a personal admin-doc corpus is 15–30 files and a few hundred chunks. **Retrieval over a few hundred chunks is not a hard problem** — recall would sit near 1.0 immediately and the eval would measure nothing. A screenshot library is thousands of short, noisy, OCR-mangled documents where retrieval genuinely fails, which is the only condition under which the interesting work exists.

It also has a real daily-use story. The user actually has this corpus, actually cannot search it today, and would actually use the result.

## Key Assumptions to Validate

- [ ] **Apple Photos cannot already answer these questions.** iOS OCRs screenshots and exposes that text to Photos search. *Test: write 10 questions you'd genuinely ask, type each into Photos search, count how many it answers. Zero code, fifteen minutes. If it's 8/10, abandon. If it's 2/10, those 10 questions are the seed of the eval set.* **Do this before anything else.**
- [ ] **`NLEmbedding` produces usable vectors on short, noisy OCR text.** Apple documents neither its dimensionality nor its language coverage. *Test: runtime-probe `dimension`, then measure recall@4 against MiniLM on the same labeled set.* Determines whether the app ships with zero bundled model weights.
- [ ] **Apple Vision OCR is good enough on screenshots to retrieve against.** *Test: OCR 50 real screenshots, read the raw output, judge whether a human could answer questions from it.*
- [ ] **LLM reranking beats raw vector ranking by enough to justify its latency.** *This is the headline experiment.*
- [ ] **Guardrails don't refuse on real screenshot content.** A personal library contains medical, financial, and private-message material; Apple's guardrails cannot be disabled and are documented as over-blocking benign content. *Test: run 20 realistic queries against real screenshots and count refusals.*

## MVP Scope

**In:** Photos library access limited to the Screenshots album · Apple Vision OCR as a resumable batch job · one embedding vector per screenshot · brute-force cosine retrieval · a swappable `RetrievalStrategy` interface · an eval harness with a labeled question set · `FoundationModels` generation over the top 4 results · one debug-grade screen showing answer, sources, and scores.

**Out:** everything else.

## Not Doing (and Why)

- **No vector database.** 5,000 screenshots × 384 dims × 4 bytes = 7.7 MB; brute-force cosine scans it in ~4 ms. At 20,000 it's 30 MB and ~15 ms. ObjectBox, HNSW, and sqlite-vec are all solving a problem this project does not have.
- **No chunking logic.** One screenshot is one retrieval unit. This removes an entire dimension of tuning and sharpens the eval onto the axis that matters: short noisy documents.
- **No PDF or document import.** A different ingestion problem that would consume the month without touching retrieval.
- **No encryption layer in v1.** The source data already lives in Photos under iOS Data Protection. Re-encrypting a derived index buys little and costs days. Revisit if the project outlives the portfolio purpose.
- **No Android.** No OS-provided LLM, no OS-provided embeddings, and a ~550 MB–1 GB bundled model. It is a second architecture, not a port.
- **No UI polish.** Explicitly deferred by the author. The screen exists to make retrieval legible, not to look good.
- **No cloud anything.** Including Apple's own Private Cloud Compute. Airplane mode must work permanently.

## Open Questions

- **Two corpora, or one?** A publishable benchmark needs reproducible ground truth, but a personal screenshot library and its labels cannot be shipped. Likely answer: personal corpus for real numbers and daily use, plus a small public/synthetic set with published labels so the comparison is reproducible. Decide before the eval harness is written — it shapes the interface.
- Does the iOS Simulator serve `SystemLanguageModel`? Undocumented; affects iteration speed given the Windows/Mac split.
- Is index-time LLM enrichment (one generated caption per screenshot, embedded instead of raw OCR) affordable? Potentially transformative for retrieval, but it is one LLM call per screenshot — hours of batch processing.
- Project name. `sekret-midget` is a directory, not a name.
