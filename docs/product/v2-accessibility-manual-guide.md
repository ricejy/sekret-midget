# #28 — iPhone manual review

Use the new **TEST DATA** build. These are instructions and expected outcomes,
with results recorded separately below.

**Review result — 2026-09-12:** the owner reported all 14 numbered checks passed.
No agent-driven screen-level tests were run.

## Before you begin

- This build has a separate fictional vault: 12 sources and 6 chats. Your regular
  vault and the previous Settings acceptance vault are not opened.
- Use only non-sensitive photos and PDFs. Do not uninstall Sekret or reset its
  production data. Do not choose Erase All until the final check below.
- Keep a note of your current text size, appearance, and motion settings so you
  can restore them afterward. Disable portrait-orientation lock for rotation.
- If the TEST DATA banner or fresh onboarding is missing, stop and tell me.
- Large controls may stack; toolbars may need their own vertical scroll. That is
  intentional. Hidden/unreachable actions, overlapping text, or lost drafts are
  failures. A long navigation-bar title may shorten; full titles must remain
  readable in the catalogue/history or Source information.

## Walkthrough

### 1. Onboarding at large text sizes

Before continuing past onboarding, open iOS Settings → Accessibility → Display &
Text Size → Larger Text. Enable Larger Accessibility Sizes and move the slider
to the largest size. Return to Sekret and scroll from top to bottom. All
explanations and readiness/Face ID/Continue actions must remain reachable.
Switch to Dark appearance in iOS Settings and inspect again. Restore your normal
text size, then continue. App lock can stay off until step 12. Apple's
[larger-text instructions](https://support.apple.com/guide/iphone/make-text-easier-to-read-iph3c076905a/26/ios/26)
describe these controls.

### 2. Baseline visual pass

Open Chat, Knowledge Base, and Settings in light appearance, then dark appearance.
Scroll each screen to both ends. Check readable text/icons, clear separators,
visible enabled/disabled controls, and a consistent native appearance. Nothing
should require guessing from color alone. In Chat history, reopen the fictional
acceptance chat if needed: its fixed sample answer contains headings, a table,
and code. Scroll the table/code horizontally and use Copy code.

### 3. Chat keyboard, drafts, and rotation

Start a new chat. Type `Draft for the Bluebird review` without sending. Tap the
blank transcript: the keyboard must dismiss. Tap Message and type again. Rotate
to landscape with the keyboard open, then back to portrait. The draft must stay;
the message field, Send, and modes must remain reachable (scroll the composer if
needed). Switch tabs and return: the unsent draft must remain. Send it once and
confirm exactly one General answer appears.

### 4. Chat history without swipe gestures

Open history. Read the long seeded titles and search for `saved chat 3`. Rename
that chat with the pencil button; Save and Cancel must both work. Clear search.
Use the trash button on a disposable seeded chat, then tap Undo above the list
**within five seconds**. It must return. Repeat once using swipe-to-delete and
Undo. Open a different saved chat and verify the intended chat appears.

### 5. Source selection and readable states

In a new chat, choose Knowledge Base mode → Select sources. Search for `archive`.
Select several long-titled sources, scroll, deselect one, and tap Done. Reopen the
sheet: the same choices must remain. Chips should show readable processing states;
long chip titles may shorten, but full titles must be readable in the selection
sheet. Wait for the selected sources to be Indexed before asking
`What day is the Bluebird review?` The answer must be labelled as source-based.

### 6. Catalogue, filtering, and pasted import

Scroll the 12-source catalogue. Search `green cupboard`, open a result, and inspect
the matching text. Return, clear search, and try type/state filters; return them
to All types/All states. Use a source's ellipsis menu to rename it, then cancel a
delete confirmation and ensure it remains. Add → Paste text, enter a long title
and fictional text, rotate with the keyboard open, and Import. The fields and
Import action must remain reachable; the item must appear once. Repeat the same
text to check the existing duplicate prompt still works.

### 7. Photos picker regression

Choose photograph: it must open **Photos**, not Files. Cancel once: no item should
be added. Reopen it and select a non-sensitive photo containing readable text.
Open its preview, pinch to zoom, switch to Extracted text, search a word, and open
Source information. A low-text image may correctly report that no searchable
text was found; failure/retry/delete controls must remain readable.

### 8. PDF preview and citation navigation

Import a non-sensitive multi-page PDF using Files. Open Preview, use the page
arrows **above the viewer**, search a repeated word, and try previous/next match.
Switch between Original and Extracted text; zoom the original. Rotate with the
search keyboard open. Controls and preview must remain usable. Ask a grounded
question about this PDF from Chat, expand Sources, and open a source card. It
must open the relevant source/page; OCR does not promise exact image highlighting.

### 9. Largest-text stress pass

Enable the largest accessibility text size again. Repeat steps 3–8 in portrait,
then the keyboard/rotation parts in landscape. Also inspect Settings, Rename,
source actions, and a destructive confirmation (Cancel it). Long titles must
wrap in lists. Mode/view choices may stack vertically. Toolbars must scroll
without preventing content scrolling. Record any clipped line, unreachable
button, or unexplained layout jump, including the screen and orientation.

### 10. VoiceOver

Use iOS Settings → Accessibility → VoiceOver. If unfamiliar, use VoiceOver Practice
first; enabling it changes touch gestures. Follow Apple's
[VoiceOver setup/practice guide](https://support.apple.com/guide/iphone/turn-on-and-practice-voiceover-iph3e2e415f/ios).
Keep volume audible and use fictional content only.

Navigate sequentially through Chat/history, source selection, Knowledge Base,
Preview, Settings, and a confirmation dialog. Check that:

- History, New Chat, Send/Stop, Rename/Delete, source actions, page/match arrows,
  and Source information have understandable spoken names and can be activated.
- A selected mode/source is announced as selected; changing it updates the state.
- Long source names are available, and chips are not read twice.
- Saved answer headings and Settings sections support heading navigation.
- Processing/status/error text is accessible; responding/interrupted states and
  the Undo notice can be heard without focus getting trapped.
- A confirmation exposes its explanation and Cancel/action choices, without
  traversing underlying content. Cancel it.

Report missing labels, repeated announcements, unreachable actions, or strange
reading order. Turn VoiceOver off when finished (or retain your preferred setting).

### 11. Reduce Motion and contrast

Enable iOS Settings → Accessibility → Motion → Reduce Motion, then return to
Sekret. Switch chat modes and Original/Extracted text; choice controls should not
slide their selection indicator. Move among PDF search matches; navigation should
not animate a long pan. Open/close history and dialogs and check for distracting
motion or lost state. See Apple's
[motion settings guide](https://support.apple.com/guide/iphone/customize-onscreen-motion-iph0b691d3ed/ios).
In both light and dark appearance, check that text remains legible and processing,
selection, errors, and deletion warnings are understandable without color alone.
Note any contrast concern; a visual pass is not a numeric contrast certification.

### 12. Interruption and lock regression

Set app lock to Immediate. With a chat, a source preview, and a destructive
confirmation visible in turn, enter the app switcher. Its card must conceal
content. Return, cancel authentication once, and verify the app stays locked.
Authenticate: no old destructive confirmation should reappear. At large text,
the unlock/error controls must still be reachable. Also start a long answer and
tap Stop (or background the app while it is responding): any incomplete response
must be clearly marked, and its actions must remain available.

### 13. Deleted-source citation and empty states

Keep a grounded answer with a source card. Delete that source from the catalogue,
reading the warning that chats retain derived information. Return to the answer:
the chat remains, but that card must say Source deleted and cannot open Preview.
Try searches with no matches in history/catalogue and inspect the empty states.
Do not delete all content until the last check.

### 14. Destructive controls — fictional vault only

Confirm the TEST DATA banner is still present. In Settings, open Delete all chats,
Delete entire Knowledge Base, and Erase all local data, **cancelling each first**.
At large text, read every warning and reach both action buttons. Finally, if you
are finished with the fixtures, choose Erase All, authenticate, and check that
Chat/Knowledge Base show empty states after relaunch. The test fixtures must not
reappear. Non-content lock/retention settings remain. This build deliberately
does not purge sandbox-wide picker copies belonging to earlier app data.

## Send results

Reply with `1 pass, 2 pass, …` and list failures/not-tested steps. For a failure,
include the step, appearance, text size, orientation, last few taps, and expected
versus actual behavior. Screenshots are useful only with fictional/non-sensitive
content. Do not send passcodes or private source text.

Restore your preferred iOS accessibility settings afterward. Leave the TEST DATA
app installed until review is complete; we will restore the regular app separately.
No PR is prepared until this review is accepted. #29's offline, retrieval, and
traffic-verification release gate remains separate.
