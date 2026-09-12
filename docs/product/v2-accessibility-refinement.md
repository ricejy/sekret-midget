# Accessibility and visual refinement

Issue #28 audits the approved Variant A interface without changing the local-only
product scope. Work starts from merged PR #39 (`cacbd8e`). The regular vault and
the owner's local Xcode signing configuration must remain untouched.

## Initial code audit — 2026-09-11

These are code-inspection findings, not a completed physical accessibility audit.

| Surface | Finding | Planned treatment |
| --- | --- | --- |
| Chat history | Cupertino list tiles inherit one-line titles/subtitles; deletion is swipe-only. | Wrapping titles and an explicit accessible delete action that preserves Undo. |
| Source selection | Same one-line tile constraint; selection state exists but the row needs an explicit button role. | Wrapping source rows with an unambiguous selected state and action. |
| Chat composer | Mode segments have a 28-point native minimum; source chips can grow arbitrarily wide; the composer has no height budget under large text/keyboard/landscape constraints. | At least 44-point actions, adaptive mode layout, bounded source labels with full semantic names, and reachable controls under constrained height. |
| Preview | Search, view choice, captured passage, and page controls surround an Expanded viewer without a shared height budget. | Keep both controls and content reachable with keyboard and accessibility text sizes. |
| PDF search | The dependency's search-result navigation calls ensureVisible with a default 200 ms animation. | Respect Reduce Motion for app-initiated search navigation. |
| Chat answers | Headings are visually styled but not marked as semantic headings. Source chips repeat their visible text in an additional semantic label. | Heading navigation and a single source announcement. |
| Knowledge Base | Rows already wrap and expose non-swipe actions; states are text, not color alone. | Verify large catalogues, long metadata, state announcements, and keyboard-safe filtering. |
| Settings / onboarding | Scrolling layouts and wrapping action labels already exist; current snapshots cover 2× text only. | Expand coverage to accessibility text sizes and dark appearance; inspect destructive confirmations and the lock screen. |

The list-tile and segmented-control constraints above were confirmed in the
installed Flutter 3.44.9 implementation. Existing icon-only Cupertino buttons
already provide semantic labels. The prior keyboard dismissal and Photos picker
fixes must remain intact.

## Implemented changes

- Wrapping history and source-selection rows with native buttons. Chat history
  exposes a Delete button in addition to swipe; Undo remains available and is
  announced as a live status above the list.
- Mode/view choices retain native segments when labels fit, with a 44-point
  minimum height. Long labels stack without truncation. Reduce Motion uses
  stationary choice buttons with explicit selected state and checkmarks.
- Chat, history, source selection, catalogue, paste import, and Preview reserve
  space for content. Toolbars become independently scrollable under constrained
  height instead of overflowing with a keyboard or large text. Preview page
  navigation now sits with the other controls above the viewer.
- Source chips bound the visible title while retaining a full semantic name and
  a separate visible processing state. Duplicate spoken chip text is removed.
- Answer/Settings headings expose heading semantics. PDF search navigation uses
  zero-duration scrolling with Reduce Motion enabled.

## Verification approach agreed with owner

The owner chose manual screen-level regression testing and requested a numbered
guide. This overrides the proposed TDD screen-test workflow. No new automated
screen tests, screen-test runs, or agent-driven UI validation are part of this
pass. Static analysis and compilation are still performed. Existing historical
test results must not be described as verifying these changes.

The owner followed [the manual walkthrough](v2-accessibility-manual-guide.md)
and reported all 14 numbered checks passed on 2026-09-12. These are owner-reported
physical review results, recorded separately from build checks.

The separate `lib/evaluation/accessibility_acceptance_main.dart` entry point uses
the production v2 screens and native capabilities with an isolated
`Application Support/accessibility-acceptance/sekret-accessibility-acceptance.sqlite3`
vault. On first launch it seeds 12 fictional sources and 6 chats, including long
titles and a static sample answer with headings, a wide table, and code. It shows
the TEST DATA banner and never opens the regular or earlier Settings-gate vault.
Fixtures are not reseeded after onboarding/Erase All. The existing sandbox-purge
no-op for isolated acceptance runs remains unchanged.

## Physical review and build results

Build checks on 2026-09-11: static analysis passed with no issues; the isolated
iOS Release acceptance build compiled, installed, and launched successfully on
the owner's iPhone. No automated test suite or screen-level test was run by the
agent. On 2026-09-12, the owner reported all 14 manual checks passed, including:

- VoiceOver traversal, labels, selected states, headings, status announcements,
  and access to actions without swipe gestures.
- Largest Dynamic Type sizes, light/dark appearance, contrast, and touch targets.
- Reduce Motion, rotation with keyboard open, draft preservation, and app locking
  while sheets or previews are visible.
- Long chat/source titles, many selected sources, large catalogues, long answers,
  unavailable citations, and all loading/error states.

This ticket is not the final release/privacy gate. Offline workflow, traffic
capture, retrieval/guardrail reevaluation, and aggregate release evidence remain
in #29. #28 is ready for PR preparation; it remains open pending the PR workflow
and CI results.
