# V1 release-gate evidence — 2026-09-06

This report contains only fictional test details and aggregate private-smoke results. It retains no private excerpts, questions, answers, names, diagnoses, identifiers, or document details.

## Build under test

| Item | Value |
|---|---|
| Git commit | `1a4e198ac8b03a293fdbb6a61abb6acdb32b7a05` |
| App version | `0.1.0+1` |
| Flutter / Dart | Flutter 3.44.9 stable / Dart 3.12.2 |
| Xcode | 26.6 (17F113) |
| Target | iPhone 15 Pro Max (`iPhone16,2`) |
| Target OS | iOS 26.6.1 (23G83) |
| Foundation Models version | No separate version is exposed to the app; OS/build is the recorded model-runtime identifier |
| Build | Signed iOS Release, 25.9 MB |

## Automated and native verification

| Check | Result |
|---|---|
| `flutter analyze` | Pass, no issues |
| Full Flutter test suite on macOS | Pass, 71 tests |
| Full portable suite on Windows | Pending final run on this commit |
| Runner native bridge suite | Pass on iOS Simulator |
| Guardrail harness suite | Pass, 5 tests on iOS Simulator |
| Static network-client/dependency audit | Pass; no application network client, analytics, telemetry, or crash-reporting SDK found |
| Release network-connection capture | Pass; zero connections attributed to Sekret Midget during a complete 84-second import-and-question cycle |

The Runner suite covered Foundation Models generation, streaming, error mapping, prompt freezing, Natural Language embeddings, Vision OCR fixtures, exact token counting, and availability mapping. Simulator-inapplicable file-protection behavior was skipped there and is covered by the production database configuration and physical-device gate.

## Retrieval evaluation

The production retrieval evaluation ran physically with Apple Natural Language embeddings (`en`, 512 dimensions, revision 1):

- Hybrid recall@4: 30/30 (1.0000).
- Dense-only recall@4: 29/30 (0.9667).
- Hybrid retrieval recovered the single dense-only miss.
- Decision: retain Apple embeddings and hybrid reciprocal-rank fusion.

## Foundation Models and guardrail evaluation

The physical production evaluation passed with a 4,096-token context, 97 instruction tokens, 92 prompt tokens, a grounded supported answer, an app-resolved citation, the exact unsupported-evidence abstention, and 4,601 ms total elapsed time.

Synthetic acceptance on iOS 26.6 passed:

- 36/40 answerable cases correct.
- Zero benign refusals.
- 10/10 unanswerable cases correctly abstained.
- Zero invented answers and no systematic refusal category.
- Median initial latency: 802 ms.
- All four initial failures were conservative abstentions. One recovered on required rerun; three repeated the abstention.

The aggregate-only private smoke test on iOS 26.6.1 passed 10/10 with zero refusals, invented answers, factual errors, false abstentions, or runtime failures. Median latency was 2,376 ms.

## Physical Release acceptance

The signed Release app completed the following sequence while disconnected from the Mac and in Airplane Mode:

| Input | Import and progress | Answer/citation | Deletion |
|---|---|---|---|
| Pasted fictional text | Pass | Correct 21-day notice answer; exact abstention for an unsupported question | Pass in UI and database audit |
| Text-layer fictional PDF | Pass | Correct 45-day notice answer; `NOTICE PERIOD`, page 2 | Pass in UI and database audit |
| Image-only fictional PDF | Pass, including OCR | Correct seven-day equipment-return answer; `RETURN DEADLINE`, page 1 | Pass in UI and database audit |
| Fictional document photo | Pass, including OCR | Correct seven-day equipment-return answer; `RETURN DEADLINE`, page 1 | Pass in UI and database audit |

Visible extraction/OCR, chunking, embedding, and indexing progress behaved as intended. The measured manual upper bound for the text-layer PDF answer was approximately two seconds, below the ten-second goal. No discrepancy was observed.

The post-run physical database audit found zero document rows imported during the 2026-09-06 Release run and zero orphaned chunks, vectors, or FTS entries. Three older document rows predated this run and were left untouched. Titles and document content were not inspected. The temporary audit copy was erased immediately after the aggregate checks.

## Privacy verification

An Instruments 26.6 Network Connections recording targeted `Sekret Midget (20251, launched)` on the recorded iPhone and covered a complete Release import, question, answer/citation, and deletion cycle. The run lasted 1 minute 24 seconds. Filtering the connection summary for `Sekret Midget` returned `No Data`, so the capture found zero connections or outbound requests attributable to the app.

Only the Network Connections instrument was enabled. The HTTP Traffic instrument was deliberately removed before recording, so request URLs, headers, bodies, and document content were not captured. Instruments listed unrelated device-level connections under `Unknown`; these were not attributed to Sekret Midget and are not counted as application traffic.

A second recording was attempted with Airplane Mode enabled and Wi-Fi disabled, but Instruments reported the target device offline and did not start or record a trace. The separately completed Airplane Mode acceptance run therefore remains the evidence that the complete workflow operates without connectivity, while the app-targeted Instruments run is the empirical traffic check.

## Remaining checks

- Run the static analysis and full portable fake-backed suite on Windows at the recorded commit.
