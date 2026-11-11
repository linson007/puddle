# Manual regression and website parity — 11 November 2026

**Public release remains on hold.** This pass adds real local-model and native UI
evidence to the [earlier regression report](release-regression-2026-11-11.md).
It does not accept a signed distribution artifact or close the remaining gates
in [readiness tracker #85](https://github.com/linson007/puddle/issues/85).

## Environment and boundaries

- Base application: `ab4000c`, including the draft-lifecycle fixes merged in
  [PR #100](https://github.com/linson007/puddle/pull/100).
- macOS 26.6 (25G72), Apple M5 Pro, 48 GiB RAM, Xcode 27.2.
- Separately identified, ad hoc signed debug app with a disposable encrypted
  workspace. All task, mail, calendar, meeting and document content was synthetic.
- Google/Microsoft provider responses and writes used the app's isolated UI-test
  transport. No personal provider credentials or real mail sends were used.
- AI replies were real streaming requests to the installed Splash server at
  `http://127.0.0.1:8000/v1`, using Qwen3.8-27B-4bit, revision
  `10c35caafbb80f7dc6a7a432cdd11af10a6d4818`. Puddle used an 8K context budget.
  No new model was downloaded. The server was stopped after testing, restoring
  its initial state.
- Website baseline: the published GitHub Pages site. Updated site: local HTTP
  preview in Chrome and Safari; Chrome desktop and approximately 400 CSS pixels wide using 300%
  browser zoom. This is responsive-layout evidence, not physical iPhone testing.

## Native walkthrough

| Flow | Observed result |
| --- | --- |
| Task capture and lifecycle | Blank commitment could not save. Created “Review manual regression checklist”, owner Alex and notes; prioritized, completed, filtered and reopened it. Reopening cleared its daily star. Task and owner survived restart. |
| Memory | Saved “Manual QA preference”; title and content survived restart. |
| Navigation | Expanded More, pinned Calendar, switched to Developer profile; shared work remained available. Calendar pin survived restart. |
| Calendar | Opened cached agenda; reviewed exact synthetic event creation, observed completed provider receipt, reviewed undo and observed its completion. |
| Mail | Opened a synthetic unread message without changing provider read status. Reviewed exact reply recipient/body, dispatched to the fixture transport and observed its completed receipt. |
| Meeting drafts | Created and edited notes, attempted Quit, chose Keep Puddle Open and retained edits. Saved; after a normal quit/relaunch, title and full notes were intact. |
| Guided local AI | Reply and tool-calling verification both passed against the real local model; connection saved and reported ready. |
| Tool round trip | Model called Read tasks, received the saved task and answered with its correct next action and owner Alex. Initial run: 19.6 s total, 10.3 s first streamed text; fixed-app repeat: 15.6 s total, 13.8 s first streamed text. These are single observations, not performance budgets. |
| Reviewed model action | Asked for a synthetic reminder, inspected approval and declined it. Declined receipt appeared; no task was created. |
| Developer session and privacy | Saved problem/findings. Edited findings with a distinctive private-only string, ended private mode and reopened the saved session; original findings remained and private text was absent. |
| Backup | Exported a passphrase-encrypted synthetic backup, opened restore preview and merged into the same workspace. Preview reported zero additions; no duplicate work or replayed actions appeared. |
| Knowledge and permissions | Selected a synthetic folder. Indexing waited on the macOS file-access prompt; the user chose Allow. Indexing then completed with one document and zero unreadable items. Search found the expected passage. Real model answer cited the file/line and correctly named Alex as rehearsal owner (14.1 s total, 12.1 s first streamed text). Permission-denial behavior was not tested. |
| Offline recovery | Stopped the model server, submitted a prompt and observed an actionable connection error with Retry. Restarted server and retried; the response was READY (6.2 s). Prompt/history were retained. |
| Routines | Created “Manual QA paused brief”; it appeared with its enable checkbox off. No schedule was activated. |
| Optional workspace states | Inspected disconnected Browser setup and empty Work Context. Did not install a driver or grant recording permissions. |

## Defect found and fixed

**P2 — tool activity crossed session boundaries.** A fresh private chat displayed
the previous conversation's “Tools: Create a reminder” status. Private tool status
could likewise remain in the normal workspace after ending the private session.
Message receipts were separate and should remain attached to their messages.

`stopAI()` now clears the transient `toolActivities` list when it cancels a turn.
A new privacy regression failed both entry/exit assertions before the fix and
passes after it. The rebuilt app was also tested with a real Read tasks call:
private entry showed an empty chat without the previous footer; another private
tool call followed by End Session restored normal history without private status.

## Website comparison and changes

The published preview had a flat sidebar that omitted the current More groups,
pinning, utilities and several native workspaces. Screen titles and task counts
also differed from the app. The website now follows the current native structure
and system typography while retaining its existing product-site styling.

| Mismatch | Update and manual verification |
| --- | --- |
| Outdated navigation | Primary Today/Puddle/Tasks/Memory; grouped optional workspaces, profile-specific Developer, working pin/unpin, Connections and Settings. Navigated Calendar and Developer; Personal switch returned from Developer to Today. |
| Static/inconsistent tasks | Page-local capture, Open/Waiting on/Completed filters, completion/reopening, open count and three-priority limit. Completed/reopened a task and created a title containing literal `<sample>`; text remained escaped and count updated. |
| Missing native workflow cues | Current native screen headings, editable/savable meeting notes, agenda/week switch, workspace search and exact-content sample reply review. Exercised each; Escape dismissed the review and returned focus to its trigger. The sample never sends email. |
| Tiny narrow-screen preview | Readable controls, stacked navigation/utilities and scrollable content. At approximately 400 CSS pixels, mobile page navigation opened/closed and preview controls/content remained within the viewport. |
| Setup and release copy | Distinguished macOS runtime from build SDK requirements, corrected Outlook documentation link, and stated source-evaluation/public-release hold. Web fonts load without blocking the system-font fallback. |

Safari also passed task completion, waiting-on owner validation and successful
save after adding the owner. A fourth priority was refused with an explanatory
message. Feature-directory search rendered all 24 features and its no-results state.
All preview data stays in page memory and resets on reload; visible copy explains
that controls change only this sample. No accounts, models or device settings are
connected by the website. State handling is isolated in `website/dist/preview.js`.

## Engineering verification

| Check | Result |
| --- | --- |
| New privacy regression before fix | Two expected assertion failures reproduced the session-boundary leak. |
| `make verify` | Guards passed, including 36 Python tests; debug discovered 614 Swift tests, 588 passed, 26 expected opt-in skips, zero failures. |
| Full release Swift suite | 610 discovered, 584 passed, 26 expected opt-in skips, zero failures. |
| Final debug app | Built, ad hoc signed, relaunched and manually verified as above. |
| Final release app | Build and bundle verification passed, including strict signature/resource checks and refusal of fixture arguments/marker-only launches. Developer ID/notarization are separate. |
| Website checks | Both scripts parsed; unique HTML IDs, fragment/asset/SVG references and local HTTP asset responses passed. Desktop and narrow-layout manual interactions passed within the scope above. |

Local logs and synthetic state are retained only in the ignored
`build/manual-e2e-2026-11-11/` directory. The earlier disk-full/load evidence is
described in the previous report; those opt-in profiles were not repeated for
this transient-status and website change.

## Remaining must-haves

The existing release gates stay open: named release/support owners and recovery
rehearsal; an immutable Developer ID-signed/notarized candidate with clean install,
upgrade/rollback and artifact-bound acceptance; all advertised model/provider
combinations; designated live OAuth/provider accounts; signed browser-helper
acceptance; microphone/system audio, notifications, sleep/wake and Keychain
behavior; supported-OS runtime and keyboard/VoiceOver acceptance; real historical
workspace migration/recovery; and minimum-hardware/endurance budgets.

One installed model on this Mac and synthetic provider writes do not close those
gates. Actual iPhone coverage and full accessibility acceptance remain pending. Chrome's computer-use surface stopped responding during final window
cleanup; its process was left intact to preserve the user's existing tabs.
