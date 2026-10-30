# Verify the Puddle personal assistant

## Contributor checks without accounts or a model

From the repository root, run:

```sh
make test
sh scripts/swift.sh test -c release
make build
```

The default suite uses synthetic data and injected transports. It needs no
Splash server, provider credentials, signing identity, or macOS recording grants.
Some tests are intentionally skipped until their integration is configured:

| Opt-in | What it enables |
| --- | --- |
| `PUDDLE_LIVE_SPLASH=1` | Synthetic real-model evaluations against Splash at `http://127.0.0.1:8000` |
| `PUDDLE_CUA_DRIVER=/absolute/path/to/cua-driver` | Installed-driver MCP handshake/catalog check; `PUDDLE_CUA_LIVE=1` additionally starts a real dedicated browser session |
| `PUDDLE_LIVE_AUDIO_FILE=/absolute/path/to/synthetic-audio` | On-device speech recognition of a synthetic audio fixture on macOS 26+ |
| `PUDDLE_LOAD_TESTS=1` | Larger synthetic storage and performance workloads described below |

Features requiring macOS 26 also skip their corresponding tests on older systems.
Leave live opt-ins unset for ordinary changes. A passing fixture suite covers
application behavior under those fixtures; it does not establish model quality,
real provider behavior, permission delivery, or public-release readiness.

The [CI workflow](../.github/workflows/ci.yml) runs the default debug and release
suites on macOS 26, then builds and verifies an ad hoc release bundle without an
OAuth client file. For setup and contribution expectations, see
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Latest public-release regression

Latest [audio follow-up](live-browser-os-acceptance-2026-10-30.md#follow-up-with-selected-source-diagnostics):
**466 debug / 462 release tests passed**, zero failures or skips. The supervised
microphone phrase passed review/save/reopen. Selected-app audio remains an open
acceptance gate; a later source trace identified ChatGPT rather than the intended
audio fixture. The retry adds safe marked
fixture relaunch, silence-placeholder filtering and signal/recognition regressions.
The follow-up also fixes offline speech-asset reservation, displays the captured
application and rejects ambiguous app filters. Source-label lifecycle and
single-app policy regressions pass; live Audio A/B acceptance remains open.

The [live browser/OS follow-up](live-browser-os-acceptance-2026-10-30.md) records
browser startup/capability, tab inventory, review, native chat-layout and
speech-download pause corrections. Live browser reads/navigation and normal
reviewed input passed; changed-target/password-field checks failed the release
gate. Public distribution remains blocked pending the browser scope decision
and the remaining supervised OS/provider/release acceptance.
Original follow-up: **459 debug / 457 release tests passed**, zero failures or skips,
including live Splash, a real dedicated Cua session/read/navigation and load tests.
Eight cases were added. These counts do not close the failed manual gates.

The [security and AI guardrail pass](security-testing-2026-10-30.md) records
five findings and their corrections, malicious-model and document tests,
streaming HTTP limits, quarantine provenance, privacy-interruption regressions
and the public-release gates that remain open.
Final security pass: **451 debug / 449 release tests passed**, no failures or
skips, including live Splash, installed-driver catalog and synthetic load tests.

The latest [six-month load report](load-testing-2026-10-30.md) records the storage,
memory/context and UI improvements, three synthetic profiles up to 108,000
messages, and a 1,000-save endurance run. All opt-ins enabled: **429 debug and
427 release tests passed**, zero failures or skips. Native heavy-workspace
search, archive reopen, task save/restart and long-chat paging passed.

See [release-regression-2026-10-30.md](release-regression-2026-10-30.md) for the
original test results, corrections, feature coverage and remaining
public-distribution gates. The briefing accuracy finding is closed by the
[verified follow-up fix](briefing-regression-fix-2026-10-30.md): 408 debug and
406 release tests pass with all live opt-ins enabled. Native fixtures
support `--ui-test-empty` for a first-run workspace with no account or model;
they never reconcile real macOS notifications.

## Six-month load regression

Run the standard synthetic profile explicitly (normally skipped):

```sh
PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test -c release --filter WorkspaceLoadTests
```

Select the archive-heavy profile or the single long active conversation:

```sh
PUDDLE_LOAD_TESTS=1 PUDDLE_LOAD_PROFILE=heavy sh scripts/swift.sh test -c release --filter WorkspaceLoadTests
PUDDLE_LOAD_TESTS=1 PUDDLE_LOAD_PROFILE=long PUDDLE_LOAD_ITERATIONS=1000 sh scripts/swift.sh test -c release --filter WorkspaceLoadTests
```

The default is 100 saves; the iteration override is bounded to 20–1,000. Every
save updates a task and appends a reply. Assertions cover retained transcripts,
late-history search, prompt bounds, memory updates, backup/restore idempotence,
P95 save latency below 100 ms and resident growth after warmup below 64 MiB.
`PUDDLE_LOAD_SAVE_BUDGET_MS` can set the latency threshold for another machine;
record the override with the results. `PUDDLE_LOAD_OUTPUT_DIRECTORY` writes
metrics JSON, and `PUDDLE_LOAD_RUN` labels it. `PUDDLE_LOAD_EXPORT_FIXTURE=1`
also writes a large synthetic JSON fixture with owner-only permissions.

The debug-only native harness accepts `--ui-test-seed <absolute-synthetic-json>`
with `--ui-test-workspace <new-disposable-directory> --ui-test-empty`. It uses
isolated credentials and disables notifications, learning and account polling.
Release builds reject the workspace flag. Never use a personal workspace as a
fixture. See the report for workload sizes, measured timings and known limits.

## Product-site UI alignment (30 October 2026)

The native workspace now shares the product site's warm paper and forest
palette, with adaptive dark colors, outlined cards and clear primary actions.
Today places priorities beside the upcoming agenda at wider sizes and stacks
them beside the assistant panel. Past events remain available through **Show
full day**. Mail and Calendar headers stack at narrower widths; reading-pane
actions wrap into rows.

Native checks passed for task quick capture with Return, click-to-edit and
save, daily priority toggling, completion and the Completed filter, search
empty states and clearing search, a demo conversation starter, the full-day
agenda toggle, and Mail beside the contextual assistant. Light and dark
appearance were visually inspected with synthetic workspaces. To reproduce
the dark check, add `--ui-test-dark-appearance` alongside the debug-only
`--ui-test-workspace <disposable-directory>` argument. This does not change
the Mac's system appearance.

Regression: 386 tests executed, 378 passed, eight opt-in tests skipped, zero
failures. Release bundling, strict ad hoc signature verification, plist lint
and whitespace checks passed. Provider writes and live audio were outside
this visual review.

## Automated checks

Run make test and make build. Tests use HTTP fixtures and in-memory credentials
to exercise the core implementations. They do not establish that a real Google
account or Splash engine is configured.

The [30 October native Cua report](cua-end-to-end-2026-10-30.md) records the
completed interactive flows, fixes, rebuild checks and remaining acceptance.
It also documents the explicit debug-only isolated workspace for repeating
native tests without personal credentials. Final regression for that run:
373 tests executed, 365 passing, eight opt-in skips, zero failures.

Core tests cover extractive memory validation, mixed introductions, stable memory
identity, legacy settings, corrupted state recovery, future-version protection,
stream fragments, incomplete tools, shared token refresh cancellation, Gmail
history and cache reuse, Calendar pagination, and bounded read retries. App-store
tests inject persistence, transport, credentials, and reminder scheduling to test
failed writes, blocked startup, late replies, and task changes without real accounts.

For opt-in real-model evaluations, start Splash at `http://127.0.0.1:8000`, then run:

    PUDDLE_LIVE_SPLASH=1 sh scripts/swift.sh test --filter LiveEvaluationTests

These checks use synthetic facts and tool results. They do not sign into Google,
save live app state, or schedule real reminders. Model behavior can vary; review
failed outputs alongside the model version. Existing name and memory recall
checks can also be run with `PUDDLE_LIVE_SPLASH=1 make test`.

## Native app without a Google account

1. Open Puddle. Confirm the main screen is **Today**. Open **Puddle** for the
   conversation and **Message Puddle** composer. Tasks, Memory and Connections
   remain available. No Gmail sign-in is required.
2. Connect Splash in Settings → Local AI. Ask a general question, or request
   writing/planning help. Confirm a local model reply.
3. Say “My name is Mira” and “I prefer concise replies.” Confirm there is no
   memory approval dialog and both facts appear in Memory. Say “Don’t remember
   this: I prefer long replies”; confirm the saved preference is unchanged.
4. Say “My name is Li. I like tea.” Confirm the name is Li and the preference is
   captured separately. Disable automatic learning, state another preference,
   and confirm no memory changes. Re-enable it when finished.
5. Open History before choosing New Conversation. Confirm the saved active chat
   appears with a Current label and can be searched and reopened. Start a new
   conversation, then switch between both chats; entries should not duplicate.
   Confirm memory and tasks remain. Restart and check both conversations again.
   Copy a reply, reuse a user message as a draft, and inspect retry tool receipts.
6. Ask for a reminder with a clear future time, approve it, and inspect Tasks.
   Enable notifications. Quit before the due time and verify macOS delivers the
   scheduled notification. Relaunch and verify one chat reminder with no second
   desktop alert. Also test completing, editing, deleting, and snoozing a reminder.
7. Quit and reopen. Confirm persistence and that archived history remains.
8. Stop Splash and ask another question. Confirm a useful error and readable
   conversation history. Restart Splash and retry the message.
9. During a slow reply, choose Stop and New Conversation. Confirm streamed text
   stops and no late reply is inserted into the new chat. Inspect timing fields
   on completed replies using a fixed prompt and model when comparing latency.

For an isolated walkthrough, use make demo or **Explore the demo**. Tool choices
and replies are labeled fixtures. Try the Memory and Reminder starter prompts;
reminder approvals and local state updates use the app’s real logic.

## Mail, Calendar and grouped navigation

1. Check Main (Today, Puddle), Work (Tasks, Calendar, Mail, Meetings), Workspace
   (History, Memory, plus Developer for Developer profiles), and pinned Connections/Settings. Resize to
   960 × 640 and scroll navigation; all destinations should remain reachable.
2. Open Mail/Calendar without Google, and with only the other service granted.
   Each remains visible and offers sign-in or Manage Google Permissions.
   Cancel sign-in and retry. Check that a failed refresh retains cached content.
3. In demo, search Mail by body, sender or attachment name; combine search with
   Unread/Important filters and clear it. Select by mouse and keyboard. Check
   the reading pane, summary, and empty results. Reading must keep unread state.
4. Choose Create task, edit the title/date and cancel: no task should exist.
   Save a draft and check Tasks for its source link. Ask Puddle should open chat
   about the selected message, including after retry, without learning facts
   from the email. Real-model answer quality remains a live acceptance check.
5. In Calendar, change Today/Next 7 days, search, and select an event. Verify
   details, local time, all-day and overnight events, missing dates, empty
   results and the incomplete-results notice. Prepare opens local context;
   Meeting notes reuses an existing note for the same event. Use synthetic
   links in automated checks; an actual Join action opens a browser join screen.
6. With a real account, refresh each view independently, compare timestamps
   and content against Google, and disconnect during a refresh. Confirm the
   account cache clears and both views return to connection setup. Neither
   view should send mail, mark messages read, or edit Google events.

Automated fixtures cover cache search/filtering, all-day and overnight agenda
boundaries, daylight-saving changes, task-draft provenance, and exclusion of
email reference turns/retries from memory extraction. Provider authorization
and live-account compatibility still require the Google acceptance checks.

## Shared-workspace role profiles

1. On a fresh workspace, open the sidebar profile menu. Verify Personal
   and Developer. Manage Profiles should offer these approaches plus Custom.
   Select Developer: chat starters
   and Today's planning action should change while saved work stays visible.
   Developer should appear in the sidebar and menu bar only for Developer
   profiles. Open Developer, then switch to each other role: Today should open
   and Developer should disappear. Switching from chat or another shared page
   should retain that page. Repeat using the menu bar profile selector and by
   creating a profile or changing the active profile's approach in Manage Profiles.
   With an older workspace or backup, verify empty CXO/Product Manager/Researcher
   presets disappear and edited profiles retain their saved fields as Custom.
   A removed active preset must fall back to a remaining profile.
2. Edit Developer's goals and guidance through Manage Profiles. Switch to Personal,
   edit its context, then return. Each must retain its own values after restart.
3. Create a Custom profile, duplicate it, rename the copy, switch away and remove
   it. Only profile configuration may be removed. Duplicate names and empty or
   oversized names/guidance must explain the error and retain the editor draft.
4. Switch during a streamed reply and during a reminder approval. The reply
   must stop and approval must dismiss without creating a new task. Current
   chat and completed actions must remain. Retrying uses the selected profile.
5. With a supported local model, check that Developer guidance affects the
   response and that it does not claim filesystem or command execution access.
   New assistant replies should retain the producing profile's name.
6. Export and restore profiles through Backups. Review profile counts, duplicate
   name/ID behavior, current edited-profile precedence, default preset fill and
   repeated import. An older schema-4 single-profile backup should still restore.
7. Verify keyboard navigation, VoiceOver menu labels, minimum-height sidebar,
   long profile names and multiple app windows. Switching should keep a typed
   draft; cancelling an editor must not save changes.

Automated fixtures cover selection, migration, shared state, role prompting,
backup compatibility, failed writes, deletion guards and late-response/approval
cancellation. Earlier native CXO/Developer switching, shared content and restart
persistence passed on 30 October; exhaustive profile editing, multiwindow and
VoiceOver variants above still need acceptance.

## Cua browser control

Follow [Cua browser setup](browser-use.md) for driver installation and macOS
permissions. Browser is available under Workspace for every role. Start a
session explicitly, inspect a disposable public page, and ask the local model
to navigate, click, fill a non-sensitive field and scroll. Review the exact
destination/target/text in chat before allowing a change. Decline, retry after
an attempted action, switch profiles while awaiting approval, and stop during
an active operation. Check both browser state and Puddle's receipts. Restart
Puddle: browser control must remain disconnected. Demo must not operate Cua.

`CuaBrowserTests` and `BrowserWorkflowTests` cover synthetic MCP framing,
capability discovery, scoped sessions and tabs, current action refs, timeouts,
cancellation, approvals, failed intent saves, uncertainty and retries. The
optional installed-driver test checks real MCP negotiation and the tool catalog,
without reading or operating a page. It does not verify granted macOS
permissions or certify real-site/model behavior.

## Developer project acceptance

1. Select a Developer profile and open Developer from the sidebar. Connect a
   small repository through Choose Folder; verify its readable
   source list, saved context, reconnect behavior and restart persistence.
2. Find a path, search a literal string and open a matching line. Verify line
   numbers, paging, visible limits and incomplete-result labels. Common private
   paths and both file/directory symlinks must not open.
3. Compare Git status and working/staged diffs with the Git client. Test new,
   staged, unstaged, deleted, conflicting and non-text paths. The text comparison
   must not be represented as complete rename/mode review or test execution.
4. Create a session, edit each evidence field, switch projects/screens, then
   return and save. Force an injected cache failure: the draft must remain.
   Remove a folder connection: project files and saved/draft session evidence
   must survive without a grant. A stale editor must not resurrect the grant.
5. Use Save & Ask with a real local model. Verify saved-session and project tools,
   source references, source-based reasoning and honest limits. Switch project
   or profile during a read: obsolete output must not publish to the new context.
6. Export/restore sessions in an isolated workspace. Session content and former
   project names remain; no folder bookmarks or project grants may be restored.
   Repeating import must not duplicate sessions.
7. Run the optional synthetic-source model check:

       PUDDLE_LIVE_SPLASH=1 sh scripts/swift.sh test --filter DeveloperLiveEvaluationTests

   It uses a random value in a temporary source file; no user repository or
   connected account is read. The model must inspect source before answering.
8. Review keyboard/VoiceOver behavior, narrow windows, long paths, revoked/stale
   bookmarks, large repositories and cancelled folder dialogs on supported Macs.

Automated fixtures use actual temporary repositories and hostile path/credential
cases. They do not certify every Git configuration or OS permission workflow.

## Executive workspace acceptance

Use `make demo` for sample data; it opens Today with one priority, overlapping
calendar events and a flagged unread email. Demo remains in-memory and cannot
export or restore real backups. The following checks still require a native
interactive pass; passing fixture tests is not a visual acceptance result.

1. On an empty non-demo workspace with no model or account, save optional work
   context, capture a commitment, and restart. Confirm profile and work survive.
2. Edit a commitment into **Waiting on someone**, name an owner, choose a
   follow-up date, priority and notes. Search by owner/notes and switch between
   Open, Waiting on and Completed. Empty waiting owners must not save.
3. Star three commitments. A fourth must explain the limit. Complete one,
   choose another, then reopen the completed item: it must not regain its star.
   At the next local day, priorities clear while commitments remain.
4. Check overdue/today groups against actual times. Confirm known calendar
   overlaps, adjacent events, all-day/multi-day events and incomplete responses.
   Refresh timestamps must change only after successful reads; failed reads
   must retain the previous data and timestamp.
5. Open Prepare on an event. Review date, exact source, matching rule, saved
   agendas, decisions/questions and linked open actions. Edit a source note:
   stale extracts must not appear as current decisions. Open its workspace.
6. Add a meeting action as a waiting commitment with a reviewed owner. Confirm
   the source quote remains available from Tasks and from meeting preparation.
7. With a real supported local model, use Brief me on today and End-of-day
   review. Inspect the daily-brief receipt and compare claims with saved sources.
   Suggestions must not create tasks or contact owners. Repeat without Google.
8. In an isolated test workspace, export a backup. Review and merge it into a
   second isolated workspace. Current chats/edits/connections must remain;
   imported chats appear in History. Import twice: no duplication. Past reminder
   alerts must not replay; future reminders follow the current preference.
9. Corrupt a copy of the backup and review it: the current workspace must remain
   intact. Force a failed cache write using the injected persistence fixtures:
   the restore must report failure and allow a retry.
10. Review minimum-size windows, long titles/owners, keyboard-only navigation,
    VoiceOver, dark/light appearance, and all empty/loading/error states. Close
    an unsaved editor, cancel a panel and dismiss a restore review: no saved
    work may change.

The implementation run on 29 October 2026 attempted native demo review, but the
computer-use service failed to start its ScreenCaptureKit stream. No visual UI
pass or real-account/model/hardware acceptance is claimed for these features.

## Voice chat

In the built app, click the microphone and approve macOS microphone and speech
recognition access. Speak, choose Done, and verify the transcript becomes an
editable draft without sending. Existing draft text should be preserved. Cancel
a second capture and confirm no extra draft is added. Try navigating away while
listening and canceling while permission is pending; capture must stop.

Select a language without an installed on-device recognizer and confirm a useful
error rather than cloud transcription. Test Read aloud, Stop reading, automatic
reply playback, and voice speed. Starting voice input must stop playback so the
assistant does not transcribe its own spoken reply. Hardware and OS permission
behavior need interactive verification; automated tests use speech fixtures.

## Optional connections

### Work source acceptance

Automated `WorkConnectorTests` and `WorkConnectionWorkflowTests` use synthetic
provider/model responses and in-memory secrets. They cover repository/site
scope, OAuth discovery/PKCE/state, blocked write tools and hostile destinations,
JSON/SSE transport, refresh rotation/coalescing, expired-session recovery,
disconnect races, partial errors, source receipts, persistence failures, demo
isolation and secret exclusion. They do not sign in to real accounts.

Before release, follow [work connector setup](work-connectors.md) using test
accounts. Check a private and public GitHub repository, a missing scope and a
pending organization approval, token expiration/replacement, details with more
than five comments, a binary/large PR patch and head-commit checks. Verify that
an unconfigured repository is refused. For Atlassian, test each product alone,
both together, multiple sites, declined/cancelled consent, an administrator
block, refresh after expiry, restart and disconnect during an active read.
Search all sources with one disconnected/revoked service; retain successful
results and display the failure. Verify actual Jira and Confluence response
shapes against the live service, source links, read-before-answer tool receipts,
keyboard navigation, narrow windows and VoiceOver. Check exports contain no
connector credentials/configuration, and that disconnect leaves prior chats
intact. Revoke test grants/tokens at the provider after acceptance.

### Google acceptance

1. Follow [Google setup](gmail-setup.md) once as the app owner and build with the
   Desktop client. In the built app, **Connect Google** should open the system
   browser directly, without asking the user for JSON or Cloud setup. Confirm
   that cancellation allows a retry and that sign-in displays progress.
2. Approve Gmail, Calendar, or just one service. Confirm the Google account email
   is displayed even for Calendar-only access, and only approved tools are
   available. Use **Manage Google Permissions** to change access; previously
   cached data for services no longer granted should be cleared.
3. Ask a general question. Confirm no email/calendar retrieval unless relevant.
   When a tool runs, its name appears in the conversation.
4. Ask for unread mail or upcoming events and compare against the source.
5. With mail polling enabled, send yourself a message from another client and
   verify one new arrival, with no duplicate notification after the next check.
6. Inspect Summarize on a cached message and source links on tool receipts.
   If Calendar has more than fifty events, confirm the partial-result notice;
   ask for a shorter window.
7. Disconnect Google during active work. Confirm cached connection data clears while conversation,
   memory, and tasks remain usable.

Calendar tools read events without editing them. Local reminders are distinct
from Google Calendar events. Live authorization needs your browser interaction;
fixture tests do not bypass it.

## Meeting access

Use synthetic links and the injected URL opener in automated tests; tests must
not attend real meetings. With an invitation you intend to join, verify that
Meetings recognizes the provider and Open join screen opens its pre-join page.
Joining remains an explicit action in that provider. Verify Calendar conference
links and pasted links, and confirm unsupported schemes and lookalike domains
are rejected. Demo join controls must remain disabled.

### Meeting search and export

Search for words in a title, participant list, note, transcript, and action.
Check accent/case matching and combined query words across fields. Edit a
transcript without saving and search for the new text; the saved text must not
replace the draft in results. Changing or clearing a query must retain the
selected note and its draft.

Export the current draft in each format to a temporary destination. Confirm
full-transcript exclusion, join links excluded by default, explicit inclusion,
and stale-summary labels. Cancel the save dialog: no file should be written.
Export over an existing disposable file and inspect the complete result. JSON
uses an export envelope with ISO 8601 dates. Automated tests cover source
preservation, filename handling, Markdown escaping, transcript fences, export
options, atomic writes, and file permissions.

### Google Meet browser attendance

Use **Check browser setup** first. It runs the Chrome protocol commands on
`about:blank`, verifies a simple evaluation and confirms the test tab is absent
after closing. It never navigates to Meet, signs in or joins a call. The result
includes the Chrome product/version or the failed command, protocol code and
bounded reason. This check is disabled during active/uncertain attendance,
Demo, external pause, a private session or app lock. A successful setup check
does not establish that Google's current page layout or admission flow works.

Use a disposable Meet conference and an account/guest permitted by its host.
Choose Join Google Meet and confirm a separate Chrome profile opens. Sign in
yourself if prompted. Camera and microphone must remain blocked. Test direct
admission, Ask to join with delayed approval, denied admission, and sign-in
requirements. Waiting must never be labeled Joined. Verify a guest name is
filled only when the guest form is offered; authentication fields must not be
filled or submitted by the assistant.

Choose Leave and confirm only the managed tab closes. Close its Chrome window
or disconnect the local control connection mid-call: Puddle must show an error
and must not claim a verified leave. Quit while joined and confirm it attempts
to leave; a failed verification must display the quit dialog. An existing Meet
tab in the dedicated profile must prevent a second session. Puddle's regular
Chrome profile, Gmail OAuth session, and Calendar data must remain separate.

Cleanup verifies the owned target is absent from a fresh target list, including
when the close command reports that the target was already removed. A success
reply with the target still present, a lost creation reply, malformed evidence
or a disconnected browser must remain uncertain. Cancellation during creation
must wait for its returned identity, close only that tab and never navigate it.
Concurrent leave requests share one cleanup. Do not acknowledge manual closure
until the dedicated tab is actually closed.

Automated tests use injected browser commands, a synthetic protocol transport,
and JavaScriptCore DOM fixtures. They cover denied media permissions before
navigation, controlled origins, guest-name serialization, in-call detection,
sign-in/admission states, owned-tab cleanup, cancellation, timeouts, malformed
responses, and Demo restrictions. They do not join a real Meet call or prove
compatibility with every version of the live Meet UI. The native UI connection
was unavailable during this continuation, so live browser and permission
verification remain manual.

### Live transcription

Use the built app on macOS 26+ with a supported installed speech language.
Install speech language must download assets only after the button is chosen.
In a synthetic test note, choose Microphone and Start transcription, then speak
an agreed test phrase. Check the active indicator, elapsed time, and provisional
text. Stop, review, append, save, and reopen. Confirm the previous transcript
was preserved. Deny microphone permission in another test and check the error.

For app audio, choose Meeting app audio and select a test application in the
macOS sharing picker. Play a controlled test clip. Confirm only the selected
app's audio is transcribed and microphone permission is not requested. Repeat
with Meeting app + microphone using headphones; check both channel labels and
chronological timestamps. Cancel the picker, change notes, leave Meetings,
unplug the input device, and stop sharing through macOS; capture must end and
retain recognized text. No real meeting or private audio is needed for these
checks. OS permission prompts must be handled by the user.

Automated tests use synthetic PCM and CMSampleBuffer audio and injected capture
sessions. They cover format conversion, buffer lifetime, clock alignment,
bounded queue overload, provisional replacement, cancellation, late callbacks,
duration and finalization deadlines, deletion, Demo restrictions, and explicit
apply/save. Real permission dialogs, speech model downloads, and recognition
accuracy are manual checks.

### Summaries and transcript import

For summaries, use a synthetic note with an explicit decision, an action with
an owner and relative deadline, and an unresolved question. Save, then generate.
All extracts must be exact source quotes. Review classification manually. Change
the source while generation runs: the previous summary must remain. Cancel must
not save a partial result. Editing a source after a successful run must show the
out-of-date notice. Automated tests cover quote validation, Unicode context
budgets, both source fields, failed saves, late results, and mode changes using
an injected model fixture. Live-model quality still requires manual assessment.

Use Review and add task on an action: Cancel must create nothing. Confirm the
task is undated until a time is selected, keeps its source quote, and links to
the meeting. Repeated clicks and regeneration must not duplicate the task.
Automated fixtures cover atomic failed saves, source changes, title and date
validation, regeneration, and deletion behavior.

For transcript import, use a synthetic `.txt`, `.vtt`, or `.srt` file. Confirm
the preview retains timestamps and speaker labels, Cancel leaves the original
text intact, and Append preserves the previous transcript. Save and reopen the
note. Empty, binary, unsupported, and oversized files must show an error without
changing the note. Automated tests exercise these cases without reading personal
meeting files.

## Recovery and notification checks

Use disposable test state for recovery exercises. The automated persistence
tests create and remove their own temporary directories. Verify that an unreadable
primary is preserved when a valid backup is recovered, that an unsupported newer
schema cannot be overwritten, and that failed writes do not acknowledge task
creation or reminder delivery. After manually restoring a blocked state file,
Settings → Assistant → Retry Loading State should restore normal editing.

Desktop notification delivery requires a built app, permission in macOS System
Settings, and an actual notification check while the app is quit. Fixture tests
verify scheduling inputs and app behavior; they do not establish system delivery
under Focus, sleep, or changed notification settings.

## Improvement acceptance matrix

The implementation record is [improvement-implementation.md](improvement-implementation.md).
Run these interactive checks with disposable state/accounts before public release:

| Flow | Acceptance |
| --- | --- |
| Guided Splash | No installed executable/Homebrew, unsupported hardware/OS, low disk/RAM, chosen path with spaces, canceled install/download, occupied port, server crash, chat-only model, wrong key, offline cached start, quit/restart without killing an independent server. |
| Review actions | Change each field/account after review; decline; grant/revoke scopes; fail disk before dispatch; interrupt after dispatch; inspect provider before resolving uncertainty. For Gmail/Outlook send only an explicitly reviewed test message. Confirm thread headers/Unicode/CC; accepted is not delivered. |
| Mail | Switch two accounts/providers while search/thread/attachment fetch runs; check cache isolation, revoked access, multi-page threads/partial limits, PDF/text/image and unsupported files. Snooze/bring back/reminder, explicit VIP reason, supported/unsupported newsletter headers and server refusal. |
| Calendar | DST/timezone/all-day/overnight/overlaps; up to ten calendars, partial results, revoked scope, candidate buffer/work hours; reviewed create/edit then undo; concurrent provider edit must reject stale ETag; attendee notifications visible. |
| Meeting companion | Floating/narrow window, notes during capture, microphone/system audio, language install, permission denial/cancel, sleep/device loss, forced restart and checkpoint review/save/discard, recurring-series title change and distinct calendar series. |
| Privacy | Legacy migration/corruption/missing Keychain key, large encrypted restore/wrong passphrase, private session then quit/end, lock all windows/menu/companion, background lock/unlock, pause during an in-flight request then resume, archive retention and remaining recovery copies. |
| Dictation | Accessibility/mic/speech grants, hotkey collision, password field, original/changed focus, unsupported editors, vocabulary boundaries, long silence/cancel, Copy fallback, Reduce Motion/VoiceOver labels. Never automatically submit. |
| Routines/errands | Close window versus Quit; missed/interrupted history and no replay; DST/timezone schedule; pause during work; restored schedules disabled. Cua explicit connect, decline/uncertain action, continuation fresh read, takeover, fresh completion quote and restart without reconnect. |
| Knowledge/work | Multiple selected sources, changes/deletions, stale bookmarks, PDF without text, DOCX limits/cancel, remove/forget, source links, project deletion while editing, decision rationale/evidence/review and portable restore. |
| Release | Owner-configured signing/notary/feed; clean install and version upgrade/rollback; wrong key/hash/build/OS, interrupted/oversize download. Verify no chat/account/token/path appears in generated diagnostics. |

The [native Cua run](cua-end-to-end-2026-10-30.md) completed the principal local
flows above with real Splash inference and isolated provider fixtures. The full
matrix describes further variants, not a list of completed results. The user
deferred live audio and permission-dependent Cua browser checks and restricted
live providers to read/draft/review. Public signing/hosting, real-account consent
and manual macOS authentication remain owner steps; an ad hoc build and fixture
responses do not substitute for them.

