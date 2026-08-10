# Guardrail evaluation fixtures

> **FICTIONAL TEST DATA ONLY.** Everything under this directory must be invented. Never place a real contract, medical record, excerpt, question, answer, model output, or identifying note here.

`development_suite.json` is the prompt-tuning suite for the disposable iOS harness. It contains:

- one fictional employment contract represented by ten excerpts;
- one fictional medical record represented by ten excerpts;
- 40 answerable cases, split evenly between legal and medical material; and
- 10 unanswerable cases, split evenly between legal and medical material.

Each resolved excerpt is 150–400 words. The names, identifiers, dates, diagnoses, treatments, events, and contractual terms are invented.

## Suite registry

| File | Purpose | Prompt | Status |
|---|---|---|---|
| `development_suite.json` | Development/tuning | `guardrail-v1` | Completed on iOS 26.5.2; results committed |
| `acceptance_attempt_1.json` | Acceptance attempt 1 | `guardrail-v1` | Ready for one authoritative run; must not be used for tuning |

The `guardrail-v1` prompt was frozen after the development run. Acceptance attempt 1 uses a new fictional residential lease and a new fictional medical record. It deliberately covers medication reactions, medical privacy, accommodations, and statements of permission versus evidence that an event actually occurred, without reusing development questions or expected answers.

Validate a suite from the repository root on Windows or macOS with PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\validate_guardrail_suite.ps1 -Path .\eval\guardrails\development_suite.json
```

## Acceptance lifecycle

Do not create an acceptance suite until the prompt is frozen.

1. Tune only against `development_suite.json`.
2. Freeze and version the prompt.
3. Generate a fresh acceptance suite with `purpose: "acceptance"`, the frozen `promptVersion`, and `acceptanceAttempt` from 1 through 3.
4. Use exactly 40 answerable and 10 unanswerable cases that were not used for tuning.
5. Run all cases once. Rerun every refusal or incorrect answer plus ten randomly selected passing cases.
6. If tuning resumes, retire that acceptance suite permanently. Never recycle it as a future gate.

The initial run determines the numerical score. Reruns test repeatability and do not erase an initial failure.

## Private material

Private cases are entered only through the harness's ephemeral private screen. They do not use this directory or the fixture JSON format. Only aggregate, de-identified results may be recorded, and those records must never contain excerpts, questions, expected answers, or generated responses.
