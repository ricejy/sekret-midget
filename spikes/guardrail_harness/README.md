# Guardrail Harness

> **Disposable spike.** This is not the production Sekret Midget app. Its job is to decide whether the product may proceed.

The harness calls Apple's on-device `SystemLanguageModel` using plain-string generation and `.permissiveContentTransformations`. It contains no network client, analytics SDK, crash reporter, feedback upload, database, or production document pipeline.

The bundled development suite is [`eval/guardrails/development_suite.json`](../../eval/guardrails/development_suite.json). Every fixture in that file is fictional.

## Requirements

- A Mac with a stable Xcode release that includes the iOS 26 SDK or newer.
- The author's iPhone 15 Pro Max on a stable OS release.
- Apple Intelligence enabled with its on-device model assets ready.
- An Apple ID configured for device deployment in Xcode.

No third-party dependency or package manager is used.

## Build on the Mac

1. Pull the repository and open `GuardrailHarness.xcodeproj`.
2. Select the **GuardrailHarness** target, then **Signing & Capabilities**.
3. Select your development team. If Xcode reports a bundle-ID collision, replace `com.ricejy.sekretmidget.guardrailharness` with a unique local identifier.
4. Select the physical iPhone 15 Pro Max as the run destination.
5. Run **Product → Test** and confirm the `GuardrailHarnessTests` suite passes. These tests keep the in-app importer aligned with `validate_guardrail_suite.ps1`, including domain distribution, excerpt-domain matching, excerpt length, sensitive-topic labels, and latency statistics.
6. Confirm the project compiles before changing the prompt or fixtures.

For an authoritative run:

1. In **Product → Scheme → Edit Scheme → Run**, set **Build Configuration** to **Release**.
2. Install and launch once while connected so Xcode can complete device deployment.
3. Confirm the harness reports the model as **Available**.
4. Stop the Xcode session, disconnect the Mac, enable airplane mode, and relaunch the installed app directly on the phone.
5. Run and grade the suite. Export only fictional results.

Debug runs, simulator runs, and Mac runs are development conveniences; they do not pass the gate.

## Synthetic workflow

The app loads the committed development suite automatically. It creates a new `LanguageModelSession` for every case and shows the fictional excerpt, question, expected answer, generated output, automatic outcome, and latency. The user assigns the authoritative manual grade.

After the initial pass, **Prepare required reruns** selects every failed case plus up to ten random passing cases. The initial grades supply the acceptance score; reruns expose repeatable failures.

The result exporter is available only for suites whose JSON declares `fictional: true`. Save exported synthetic result JSON under `eval/guardrails/results/` if it should become repository evidence.

## Private workflow

Use the **Private** tab only after synthetic acceptance passes:

- five cases from a real contract;
- five cases from a real medical document;
- zero refusals;
- at least eight correct answers; and
- zero invented answers.

Enter one local excerpt and question at a time. The private tab cannot export. Saving a grade clears that case's text and response. Backgrounding clears the entire private session, its detailed content, and its in-memory aggregate. The app also obscures itself in the app switcher and disables third-party keyboard extensions.

For the permanent record, manually write only aggregate counts, latency, stable OS/model version, prompt version, and de-identified failure categories. Never record private excerpts, questions, expected answers, or generated responses.

## Known verification boundary

The project is prepared on Windows but cannot be compiled or device-tested there. Xcode compilation on the Mac is the next required verification step. Apple evolves Foundation Models APIs across SDK versions; if the stable SDK reports a compile-time API change, adjust the isolated harness and record the exact SDK/OS version with the result.
