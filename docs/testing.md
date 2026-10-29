# Verify the Puddle personal assistant

## Automated checks

Run make test and make build. Tests use HTTP fixtures and in-memory credentials
to exercise the core implementations. They do not establish that a real Google
account or Splash engine is configured.

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

1. Open Puddle. Confirm the main screen is a conversation with **Message Puddle**,
   plus Tasks, Memory, and Connections. No Gmail sign-in is required.
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

