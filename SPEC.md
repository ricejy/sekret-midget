# Spec: Private Document Q&A (iOS)

**Status:** Draft v3 — awaiting review
**Last updated:** 2026-07-27
**Supersedes:** v2 (screenshot retrieval) — rejected by the author. v1's document framing is restored and sharpened.

---

## Objective

An iOS app that lets you **upload sensitive documents and ask questions about them, with nothing ever leaving the phone.**

The documents this exists for are exactly the ones you would not paste into ChatGPT or Claude: employment contracts, leases, medical records, financial statements, legal correspondence, photographed ID documents. The value proposition is not "AI on your phone" — it is **AI you can use on material you are unwilling to upload anywhere.**

**Primary user:** the author, for real use. First real task: querying a sensitive contract.

**Success looks like:** you import a 40-page contract, ask *"what's the notice period for termination?"*, and get a correct answer citing the clause it came from — offline, with no account, and with confidence that the document never left the device.

### Why the privacy claim is real here

Every stage runs on models supplied by iOS itself:

- **Generation** — `FoundationModels` (iOS 26+). Free, on-device, **zero app bytes**: *"It's built into the operating system, so it won't increase your app size."* (Apple, WWDC25 s286)
- **Embeddings** — `NLEmbedding` (NaturalLanguage). Free, on-device, zero bytes.
- **OCR** — `Vision`. Free, on-device, zero bytes.

The app therefore ships with **no model weights at all** and makes no network calls. That is a materially stronger privacy claim than competitors who bundle a 1.4 GB model and still phone home for analytics — and it is verifiable by anyone with a packet capture.

### The constraint that shapes everything

**~4,096 tokens of context**, shared across instructions, retrieved text, question, and answer. The model sees **at most 3–4 chunks per query**.

This is not "chat with your documents." It is: *narrow question → answer grounded in the few most relevant passages → citation.* Retrieval precision is the difference between a useful product and a plausible-sounding liar. Most apps in this space fail here by stuffing whole PDFs into context.

### Non-goals for v1

- Android. No OS LLM, no OS embeddings, ~550 MB–1 GB bundled model. A second architecture, not a port.
- Monetization, accounts, App Store submission.
- General chat. Long multi-turn conversation. The context budget forbids both.
- Any network egress, including Apple's own Private Cloud Compute. Airplane mode must work permanently.
- Document editing, annotation, or management features. This app answers questions.

---

## Prerequisites

- **macOS + Xcode** for all iOS work. Dart work happens on Windows; native work on the Mac; synced via GitHub.
- **iPhone 15 Pro Max** with Apple Intelligence enabled and assets downloaded. Simulator support for `SystemLanguageModel` is undocumented — assume a physical device is required.

---

## Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| App | Flutter (latest stable, pin at init) | |
| Generation | `FoundationModels` via hand-written Swift bridge | 0 app bytes |
| Embeddings | `NLEmbedding`, with all-MiniLM-L6-v2 int8 (23 MB) as fallback | Fallback only if quality fails |
| OCR | Apple `Vision` (`VNRecognizeTextRequest`) via bridge | 0 bytes; ML Kit would cost ~38 MB on iOS |
| PDF text | `pdfrx` (MIT, actively maintained) | Avoids Syncfusion's commercial licensing |
| Store | `sqlite3` — documents, chunks, FTS5 index, vectors as BLOBs | |
| Lexical search | SQLite **FTS5** (BM25) | Built in, zero extra bytes |
| Vector search | Brute-force cosine over int8 vectors | No vector DB. See Storage Design. |

**No Flutter package wraps `FoundationModels` usefully** — all pub.dev candidates are 0.x, single-maintainer, built against iOS 26.0, under ~2,000 combined monthly downloads. We write the bridge. `flutter_local_ai` is worth reading as reference.

**Do not use** (verified stale/abandoned/superseded as of 2026-07): `onnxruntime` (gtbluesky), `tflite_flutter`, `isar`, `hive`, `sqlcipher_flutter_libs` (`0.7.0+eol`), `apple_vision*` wrappers, `mediapipe_genai`, `pdf_text`/`read_pdf_text`/`flutter_pdf_text`. `fonnx` has the best published benchmarks but is **GPLv2/commercial dual-licensed** — read, don't depend.

---

## Storage & Retrieval Design

### Sizing first

For a realistic personal corpus — ~20 documents averaging 20 pages, ≈2,000 chunks:

| Representation | Size |
|---|---:|
| Chunk text | ~1.2 MB |
| float32 vectors (384-dim) | ~3 MB |
| **int8 quantized vectors** | **~770 KB** |
| binary quantized (1 bit/dim) | ~96 KB |

**Conclusion: there is no storage or memory problem at this scale.** Even the naive approach fits in single-digit megabytes. Do not build for a constraint that does not exist — optimize for retrieval quality, take the cheap memory wins because they are free, and keep the heavier levers documented for later.

### The design

**Chunking** (matters far more here than it would for short documents):
- ~250 tokens with ~15% overlap
- Split on paragraph and clause boundaries, never mid-sentence
- **Prepend the section heading to each chunk's embedded text.** In contracts this single decision tends to outperform most other tuning — it gives otherwise-identical boilerplate chunks their distinguishing context.
- Retain page number and section heading as metadata for citation

**Storage:** one SQLite database.
- `documents` — id, title, source type, imported-at, page count
- `chunks` — id, document id, text, page, heading, token count
- `chunks_fts` — FTS5 virtual table over chunk text (BM25)
- `vectors` — chunk id, int8 vector BLOB, scale factor

Vectors are streamed from SQLite during search and never held fully resident. At these sizes the scan is a few milliseconds.

**Retrieval — hybrid, because neither half is sufficient alone:**
1. **FTS5/BM25** catches exact legal terms — *"pet deposit"*, *"Section 12.3"*, *"Tenant"*, dates, dollar amounts. Dense embeddings are weak on these.
2. **Dense cosine** catches paraphrase — *"can I have a dog?"* → *"Pet Deposit"* — where BM25 shares no vocabulary and scores zero.
3. **Reciprocal rank fusion** combines them. Per-signal contributions are kept separate so the UI can show *why* something ranked.
4. Take top ~20, then fill the context budget with the best 3–4.

**Optional, evaluated not assumed:** LLM reranking of the top 20 down to 4 using `FoundationModels` itself — a second use of the free OS model, directly attacking the 4-passage bottleneck. Worth measuring; may not justify its latency.

**Explicitly rejected:** vector databases (ObjectBox, sqlite-vec, HNSW). Brute force over a few thousand int8 vectors takes milliseconds. Adding an ANN index would be complexity in service of a problem this corpus does not have.

**Levers held in reserve** for when the corpus grows past ~50k chunks: binary quantization with float rescoring of the top 50; two-stage document-then-chunk retrieval; Matryoshka dimension truncation.

---

## Ingestion

Three input paths, all on-device:

1. **PDF with a text layer** — `pdfrx`, straightforward extraction.
2. **Scanned/image-only PDF and photos** — Apple Vision OCR. Required: sensitive material is often photographed rather than exported.
3. **Pasted text** — the zero-friction path, and the fastest way to test the whole pipeline.

Known OCR failure modes to expect and handle: multi-column layouts read left-to-right across columns; tables flatten into word soup; headers and footers bleed into body text; rotated or skewed scans degrade sharply. Native PDF text extraction returns **nothing** for image-only PDFs — OCR is a mandatory fallback, not an enhancement.

---

## Token Budget

Design against **4,096 tokens**. (A WWDC26 session page suggested 8,192 for iOS 27; this could not be confirmed from any primary source and the fetch was flagged unreliable. Treat headroom as a bonus, never a dependency.)

| Slot | Budget |
|---|---:|
| System instructions | ~150 |
| Retrieved chunks (3–4 × ~250) | ~1,000 |
| User question | ~100 |
| Answer reservation | ~512 |
| Safety margin | ~2,300 |

Measure with `SystemLanguageModel.tokenCount(for:)` (iOS 26.4+) rather than estimating. Add chunks in rank order until the budget is hit; drop whole chunks, never truncate mid-chunk.

---

## Project Structure

```
lib/
  core/
    ingest/       → PDF/image/text → OCR → chunking → indexing
    embed/        → Embedder interface + Apple/ONNX/fake impls
    store/        → sqlite3: documents, chunks, FTS5, vectors
    retrieve/     → BM25, dense, RRF fusion, optional LLM rerank
    generate/     → LlmBackend interface, context assembly, citations
    platform/     → MethodChannel/EventChannel plumbing
  ui/             → Library, import, ask, answer-with-sources
ios/Runner/Bridge/ → Swift: FoundationModels, NLEmbedding, Vision
test/
eval/             → Labeled questions + fixture documents (synthetic only)
tool/eval.dart    → Retrieval quality harness
docs/
```

### The Windows/Mac boundary

Every native capability sits behind a Dart interface with a working fake: `LlmBackend` · `Embedder` · `OcrEngine`.

Consequence: chunking, storage, FTS5, fusion, ranking, context assembly, citation mapping, the eval harness, and all UI are built and fully tested **on Windows**. Only the three bridge implementations and final measurement need the Mac. This is good design independently, but the two-machine setup makes it mandatory.

---

## Code Style

Standard `dart format` + `flutter_lints`. No `dynamic` in public APIs. No `late` without a justifying comment. Results over exceptions for expected failure paths.

```dart
/// Generation backend. Implementations must never perform network I/O.
abstract interface class LlmBackend {
  Future<LlmAvailability> availability();

  /// Streams the answer. Throws [LlmUnavailable] if not [Available] —
  /// callers must check availability first.
  Stream<String> generate({
    required String instructions,
    required String prompt,
    int maxOutputTokens = 512,
  });
}

/// Mirrors Apple's SystemLanguageModel.Availability. Each case needs a
/// distinct UI treatment, so we deliberately do not collapse it to a bool.
sealed class LlmAvailability {
  const LlmAvailability();
}

final class Available extends LlmAvailability {
  const Available();
}

/// Permanent — device lacks Apple Intelligence (pre-A17 Pro).
final class DeviceNotEligible extends LlmAvailability {
  const DeviceNotEligible();
}

/// User-actionable — deep-link to Settings.
final class AppleIntelligenceNotEnabled extends LlmAvailability {
  const AppleIntelligenceNotEnabled();
}

/// Transient — OS is still downloading model assets. Retry later.
final class ModelNotReady extends LlmAvailability {
  const ModelNotReady();
}
```

---

## Testing Strategy

**Unit (Windows, fakes, fast):** chunk boundaries and overlap · heading prepending · BM25 and RRF fusion math · cosine correctness against hand-computed vectors · int8 quantization round-trip error · context assembly respecting the budget · citation offsets resolving to the correct page · store round-trip.

**Retrieval eval:** a fixture corpus of **synthetic** contracts and policies in `eval/` — invented, never real personal documents — plus ≥30 labeled questions annotated with the chunk(s) that genuinely contain the answer. Primary metric **recall@4**: did a correct chunk survive into the passages the model actually saw? Re-run after any change to chunking, embedding, or ranking. This is what makes retrieval claims defensible rather than vibes.

**Bridge (Mac + device):** XCTest for the three availability states, streaming, `guardrailViolation` and `contextSizeExceeded` handling, and Vision OCR on a fixture image.

**Not doing:** coverage targets, golden-file UI tests.

---

## Boundaries

**Always**
- `flutter analyze` and `flutter test` clean before every commit.
- Every native capability behind an interface with a working fake.
- Re-run the retrieval eval after any change to chunking, embedding, or ranking.
- Handle all three `LlmAvailability` states wherever the model is reachable.
- Show the sources behind every answer. An uncited answer about a contract is worse than no answer.

**Ask first**
- Any new dependency, especially native or non-permissively licensed.
- Schema changes once real documents are indexed on the device.
- Switching the embedder — invalidates every stored vector, forces re-indexing.
- Anything that opens a socket, for any reason.

**Never**
- Send data off-device. No analytics, no crash reporting, no remote config, no PCC.
- Commit real personal documents. `eval/` fixtures are synthetic only.
- Claim a retrieval improvement without an eval run behind it.

---

## Success Criteria

v1 is done when, on the iPhone 15 Pro Max:

1. A PDF, a photographed document, and pasted text all import, chunk, embed, and index — with visible progress.
2. Asking a factual question about an imported contract returns a correct answer **with a citation resolving to the right page and clause**, in under 10 seconds.
3. **recall@4 ≥ 0.80** on the ≥30-question synthetic eval set. *(Provisional — this number is invented, not derived. Replace it with a real baseline after the first eval run.)*
4. Hybrid retrieval is shown by eval to beat dense-only. If it doesn't, that's a finding — record it and simplify.
5. **Guardrail refusal rate on realistic sensitive content is measured and acceptable.** See Risk R1.
6. The app works fully in airplane mode; a traffic capture over a full import-and-ask cycle shows **zero outbound requests**.
7. All three availability states render correct, actionable UI.
8. `flutter analyze` clean, `flutter test` green on Windows with fakes only.

---

## Risks

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| **R1** | **Guardrails refuse on sensitive content.** They cannot be disabled; `.permissiveContentTransformations` covers only plain-string output; over-blocking on medical and legal text is documented. This is the premise of the product. | **Fatal** | **Test first, before building anything.** Run ~20 realistic questions against a real contract and a medical document. If refusals are common, the product needs rethinking — not the implementation. |
| R2 | `NLEmbedding` quality on legalese is unknown; dimensionality and language coverage are undocumented | Medium | Probe `dimension` at runtime early; MiniLM fallback is specced and independent. FTS5 carries retrieval regardless. |
| R3 | OCR quality on photographed contracts too poor to retrieve against | High | OCR 20 real pages and read the output before building on it. |
| R4 | Chunking legal text badly — clauses split across chunks, cross-references broken | High | Eval catches it. Heading-prepending mitigates. Chunk on clause boundaries. |
| R5 | Simulator won't serve `SystemLanguageModel` | Low | Fakes cover all logic; only measurement needs hardware. |

---

## Open Questions

1. **Do guardrails refuse on your real documents?** Everything else is downstream of this. Test before writing code.
2. `NLEmbedding` dimensionality, language coverage, and quality on legalese — resolved by runtime probe plus eval, not by reading docs.
3. Does the Simulator serve `SystemLanguageModel`? Affects iteration speed given the two-machine setup.
4. Optimal chunk size for contracts — 250 tokens is a starting guess, not a derived value. The eval decides.
5. Is 4,096 still the ceiling on iOS 27? Unresolved. Design for 4,096.
6. Encryption at rest — deferred for v1. Documents live in the app's sandbox under iOS Data Protection. If added later: SQLite3MultipleCiphers via `package:sqlite3` (**not** `sqlcipher_flutter_libs`, now `0.7.0+eol`), key in Keychain, entangled with an on-disk random key so uninstall genuinely invalidates it (iOS Keychain items survive app deletion).
7. Project name.

---

## Appendix: Verified Facts

Confidence flags are honest; several claims were explicitly not confirmable.

- **App size:** Apple, WWDC25 s286, verbatim: *"It's built into the operating system, so it won't increase your app size."* HIGH.
- **Context window:** 4,096 tokens shared input+output, per Apple's own changelog (Feb 2026). Overflow raises `exceededContextWindowSize` / `contextSizeExceeded`. HIGH for 26.x. The 8,192 figure for iOS 27 is **UNVERIFIED**.
- **Availability states:** exactly three — `deviceNotEligible` (permanent), `appleIntelligenceNotEnabled` (user action), `modelNotReady` (transient). No way to trigger the asset download from the app. HIGH.
- **Device floor:** iPhone 15 Pro / 15 Pro Max (A17 Pro). Base iPhone 15 and older excluded. From the 16 generation on, all iPhones qualify including 16e/17e. HIGH. Share of active install base **UNVERIFIED**.
- **`NLEmbedding`:** sentence-level, iOS 13+, **not deprecated**, exposes `vector(for:)`, `distance(between:and:)`, `neighbors(for:maximumCount:)`. Dimensionality and language coverage **UNDOCUMENTED**. HIGH on existence, UNVERIFIED on numbers.
- **`FoundationModels` ships no embedding API** — confirmed against the full framework symbol listing. HIGH negative.
- **`SpotlightSearchTool`** (CoreSpotlight, iOS 27 beta) searches only your app's own Spotlight index and files your app created — not arbitrary user content. No free RAG. HIGH.
- **Guardrails cannot be fully disabled.** `.permissiveContentTransformations` applies only to plain-string output; guided generation always runs default guardrails. HIGH.
- **App Store:** no AI-specific guideline exists. Generic 4.7 (chatbots: content filtering, abuse reporting, age gating) applies. MODERATE-HIGH.
- **MiniLM benchmark (measured):** all-MiniLM-L6-v2 int8, 23.0 MB, 384-dim — iPhone 14 **67 ms**, Pixel Fold **33 ms** per ~200-word chunk (fonnx, ORT 1.16.1, Oct 2023, methodology disclosed).
- **Brute-force cosine viability:** comfortable to ~10K–50K vectors; INFERRED from FAISS/Pinecone figures, no mobile-Dart benchmark exists.
- **iOS Keychain items survive app deletion** (confirmed by Apple DTS) — relevant if encryption is added later.
- **Market context:** "private and on-device" is not differentiation — a dozen apps claim it, and every app attempting local document RAG has single-digit-to-low-teens rating counts. The unfilled gap is execution quality on real retrieval; most competitors stuff whole PDFs into context and call it RAG. Recorded for honesty; does not affect a build-for-yourself first iteration.
