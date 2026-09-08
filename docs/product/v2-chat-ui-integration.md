# Approved Chat interface integration

Issue #25 implements Variant A — Native Focus as native Flutter/Cupertino
widgets, not copied prototype HTML. `ChatScreen` takes the app-lifetime
`ChatWorkspace`, `KnowledgeBase`, and shared `ChatEngine`. SQL, retrieval,
grounding, context budgets, and persistence remain in those existing modules.
Navigation to the Knowledge Base, a citation preview, external links, and native
settings are explicit callbacks. The screen does not own or dispose the modules.

## Staged rollout

The v1 default screen and its evaluation entry points remain unchanged while
#26 (catalogue/preview) and #27 (Settings/protection) finish the v2 shell.
Opt in to the Chat shell on iOS with:

```sh
flutter run --release --dart-define=SEKRET_V2=true
```

`openChatApp` opens the existing `sekret-midget.sqlite3` filename with the v2
vault and explicit file protection. It **never** resets an unrecognized/v1
database. If the development phone still contains the v1 database, startup
explains that the transition needs separate confirmation. Disable the flag to
return to v1. Do not delete data merely to make this flag launch.

Knowledge Base and Settings destinations are explicitly unfinished landing
screens in this intermediate shell; their tickets supply the real controls.
The Add to Knowledge Base shortcut navigates there and does not import into
Chat. Existing v2 knowledge items can already be selected in Chat. This ticket
does not claim the whole v2 application is released.

## Chat behavior

- New Chat preserves the previous chat. Searchable history restores the current
  chat and supports rename, swipe-delete, and the workspace's five-second Undo.
  Unsaved composer drafts stay with each chat in memory, not across launches.
- Mode selection stays visible beside the composer. Each displayed answer uses
  its recorded mode, never the currently selected mode. Source chips expose
  readiness; the searchable multi-select screen permits preselection while
  indexing, but sending waits for every selected item to be indexed.
- Compact right-aligned user bubbles and full-width assistant text follow the
  chosen hierarchy. Streamed snapshots update in place. Scrolling follows the
  latest response only when the reader is already near the bottom; opening a
  chat moves to its latest turn. Keyboard metric changes keep that position
  visible without forcing a reader away from earlier text.
- Generation is globally exclusive. Stop remains available after changing
  chats, with an explanation that another chat is responding. Tab changes do
  not suspend generation. Failed, stopped, interrupted, unavailable, and exact
  insufficient-evidence outcomes remain distinguishable.
- Copy answer, text selection, original-provenance Regenerate, and confirmed
  Delete from here are available on retained turns. The last operation removes
  that turn and every later turn, not just the displayed assistant text.
- The subtle summary disclosure reads the workspace's existing saved summary;
  viewing a transcript never creates a summary or deletes earlier messages.
- Expandable source cards show immutable source title, page, section, and
  captured passage. Availability is rechecked when opening. Deleted sources
  retain their excerpt and show `Source deleted` without a preview action.

## Rendering and privacy

`AnswerContent` parses Markdown into native, selectable widgets. It supports
headings, emphasis, nested lists, block quotes, horizontally scrollable tables,
and copyable code blocks. It never renders HTML in a WebView or executes code.
Image syntax becomes text; no remote, file, or data image loads are performed.
Only absolute HTTP(S) links without embedded credentials can be opened. A tap
first shows the complete destination and an external-network warning; opening
requires explicit confirmation and uses the external browser. Nothing fetches
links automatically. The Markdown parser and link adapter are documented by
[Dart Markdown](https://pub.dev/packages/markdown) and
[Flutter url_launcher](https://pub.dev/packages/url_launcher).

`SourcePreview` is the citation destination shared with the upcoming catalogue:
selectable original pasted text, original PDF pages positioned at the captured
page, and pinch-zoomable original photographs. The captured passage is shown
separately. No unreliable geometric highlighting is invented. #26 expands
preview search, page navigation, metadata, and extracted-text controls.

The opt-in app shell serializes foreground/background lifecycle operations,
keeps generation alive across tabs, and obscures its content when inactive.
Full app-lock authentication and device privacy acceptance remain #27/#29.
System appearance and dynamically resolved secondary labels support light and
dark mode; the bundled Cupertino icon asset prevents missing-glyph controls.

## Verification commands

```sh
flutter analyze
flutter test
flutter test integration_test/chat_ui_test.dart -d <usb-device-id> --no-uninstall
```

The portable UI scenarios use the real workspace, vault, Knowledge Base, and
engine with deterministic native-capability adapters and fictional content.
They assert visible behavior and persisted outcomes rather than private widget
structure. Coverage includes history/drafts/rename/Undo, source readiness and
preview/deletion, global streaming Stop, unavailable recovery, message actions,
summary disclosure, interrupted/failure states, Markdown safety and explicit
links, large type/keyboard layout, text previews, and dark-mode abstention.

The physical-device entry point reuses the scenarios with the real display and
keyboard geometry. It does not open the user's production database. As with the
previous integration tests, keep the device unlocked and connected by USB and
use `--no-uninstall` to retain app data. Restore the normal app build afterward.
These deterministic scenarios do not measure real Apple-model answer quality.

On 2026-09-08, all 11 UI scenarios passed on the target iPhone 15 Pro Max
(iOS 26.6.1) over USB. Two additional portable shell scenarios verify that tab
changes preserve generation, backgrounding obscures and interrupts it, and a
startup schema error is shown without resetting data. Light, grounded, and dark
screenshots were rendered and visually inspected with native fonts.

For optional local visual inspection on a Mac, system fonts can be loaded into
the widget-test renderer (ordinary tests use Flutter's deterministic test font):

```sh
flutter test test/chat_screen_test.dart --dart-define=WRITE_CHAT_SCREENSHOTS=true
```

This writes generated General, grounded, and dark screenshots to
`/private/tmp/sekret-chat-*.png`; it adds no system font files to the repository.
