# Implementation Plan

**For:** `SPEC.md` v2 — On-Device Screenshot Retrieval (iOS)
**Date:** 2026-07-26
**Horizon:** ~4 weeks

---

## Component Map

| # | Component | Where it runs | Depends on |
|---|---|---|---|
| C1 | Core interfaces + fakes | Dart, Windows | — |
| C2 | Store (sqlite3: screenshots, OCR text, vectors, metadata) | Dart, Windows | C1 |
| C3 | Retrieval strategies (cosine, fusion, rerank) | Dart, Windows | C1, C2 |
| C4 | Context assembly under the 4K budget | Dart, Windows | C1 |
| C5 | Swift bridge — Vision OCR | Native, **Mac** | C1 |
| C6 | Swift bridge — `NLEmbedding` | Native, **Mac** | C1 |
| C7 | Swift bridge — `FoundationModels` generation | Native, **Mac** | C1 |
| C8 | Photos enumeration (`PHAsset`, screenshots only) | Native, **Mac** | C1 |
| C9 | Ingest pipeline (resumable batch) | Dart + native | C2, C5, C6, C8 |
| C10 | MiniLM embedder (`flutter_onnxruntime`) | Dart + native | C1 |
| C11 | Eval harness (`tool/eval.dart` → `docs/results.md`) | Dart, Windows | C1, C2, C3 |
| C12 | Labeled question set | **Human time** | OCR text existing (C9) |
| C13 | Minimal UI (one screen) | Dart | C3, C4, C7 |

---

## Dependency Graph

```
T0 Photos gate ──────────────────────────────► (everything)
                                                    │
                        ┌───────────────────────────┴──────────────────┐
                        ▼                                              ▼
              C1 interfaces + fakes                          [Mac track, parallel]
                        │                                    C5 OCR ─┐
        ┌───────┬───────┴───────┬─────────┐                  C6 NLEmb ┼─► C9 ingest
        ▼       ▼               ▼         ▼                  C8 Photos┘      │
       C2      C3              C4       C11                  C7 LLM ─────────┤
      store  retrieval      context     eval                                 ▼
        │       │               │         │                            C12 labeling
        └───────┴───────────────┴─────────┴──────────────────────────────────┤
                                                                             ▼
                                                              EXPERIMENTS ──► C13 UI
```

**The keystone is C1.** Defining `Embedder`, `LlmBackend`, `OcrEngine`, and `ScreenshotSource` with working fakes is what makes the Windows/Mac split viable — it unblocks C2, C3, C4, and C11 to be built and fully tested with no device at all. Build it first, build it carefully, and resist the urge to let a native detail leak through it.

---

## Ordering Rationale

**Week 0 — the gate.** No code. Two facts decide whether this project should exist: how many of your real questions Apple Photos already answers, and how many screenshots you actually have. If Photos scores well, build something else. If your library is under ~1,000 screenshots, retrieval is trivial again and we're back where the admin-docs framing died.

**Week 1 — foundations and the boring native work.** The Dart foundations (C1–C4) are low-risk and can be done anywhere. The bridge work (C5–C8) is the single largest schedule risk in the project: it is unglamorous, it needs the Mac, and it is not the part you find interesting. It goes early precisely because it is risky, not because it is important.

**Week 2 — first real number.** The eval harness plus the labeled set produce the first honest recall@4. Everything before this point is scaffolding; everything after it is informed by data. Getting a real number by end of week 2 is the most important scheduling goal in the plan.

**Week 3 — the experiments.** This is what the project is for. Protect this week.

**Week 4 — generation, minimal UI, write-up.** `docs/results.md` is the artifact; leave real time for it.

### What runs in parallel

- **Mac track and Windows track are genuinely independent** through week 1. Dart foundations against fakes need no device; the Swift bridge needs no Dart logic beyond the interface signatures.
- **Labeling (C12) is human time, not code time**, and it is on the critical path for every number in the project. Start it the moment OCR text exists — and you can start drafting questions before that, just by scrolling your own library. Do not leave it until you need it.
- **MiniLM (C10) is independent of the Apple bridge** and can be built while blocked on anything native.

---

## Risk Register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| **R1** | Apple Photos already answers the questions — no reason for the project | Medium | Fatal | Task 0, before any code. Cheapest possible test. |
| **R2** | Screenshot library is too small for retrieval to be hard | Medium | Fatal | Counted in Task 0. Under ~1,000 → change corpus, not strategy. |
| **R3** | Week 1 bridge/ingest work overruns into the experiment weeks | **High** | High | Hard cap: if ingest is unfinished at end of week 1, cut scope — English only, cap at 1,000 screenshots. Never compress weeks 2–3. |
| **R4** | `NLEmbedding` is unusable (returns nil, tiny dim, poor quality on OCR noise) | Medium | Medium | Probe `dimension` in T2.3, before building on it. MiniLM fallback is already specced and independent. |
| **R5** | Guardrails refuse on real personal content | Medium | Medium | Probe in week 2 with 20 realistic queries. **A measured refusal rate is itself a publishable finding** — this degrades the app, not the project. |
| **R6** | Simulator won't serve `SystemLanguageModel`; all LLM iteration needs the device | Medium | Low | Fakes cover all logic; only measurement needs hardware. Annoying, not blocking. |
| **R7** | Vision OCR on screenshots is too noisy to retrieve against | Low | High | Read 50 raw outputs by hand in T2.2, before building the pipeline on top of it. |
| **R8** | Labeling 50 questions is more tedious than expected and slips | Medium | High | Use the reverse technique: sample a screenshot, write the question it answers. Start in week 1. |

**The two risks worth actually worrying about are R3 and R8** — both are schedule risks on unglamorous work, and both eat the weeks you care about. Everything else is either cheap to test or degrades gracefully.

---

## Verification Checkpoints

| CP | When | Must be true | If not |
|---|---|---|---|
| **CP0** | End week 0 | Photos hit-rate recorded; screenshot count ≥ ~1,000 | Stop. Re-scope the corpus. |
| **CP1** | End week 1 | Ingest runs end-to-end on ≥500 real screenshots, resumable, throughput measured | Cut OCR scope. Do not push into week 2. |
| **CP2** | End week 2 | One real recall@4 number exists on the real corpus with ≥30 labeled questions | Drop an experiment axis; the baseline matters more than breadth. |
| **CP3** | End week 3 | `docs/results.md` populated across ≥4 strategy configs incl. LLM rerank | Ship with fewer configs; report honestly what wasn't run. |
| **CP4** | End week 4 | Airplane-mode verified, UI usable, write-up done | — |

---

## Definition of Done

The project is done when someone can read `docs/results.md` and learn something they could not have looked up: whether Apple's free `NLEmbedding` is good enough for real on-device retrieval, and whether spending a second LLM call on reranking buys enough recall to justify the latency — both measured on real hardware against a real corpus.

Everything else in this repo exists to produce that document honestly.
