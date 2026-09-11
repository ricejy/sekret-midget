# Settings, onboarding, and app protection

Issue #27 completes the opt-in v2 Settings tab. The default launch remains v1;
`SEKRET_V2=true` still refuses an unrecognized v1 database without resetting it.
The displayed name is Sekret. Package, bundle, repository, and database names
are unchanged. No production data reset is part of this implementation.

## Behavior

- First launch explains local processing, checks model readiness, offers optional
  device authentication, and continues even when generation is unavailable.
  Import permissions are not requested during onboarding.
- Settings exposes specific model status/recovery, local-only privacy, retention,
  logical storage usage, deletion, app lock/delay, and allowlisted diagnostics.
- Retention uses the existing workspace preview and revision-checked confirmation.
  Complete chats are removed; summaries do not replace transcripts. Reaping still
  runs on launch/resume. Default retention remains manual.
- Schema 6 transactionally adds the onboarding flag. Existing chats, knowledge,
  retention, and protection settings survive upgrades from supported v2 schemas.
- App lock is optional. Enabling and disabling it both require a fresh device
  authentication. Cold launches always lock when enabled. Foreground returns use
  immediate, one-minute, or fifteen-minute delays; elapsed and wall time account
  for suspension/sleep, with backwards wall-clock changes locking conservatively.
- Authentication cancellation, missing bridges, platform failures, overlapping
  requests, and requests backgrounded before completion all fail closed. A native
  authentication prompt's inactive/resume transition does not create a lock loop.
- The native policy is Apple's `deviceOwnerAuthentication`, which permits normal
  device-passcode fallback. There is no app PIN, custom encryption, or app key.
  See [Apple's policy documentation](https://developer.apple.com/documentation/LocalAuthentication/LAPolicy/deviceOwnerAuthentication).
- `SceneDelegate` places an opaque native window above app content synchronously
  when resigning active. A separate Flutter cover includes the root navigator,
  dialogs, and accessibility. Snapshot concealment applies even with app lock off.
- A newly required lock dismisses root dialogs, hides the full interface, and
  stops generation/indexing. No content notifications are scheduled.

## Destructive actions

All three actions require an explicit irreversible confirmation. Erase All also
requires fresh device authentication, even when optional app lock is off.

The shell removes tab navigators, previews, drafts, and Undo surfaces, stops
generation/import admission, waits for active work, then performs deletion.
Resume/unlock cannot restart processing during this maintenance interval.

- Delete all chats includes staged Undo deletions and clears current-chat state;
  Knowledge Base originals/indexes stay.
- Delete entire Knowledge Base stops processing and deletes each source through
  the Knowledge Base. Retained chats may contain derived sensitive text; citations
  become Source deleted. The confirmation explicitly warns about this.
- Erase All removes all content-bearing vault records, rebuilds empty FTS data,
  and compacts the database. Non-content onboarding, retention, and app-lock
  preferences stay. SQLite secure-delete is enabled; this is not a claim about
  forensic erasure of OS backups, flash hardware, or content copied outside Sekret.
- iOS document-picker import copies are discarded after reading their bytes.
  Knowledge Base deletion/Erase All also purge picker Inbox directories. Cleanup
  is confined to descendants of the app's own temporary/Documents Inbox locations;
  provider originals and arbitrary paths are never removed.
- Errors are shown without paths or user content. Failed operations can be retried.

## Verification

Portable tests use real SQLite/workspace/Knowledge Base with deterministic native
adapters. They cover onboarding, unavailable-model access, persisted preferences,
schema migration, authentication failure/suspension/concurrency, exact lock-delay
boundaries, sleep/clock changes, confirmation cancellation, deletion scope,
in-flight generation/indexing, draft invalidation, root-dialog lock protection,
retention, and narrow/large-text/dark interfaces.

```sh
flutter analyze
flutter test
flutter test test/settings_accessibility_test.dart \
  --dart-define=WRITE_SETTINGS_SCREENSHOTS=true
flutter test integration_test/settings_ui_test.dart \
  -d 00008130-001E182A2190001C --no-uninstall
flutter build ios --release --no-codesign --dart-define=SEKRET_V2=true -t lib/main.dart
```

Screenshots go to `/private/tmp/sekret-settings-*.png`. The physical UI tests use
only in-memory fictional vaults and **fake authentication**. They do not prove
that Face ID/passcode or native snapshots work. Native XCTest checks the selected
authentication policy, diagnostic allowlist, and import path confinement.

The physical gate still requires actual enable/unlock/cancel/passcode fallback,
background/cold-launch lock behavior, and app-switcher checks with Chat, Preview,
and a destructive dialog visible. Use an explicitly isolated fictional vault or
an immediately confirmed v1-to-v2 transition; never erase the production vault
as part of automated checks. Restore the normal release app after integration
tests using `flutter run --release --no-resident -d <device> -t lib/main.dart`.

### Isolated manual gate

`lib/evaluation/settings_acceptance_main.dart` is a separate executable, not a
production launch option. It uses the real model/authentication adapters and
production v2 screens, but stores fixtures in
`Application Support/settings-acceptance/sekret-settings-acceptance.sqlite3`.
The `TEST DATA` banner identifies it. It never opens the regular vault. First
launch seeds one fictional chat/source; after onboarding, Erase All does not
reseed them on restart.

```sh
flutter run --release --no-resident -d 00008130-001E182A2190001C \
  -t lib/evaluation/settings_acceptance_main.dart
```

The isolated adapter delegates authentication/diagnostics to iOS but deliberately
does not perform sandbox-wide import-copy purging: that sandbox can still hold
older production copies. Native purge is tested separately against a uniquely
created fixture directory, including preservation of originals and symlinks.
Use only fictional pasted text or non-sensitive photographs in the manual gate.

1. Enable Face ID during onboarding and continue. Confirm Settings reports the
   actual local model and authentication capabilities.
2. With Immediate delay, leave and return: only the lock screen is accessible.
   Cancel authentication: it must stay locked. Then authenticate successfully.
3. Exercise the normal iOS passcode fallback, without sharing the passcode.
4. Inspect app-switcher cards from Chat, source Preview, and a destructive
   confirmation dialog. Only the opaque Sekret cover should appear. Returning
   through the lock must not restore a pending destructive confirmation.
5. Check one-minute delay before/after the threshold, and that fifteen-minute
   delay can be selected and persists. Force-quit/relaunch still requires auth.
   All exact delay boundaries, sleep, and backwards clock changes also have
   deterministic portable coverage.
6. Cancel Erase All authentication and check fixtures remain. Repeat, authenticate,
   and verify the fictional chat/source are gone, including after relaunch.
   Erase All deliberately keeps non-content lock/retention/onboarding choices.

## Current gate status — 2026-09-10

The physical lock/resume fixture originally stalled by requesting a frame after
simulating `paused`. A narrowed frame-scheduling assertion reproduced the cause;
Flutter's live binding disables frames in that state. The regression now checks
concealment during `inactive`, delivers pause/resume without pumping while paused,
then verifies the lock and dismissal of the root dialog. The isolated device
case passed in 13 seconds. Production lock behavior was not changed for this fix.

- Complete portable suite: 191 passed.
- Real-font Settings/onboarding snapshots inspected, including dark and 2× text.
- Static analysis: clean.
- Unsigned v2 iOS Release build: passed.
- Physical iPhone 15 Pro Max, iOS 26.6.1, USB: all 9 Settings UI scenarios passed
  in 1 minute 15 seconds, using `--no-uninstall` and fictional in-memory vaults.
- Physical native XCTest: all 22 tests passed in Release using the isolated
  acceptance entry point as host. Includes device-auth policy/diagnostics, real
  fixture-only import purge, path confinement, file protection, embeddings, OCR,
  and existing model bridge regression coverage.
- Owner confirmed all six manual authentication/snapshot/deletion checks passed.
  The new tests do not open or reset the production vault.
- Signed Release acceptance app installed and launched successfully; left on the
  iPhone after the owner's manual gate. The normal entry point remains unchanged;
  restore `lib/main.dart` when returning to the regular app.

### Owner-review follow-up

The owner reported two usability issues after passing the manual gate:

- Chat dismissed its keyboard only on drag or a mode-control action. The message
  field now explicitly unfocuses on an outside pointer release, so taps elsewhere
  dismiss it without moving controls before their tap finishes. Only the composer
  loses focus; answer selection remains independent.
- Choose photograph was wired to the Files adapter. iPhone now uses a dedicated
  `PHPickerViewController` bridge, filtered to a single image. Only the selected
  image's bytes/name are returned, with no full-library permission or app-owned
  temporary file. PDF selection remains Files; non-iOS demo fallback is unchanged.

Per the owner's explicit request, no automated tests or agent-driven UI testing
were run for these two follow-ups. The earlier recorded passing runs predate
these changes. The updated signed Release acceptance build compiled, installed,
and launched successfully on the owner's iPhone. On 2026-09-11 the owner confirmed
review of both follow-ups and authorized opening the PR. No further automated
test run was performed for these changes.
