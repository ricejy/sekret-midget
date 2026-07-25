# Spec: On-Device Screenshot Retrieval (iOS)

**Status:** Draft v2 — awaiting review
**Last updated:** 2026-07-26
**Supersedes:** v1 (personal admin documents) — rejected because the corpus was too small for retrieval to be a real problem. Rationale in `docs/ideas/screenshot-rag.md`.

---

## Objective

Answer questions about your own screenshot library, entirely on-device, using models supplied by iOS.

**The deliverable is not the app.** It is a **measured comparison of on-device retrieval strategies** on a real, messy, personal corpus — reported as recall@4 and latency on an iPhone 15 Pro Max. The app is the vehicle that produces and demonstrates those numbers.

**Audience:** AI/ML engineering roles. The artifact they will look at is the results table and the eval methodology, not the UI.

**Timeline:** ~1 month.

### Why this is worth building

No independent, reproducible benchmark of on-device RAG on Apple silicon appears to exist — my research found zero Flutter on-device RAG case studies reporting latency, recall, or memory. Meanwhile Apple ships a free LLM, free sentence embeddings, and free OCR, none of which have been rigorously compared for retrieval.

There is a real constraint that makes the problem non-trivial: **~4,096 tokens of context, shared across instructions, retrieved text, question, and answer.** The model sees at most ~4 screenshots per query. Almost every shipping app in this space fails this by stuffing whole documents into context. Here it is the explicit research question: *how good can retrieval get when the generator can only see four passages?*

### Non-goals

- UI/UX quality. Explicitly deferred. One debug-grade screen.
- Android, monetization, App Store submission, accounts, onboarding.
- Document/PDF import, chunking strategies, vector databases. See "Not Doing" in the idea one-pager.
- Any network egress, including Apple's Private Cloud Compute. Airplane mode must work permanently.

---

## Prerequisites

- **macOS + Xcode.** All iOS build/run/debug work. Dart work happens on Windows; native work on the Mac; repo synced via GitHub.
- **iPhone 15 Pro Max** with Apple Intelligence enabled and model assets downloaded. Simulator support for `SystemLanguageModel` is undocumented — assume physical device required.
- **The Photos baseline test, run before any code is written** (see Task 0).

---

## Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| App | Flutter (latest stable, pin at init) | Thin shell |
| LLM | `FoundationModels` (iOS 26+) via hand-written Swift bridge | 0 app bytes |
| Embeddings | `NLEmbedding.sentenceEmbedding` **and** all-MiniLM-L6-v2 int8 (23 MB, `flutter_onnxruntime`) | Both — comparing them is an experiment, not a choice |
| OCR | Apple `Vision` (`VNRecognizeTextRequest`) via bridge | 0 bytes; ML Kit would cost ~38 MB on iOS |
| Photos | `PHAsset` filtered to `PHAssetMediaSubtype.photoScreenshot` | Screenshots album only |
| Store | `sqlite3` — screenshots, OCR text, vectors as BLOBs | No encryption in v1 |
| Retrieval | Brute-force cosine in Dart | Provably sufficient: 5k × 384 dims ≈ 7.7 MB, ~4 ms scan |

**No Flutter package wraps `FoundationModels` usefully** — all pub.dev candidates are 0.x, single-maintainer, built against iOS 26.0, under ~2,000 combined monthly downloads. We write the bridge. `flutter_local_ai` is worth reading as reference.

**Do not use** (verified stale/abandoned/superseded as of 2026-07): `onnxruntime` (gtbluesky), `tflite_flutter`, `isar`, `hive`, `sqlcipher_flutter_libs` (`0.7.0+eol`), `apple_vision*` wrappers, `mediapipe_genai`. `fonnx` has the best published benchmarks but is **GPLv2/commercial dual-licensed** — read, don't depend.

---

## The Experiment Matrix

This is the core of the project. Each axis is independently switchable so the eval can isolate its contribution.

**1. Embedder**
- `NLEmbedding` (Apple, 0 bytes, dimensionality undocumented — probe at runtime)
- all-MiniLM-L6-v2 int8 (23 MB, 384-dim; measured 67 ms/chunk on iPhone 14)

**2. Indexed representation** — what text actually gets embedded
- Raw OCR text
- OCR text + metadata (source app, date)
- **LLM-enriched:** a one-sentence description generated per screenshot at index time, embedded instead of raw OCR. Potentially transformative on noisy OCR; costs one LLM call per screenshot (hours of batch). Run on a 200-screenshot subset first to decide if it earns its cost.

**3. Ranking**
- Dense cosine only (baseline)
- Dense + BM25 via reciprocal rank fusion
- Dense + recency + source-app fusion — screenshot queries are heavily temporal ("that thing last week") and contextual ("in Messages"), so this may matter more than BM25

**4. Reranking**
- None
- **LLM rerank:** retrieve top 20 cheaply, score each with `FoundationModels` in a compact prompt, keep top 4. Uses the free OS model twice per query for two different jobs, and directly attacks the 4-passage bottleneck. **This is the headline experiment.**

**5. Query handling**
- Raw user query
- LLM query rewrite/expansion before retrieval

---

## Metrics

| Metric | Definition | Why |
|---|---|---|
| **recall@4** | Did a correct source screenshot survive into the 4 fed to the model? | Primary. Directly bounds achievable answer quality. |
| MRR@20 | Mean reciprocal rank over the pre-truncation candidate set | Separates retrieval quality from the 4-slot truncation |
| Answer correctness | Human-judged, on the labeled set | recall@4 can be high while answers are still bad |
| Ingest latency | ms/screenshot, split OCR vs embed | Determines whether a 5k-screenshot import is tolerable |
| Query latency | p50/p95, end to end | LLM reranking will hurt here — quantify the trade |
| Storage | Bytes/screenshot | Supports the "absurdly small" claim |

### Ground truth

Target **≥50 labeled questions**, each annotated with the screenshot(s) that genuinely contain the answer.

Cheap bootstrapping technique: sample a random screenshot, ask *"what question would this answer?"*, write it down. Generates labeled pairs far faster than thinking up questions and then hunting for sources. Mix in the 10 questions from the Photos baseline test.

**Two corpora.** Personal screenshots produce the real numbers but cannot be published. Also build a small public/synthetic screenshot set with shipped labels so the comparison is reproducible by others. Decide the split before writing the harness — it shapes the interface.

---

## Commands

```bash
# Cross-platform (Windows + Mac) — fakes, no device
flutter pub get
flutter analyze
flutter test
dart format --set-exit-if-changed .

# The eval harness — the primary artifact
dart run tool/eval.dart --strategy=dense-nl --corpus=eval/public
dart run tool/eval.dart --all-strategies --out=docs/results.md

# Mac only
flutter run -d <device-id>          # physical iPhone
flutter build ios --release
cd ios && xcodebuild test -scheme Runner -destination 'platform=iOS,name=<device>'
```

---

## Project Structure

```
lib/
  core/
    ingest/       → PHAsset enumeration, OCR batch job, resumability
    embed/        → Embedder interface + Apple/ONNX/fake impls
    store/        → sqlite3: screenshots, ocr_text, vectors, metadata
    retrieve/     → RetrievalStrategy interface + all strategy impls
    generate/     → LlmBackend interface + Apple/fake impls
    platform/     → MethodChannel/EventChannel plumbing
  ui/             → One screen. Ask, answer, 4 sources with scores.
ios/Runner/Bridge/ → Swift: FoundationModels, NLEmbedding, Vision
tool/
  eval.dart       → Eval runner, emits the results table
eval/
  public/         → Shareable synthetic corpus + labels
  personal/       → Gitignored. Never committed.
  questions.yaml  → Labeled Q→source pairs
test/
docs/
  results.md      → THE ARTIFACT
  ideas/
  adr/
```

### The Windows/Mac boundary

Every native capability sits behind a Dart interface with a working fake:
`LlmBackend` · `Embedder` · `OcrEngine` · `ScreenshotSource`

Consequence: storage, retrieval, ranking, fusion, eval harness, and UI are all developed and tested **on Windows**. Only the four bridge implementations and final measurement need the Mac. This is both good design and a practical necessity given the two-machine setup.

---

## Code Style

Standard `dart format` + `flutter_lints`. No `dynamic` in public APIs. Results over exceptions for expected failures.

The central abstraction — strategies must be swappable by the eval harness without touching anything else:

```dart
/// A complete retrieval configuration. The eval harness enumerates these
/// and reports one row per strategy, so every implementation must be
/// constructible without side effects and free of hidden global state.
abstract interface class RetrievalStrategy {
  /// Stable identifier used as the row key in results.md.
  String get id;

  /// Returns candidates ranked best-first, at most [limit].
  /// Implementations must not truncate to the context budget — that is the
  /// caller's job, so retrieval quality stays measurable independently of
  /// how many passages happen to fit.
  Future<List<ScoredScreenshot>> retrieve(String query, {int limit = 20});
}

final class ScoredScreenshot {
  const ScoredScreenshot({
    required this.id,
    required this.score,
    required this.signals,
  });

  final ScreenshotId id;
  final double score;

  /// Per-signal contributions (dense, bm25, recency, rerank) kept separate
  /// so the debug UI and the eval can both attribute *why* something ranked.
  final Map<String, double> signals;
}
```

---

## Token Budget

Design against **4,096 tokens**. (A WWDC26 session page suggested 8,192 for iOS 27, but this could not be confirmed from any primary source and the fetch was flagged unreliable. Treat headroom as a bonus, never a dependency.)

| Slot | Budget |
|---|---:|
| System instructions | ~150 |
| 4 screenshots' OCR text | ~1,600 |
| User question | ~100 |
| Answer reservation | ~512 |
| Safety margin | ~1,700 |

Measure with `SystemLanguageModel.tokenCount(for:)` (iOS 26.4+) rather than estimating. Add sources in rank order until the budget is hit; drop whole units, never truncate mid-screenshot.

---

## Testing Strategy

**Unit (Windows, fakes, fast):** cosine correctness against hand-computed vectors · RRF fusion math · recency decay · ranking tie-breaks · context assembly respecting the budget · store round-trip · ingest resumability after simulated interruption.

**Eval (the real gate):** `tool/eval.dart` runs every strategy against the labeled set and emits `docs/results.md`. Runs on Windows with the fake embedder for harness correctness; real numbers come from the Mac and device. **No retrieval change lands without a re-run.**

**Bridge (Mac + device):** XCTest for the three `LlmAvailability` states, streaming, `guardrailViolation` handling, and Vision OCR on a fixture image.

**Not doing:** coverage targets, golden-file UI tests, widget tests beyond smoke level.

---

## Boundaries

**Always**
- `flutter analyze` and `flutter test` clean before every commit.
- Every native capability behind an interface with a working fake.
- Re-run the eval after any retrieval, embedding, or representation change.
- Report numbers with the corpus and device they came from.

**Ask first**
- Any new dependency, especially native or non-permissively licensed.
- Schema changes once a real index exists on the device (re-ingest is expensive).
- Switching the default embedder — invalidates every stored vector.
- Anything that opens a socket, for any reason.

**Never**
- Send data off-device. No analytics, no crash reporting, no PCC.
- Commit personal screenshots, OCR output, or personal labels. `eval/personal/` is gitignored.
- Claim a retrieval improvement without an eval run backing it.
- Report a number without saying which corpus produced it.

---

## Success Criteria

v1 is done when:

1. **The Photos baseline is documented** — how many of 10 real questions Apple Photos already answers, recorded in `docs/results.md` as the thing this project must beat.
2. **≥50 labeled questions** exist over the personal corpus, plus a shareable public set.
3. **`docs/results.md` contains a populated results table** across at least four strategy configurations, with recall@4, MRR@20, and query latency, measured on the iPhone 15 Pro Max.
4. **The `NLEmbedding` vs MiniLM question is answered with data** — including whether the app can ship with zero bundled model weights.
5. **The LLM-reranking experiment has a verdict** — the recall gain and the latency cost, both measured.
6. A full ingest of the real screenshot library completes, is resumable, and reports its throughput.
7. Asking a question returns an answer with its four sources and their per-signal scores visible.
8. Airplane mode works; a traffic capture over a full ingest-and-ask cycle shows zero outbound requests.
9. `flutter analyze` clean, `flutter test` green on Windows with fakes only.

**Provisional usability floor:** recall@4 ≥ 0.70 on the personal corpus for the app to feel worth using. This number is invented, not derived — replace it with a real baseline after the first eval run.

---

## Sequencing

| Week | Focus |
|---|---|
| 0 | **Photos baseline test.** No code. Go/no-go. |
| 1 | Swift bridge (OCR + embedding + LLM), Photos enumeration, store, resumable ingest |
| 2 | Eval harness, labeled question set, dense baseline numbers |
| 3 | The experiments: embedder comparison, fusion, reranking, enrichment |
| 4 | Generation, minimal UI, `docs/results.md` write-up |

Week 1 is the risky one — it is the least interesting work and the most likely to overrun. If ingest is still fighting you at the end of week 1, cut OCR scope (fewer screenshots, English only) rather than compressing the eval weeks.

---

## Open Questions

1. **`NLEmbedding` quality on short noisy OCR text is unknown.** Dimensionality and language coverage are undocumented; the API predates iOS 13 and hasn't been updated. Apple's own docs do steer semantic-similarity work toward it over `NLContextualEmbedding`. Resolved by experiment, not by reading.
2. **Guardrails cannot be disabled** and are documented as over-blocking benign content. A personal screenshot library contains medical, financial, and private-message material. Probe early with 20 realistic queries.
3. Does the Simulator serve `SystemLanguageModel`? Undocumented; affects iteration speed.
4. Is index-time LLM enrichment affordable at full corpus scale?
5. Is 4,096 still the ceiling on iOS 27? Unresolved. Design for 4,096.
6. Project name.

---

## Appendix: Verified Facts

Confidence flags are honest; several claims were explicitly not confirmable.

- **App size:** Apple, WWDC25 s286, verbatim: *"It's built into the operating system, so it won't increase your app size."* HIGH.
- **Context window:** 4,096 tokens shared input+output, per Apple's own changelog (Feb 2026). Overflow raises `exceededContextWindowSize` / `contextSizeExceeded`. HIGH for 26.x. The 8,192 figure for iOS 27 is **UNVERIFIED**.
- **Availability states:** exactly three — `deviceNotEligible` (permanent), `appleIntelligenceNotEnabled` (user action), `modelNotReady` (transient). No way to trigger asset download from the app. HIGH.
- **Device floor:** iPhone 15 Pro / 15 Pro Max (A17 Pro). Base iPhone 15 and older excluded. From the 16 generation on, all iPhones qualify including 16e/17e. HIGH. Share of active install base **UNVERIFIED**.
- **`NLEmbedding`:** sentence-level, iOS 13+, **not deprecated**, exposes `vector(for:)`, `distance(between:and:)`, `neighbors(for:maximumCount:)`. Dimensionality and language coverage **UNDOCUMENTED**. HIGH on existence, UNVERIFIED on numbers.
- **`FoundationModels` ships no embedding API** — confirmed against the full symbol listing. HIGH negative.
- **`SpotlightSearchTool`** (CoreSpotlight, iOS 27 beta) searches only your app's own Spotlight index and files your app created — not arbitrary user content. No free RAG. HIGH.
- **Guardrails cannot be fully disabled.** `.permissiveContentTransformations` applies only to plain-string output. HIGH.
- **App Store:** no AI-specific guideline exists. Generic 4.7 (chatbots: content filtering, abuse reporting, age gating) applies. MODERATE-HIGH.
- **MiniLM benchmark (measured):** all-MiniLM-L6-v2 int8, 23.0 MB, 384-dim — iPhone 14 **67 ms**, Pixel Fold **33 ms** per ~200-word unit (fonnx, ORT 1.16.1, Oct 2023, methodology disclosed).
- **Brute-force cosine viability:** comfortable to ~10K–50K vectors; INFERRED from FAISS/Pinecone figures, no mobile-Dart benchmark exists. 5k screenshots ≈ 7.7 MB of vectors, ~4 ms scan.
- **Competitive note:** iOS already OCRs screenshots and exposes that text to Photos search. The wedge is semantic retrieval and synthesis, not keyword finding. **Quantify this in Task 0 before building.**
