# Task List

Ordered by dependency. See `tasks/plan.md` for rationale, risks, and checkpoints.
Legend: 🪟 Windows-only · 🍎 Mac required · 👤 human time, not code

---

## Week 0 — The Gate

- [ ] **T0.1 👤 Photos baseline test** — no code
  - Acceptance: 10 questions you'd genuinely ask your screenshot history, each tried in Photos search, hit/miss recorded. Screenshot count recorded (Photos → Media Types → Screenshots).
  - Verify: `docs/results.md` contains the baseline table and the corpus size.
  - Files: `docs/results.md`
  - **STOP CONDITION:** Photos answers ≥8/10, or fewer than ~1,000 screenshots → re-scope before continuing.

- [ ] **T0.2 Install and pin Flutter on both machines**
  - Acceptance: identical stable version on Windows and Mac; `flutter doctor` clean for iOS on the Mac; version recorded in `SPEC.md`.
  - Verify: `flutter --version` matches on both; `flutter doctor -v`.
  - Files: `SPEC.md`

- [ ] **T0.3 Scaffold the Flutter project**
  - Acceptance: `flutter create` with iOS + the directory layout from `SPEC.md`; runs on device; `flutter analyze` clean.
  - Verify: `flutter analyze && flutter test`; app launches on the iPhone.
  - Files: `pubspec.yaml`, `lib/main.dart`, `analysis_options.yaml`, `ios/`

---

## Week 1 — Foundations 🪟 (parallel with the Mac track below)

- [ ] **T1.1 Core interfaces + fakes** ← keystone, do first
  - Acceptance: `Embedder`, `LlmBackend`, `OcrEngine`, `ScreenshotSource` defined with deterministic fakes. `LlmAvailability` models all three Apple states. No native type leaks through any signature.
  - Verify: `flutter test` green with fakes only, no device.
  - Files: `lib/core/embed/embedder.dart`, `lib/core/generate/llm_backend.dart`, `lib/core/ingest/ocr_engine.dart`, `lib/core/ingest/screenshot_source.dart`, `test/core/fakes_test.dart`

- [ ] **T1.2 sqlite3 store + schema**
  - Acceptance: tables for screenshots, OCR text, vectors (BLOB), metadata (source app, captured-at). Insert/query/round-trip a 384-dim vector without precision loss.
  - Verify: `flutter test test/core/store_test.dart`
  - Files: `lib/core/store/schema.dart`, `lib/core/store/store.dart`, `test/core/store_test.dart`

- [ ] **T1.3 Brute-force cosine + ranking**
  - Acceptance: cosine matches hand-computed values; ranking is stable and deterministic under ties; scans 5,000 × 384-dim in <20 ms on desktop.
  - Verify: `flutter test test/core/retrieve_test.dart` incl. a timing assertion.
  - Files: `lib/core/retrieve/cosine.dart`, `lib/core/retrieve/strategy.dart`, `test/core/retrieve_test.dart`

- [ ] **T1.4 Context assembly under token budget**
  - Acceptance: adds sources in rank order until the budget is hit; drops whole units, never truncates mid-screenshot; respects the reservation for output.
  - Verify: `flutter test test/core/context_test.dart` incl. an over-budget case.
  - Files: `lib/core/generate/context_builder.dart`, `test/core/context_test.dart`

---

## Week 1 — Bridge 🍎 (highest schedule risk — see R3)

- [ ] **T2.1 Swift bridge scaffolding + availability**
  - Acceptance: MethodChannel wired; `SystemLanguageModel.availability` surfaced faithfully as all three states; Dart receives them as `LlmAvailability`.
  - Verify: XCTest on device; force each state (disable Apple Intelligence in Settings to hit `appleIntelligenceNotEnabled`).
  - Files: `ios/Runner/Bridge/FoundationModelsBridge.swift`, `lib/core/platform/channels.dart`, `test/core/availability_test.dart`

- [ ] **T2.2 Vision OCR bridge** — includes R7 probe
  - Acceptance: `VNRecognizeTextRequest` returns text for an image path. **Then OCR 50 real screenshots and read the raw output by hand** before anything is built on top.
  - Verify: XCTest on a fixture image; findings on OCR quality recorded in `docs/results.md`.
  - Files: `ios/Runner/Bridge/OcrBridge.swift`, `lib/core/ingest/apple_vision_ocr.dart`, `docs/results.md`

- [ ] **T2.3 `NLEmbedding` bridge + dimension probe** ← resolves Open Question 1
  - Acceptance: `sentenceEmbedding(for: .english)` loads; **`dimension` probed and recorded**; returns a stable vector for the same input; nil-handling defined for unsupported languages.
  - Verify: XCTest; dimensionality written into `SPEC.md` (currently "undocumented").
  - Files: `ios/Runner/Bridge/EmbeddingBridge.swift`, `lib/core/embed/apple_nl_embedder.dart`, `SPEC.md`

- [ ] **T2.4 `FoundationModels` generation + streaming**
  - Acceptance: prompt in, tokens streamed out over an EventChannel; `guardrailViolation` and `contextSizeExceeded` surfaced as distinct typed Dart errors, not generic failures.
  - Verify: XCTest on device; deliberately overflow the context to confirm the error path.
  - Files: `ios/Runner/Bridge/FoundationModelsBridge.swift`, `lib/core/generate/apple_llm_backend.dart`, `test/core/generate_test.dart`

- [ ] **T2.5 Photos enumeration**
  - Acceptance: `PHAsset` fetch limited to `PHAssetMediaSubtype.photoScreenshot`; returns id, captured-at, and image path; permission denial handled.
  - Verify: run on device, count matches the Photos app's Screenshots album.
  - Files: `ios/Runner/Bridge/PhotosBridge.swift`, `lib/core/ingest/photos_screenshot_source.dart`

---

## Week 1–2 — Ingest

- [ ] **T3.1 Resumable ingest pipeline**
  - Acceptance: enumerate → OCR → embed → store, with progress, cancellation, and resume-after-kill. Re-running skips already-processed assets. Reports ms/screenshot split by stage.
  - Verify: `flutter test` for resume logic with fakes; kill mid-run on device and confirm it resumes.
  - Files: `lib/core/ingest/pipeline.dart`, `lib/core/ingest/checkpoint.dart`, `test/core/ingest_test.dart`

- [ ] **T3.2 Full ingest of the real corpus** — CP1
  - Acceptance: entire library ingested; throughput, total time, and storage bytes/screenshot recorded.
  - Verify: numbers land in `docs/results.md`.
  - Files: `docs/results.md`

---

## Week 2 — First Real Number

- [ ] **T4.1 👤 Labeled question set** — start in week 1, don't defer (see R8)
  - Acceptance: ≥50 questions in `eval/questions.yaml`, each mapped to the screenshot(s) that genuinely contain the answer. Includes the 10 from T0.1. Technique: sample a random screenshot, write the question it answers.
  - Verify: schema validates; every referenced screenshot id exists in the store.
  - Files: `eval/questions.yaml`, `tool/validate_questions.dart`

- [ ] **T4.2 Eval harness**
  - Acceptance: `dart run tool/eval.dart --strategy=<id>` computes recall@4, MRR@20, and query latency p50/p95; `--all-strategies` emits the results table into `docs/results.md`. Every row records corpus and device.
  - Verify: runs on Windows against fakes with a synthetic corpus and known-correct expected output.
  - Files: `tool/eval.dart`, `lib/core/eval/metrics.dart`, `test/core/metrics_test.dart`

- [ ] **T4.3 Dense baseline — `NLEmbedding`** — CP2
  - Acceptance: first honest recall@4 on the real corpus.
  - Verify: `docs/results.md` has a populated baseline row.
  - Files: `docs/results.md`

- [ ] **T4.4 MiniLM embedder + the headline comparison**
  - Acceptance: all-MiniLM-L6-v2 int8 via `flutter_onnxruntime`; same eval re-run; `NLEmbedding` vs MiniLM decided **on data**, with app-size cost stated (0 MB vs 23 MB).
  - Verify: both rows in `docs/results.md`; `SPEC.md` updated with the decision and its reasoning.
  - Files: `lib/core/embed/onnx_embedder.dart`, `assets/models/` (gitignored), `docs/results.md`, `SPEC.md`

- [ ] **T4.5 Guardrail refusal probe** — R5
  - Acceptance: 20 realistic queries over real screenshots; refusal rate measured and characterised (what kind of content triggers it).
  - Verify: recorded in `docs/results.md` as a finding.
  - Files: `docs/results.md`

---

## Week 3 — The Experiments (protect this week)

- [ ] **T5.1 BM25 + reciprocal rank fusion**
  - Acceptance: lexical index over OCR text; RRF against dense; fusion weight configurable; per-signal contributions exposed in `ScoredScreenshot.signals`.
  - Verify: `flutter test` for RRF math; eval row added.
  - Files: `lib/core/retrieve/bm25.dart`, `lib/core/retrieve/fusion.dart`, `test/core/fusion_test.dart`, `docs/results.md`

- [ ] **T5.2 Recency + source-app fusion**
  - Acceptance: recency decay and source-app match as additional signals; evaluated separately and combined with BM25.
  - Verify: `flutter test` for decay curve; eval rows added.
  - Files: `lib/core/retrieve/recency.dart`, `test/core/recency_test.dart`, `docs/results.md`

- [ ] **T5.3 LLM reranking** ← headline experiment
  - Acceptance: retrieve top 20, score each with `FoundationModels` in a compact prompt, keep top 4. **Both the recall@4 gain and the added query latency reported.**
  - Verify: eval rows with and without rerank, on the same corpus and device.
  - Files: `lib/core/retrieve/llm_reranker.dart`, `test/core/reranker_test.dart`, `docs/results.md`

- [ ] **T5.4 Index-time LLM enrichment (200-screenshot subset)**
  - Acceptance: generate a one-sentence description per screenshot, embed that instead of raw OCR; evaluated on the subset only. Full-corpus cost extrapolated and reported.
  - Verify: eval row on the subset; explicit go/no-go on whether it earns its batch cost.
  - Files: `lib/core/ingest/enrichment.dart`, `docs/results.md`

- [ ] **T5.5 Query rewriting**
  - Acceptance: LLM expands/rewrites the query before retrieval; evaluated against the best config so far.
  - Verify: eval row added.
  - Files: `lib/core/retrieve/query_rewriter.dart`, `docs/results.md`

---

## Week 4 — Ship

- [ ] **T6.1 End-to-end generation path**
  - Acceptance: question → retrieve → assemble under budget → generate → answer with source ids, using the winning strategy from week 3.
  - Verify: integration test with fakes; manual run on device.
  - Files: `lib/core/generate/answer_service.dart`, `test/core/answer_service_test.dart`

- [ ] **T6.2 Minimal UI**
  - Acceptance: one screen — ask, streamed answer, the 4 source screenshots with per-signal scores visible. Handles all three availability states. Debug-grade is fine.
  - Verify: manual on device.
  - Files: `lib/ui/ask_screen.dart`, `lib/ui/source_tile.dart`, `lib/main.dart`

- [ ] **T6.3 Airplane-mode + zero-egress verification**
  - Acceptance: full ingest-and-ask cycle in airplane mode; a traffic capture over a normal cycle shows zero outbound requests.
  - Verify: capture recorded as evidence in `docs/results.md`.
  - Files: `docs/results.md`

- [ ] **T6.4 Write-up** ← the artifact
  - Acceptance: `docs/results.md` opens with the results table, states corpus size and device, reports the Photos baseline it beats, and answers the five questions from `SPEC.md` success criteria. README links to it.
  - Verify: a stranger can read it and learn something they couldn't look up.
  - Files: `docs/results.md`, `README.md`
