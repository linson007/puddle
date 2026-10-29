# Puddle supported features

Puddle is a native macOS personal assistant using a separately running local
Splash server. It supports conversation, personal memory, local tasks and
reminders, and optional read access to Gmail and Google Calendar. Google is
optional; general conversation needs only Splash.

## Requirements and setup

- macOS 14 or later; Swift 6 tools or Xcode to build.
- A running Splash server for real model responses. Splash has its own hardware,
  model, and operating system requirements.
- A Google account and an app-owner-provisioned Desktop OAuth client only for
  Gmail or Calendar. See [Google setup](gmail-setup.md).
- Desktop notification permission for reminders outside the app.
- macOS 26+ and a supported speech language for long-form meeting transcription.
- Google Chrome for the experimental local Google Meet attendance assistant.

Build with `make build`, then open `build/Puddle.app`. In Settings → Local AI,
enter the Splash address and optional API key and choose **Save and Test
Connection**. The default address is `http://127.0.0.1:8000`.

## Conversation

Puddle can help with questions, writing, brainstorming, planning, and follow-up
questions. Replies stream into the conversation. **Stop** cancels the active
turn, including an outstanding task approval. A response that reaches its output
limit is labeled; an interrupted tool stream cannot execute pending tools.

- **New Conversation**, including ⌘N, archives the current chat and opens an empty
  one. Memory, tasks, preferences, and connections remain available.
- **History** lists the current conversation immediately, marked **Current**,
  alongside archived chats. Search matches messages in both. Open a conversation
  to continue it, or delete it from History. Opening the current chat keeps any
  reply running; switching to another saves the chat it replaces without
  duplicating entries.
- **Copy** copies a message. **Use as draft** puts a user message into the composer
  so it can be edited and sent as a new message.
- **Retry last message** replaces the last attempt's response while preserving
  its tool receipts. If that attempt already created a reminder, retry cannot
  create additional reminders; ask in a new message to request another action.
- Tool receipts show completed, declined, or failed operations. Mail and calendar
  receipts link to source items when available.
- Completed live replies show total time, first-token time, and time spent
  extracting memory. Fixture replies do not represent inference performance.

Settings → Assistant stores response preferences. Settings → Local AI offers
4K, 8K, 16K, and 32K context budgets. Puddle also respects the server's reported
context capacity. Text token counts are estimates; Splash's tokenizer is
authoritative. Older history and large tool results are bounded for inference;
truncated tool results are labeled. Stored conversation history is retained
until its archive is deleted.

## Voice chat

Choose the microphone in the composer, or press Command-Shift-M, to dictate a
message. The app requests microphone and speech recognition permission only
when you start input. Recognition requires an installed on-device language;
Puddle refuses a cloud fallback if that language is unavailable.

While listening, the transcript and a microphone indicator remain visible.
Choose **Done** to finish, or **Cancel** to discard the capture. Each dictation
is limited to fifty seconds. The transcript is appended to your draft, preserving
existing typed text. Review or edit it and choose Send. Voice input does not
automatically submit a message. Navigating away, closing chat, or starting other
work cancels capture. Demo mode cannot start the microphone.

Enable **Read new replies aloud** for spoken answers after sending a dictated
message. This is turn-based voice chat; it does not continuously listen or
detect a wake word. The selected voice language also selects recognition language.

### Read replies aloud

Choose **Read aloud** below an assistant reply to hear it using an installed
macOS voice. The same control stops playback. New conversations, stopping work,
and starting another request also stop the previous spoken reply.

Settings → Assistant → Voice includes an optional **Read new replies aloud**
setting, language choices, and speaking speed. Automatic playback is off by
default. Available voices depend on the language packs installed in macOS.
Spoken replies omit fenced code blocks, link destinations, images, and visual
Markdown markers and are limited to 8,000 characters. This playback does not
access the microphone.

## Personal memory

Automatic learning is enabled by default and can be disabled in Settings →
Assistant. Disabling it stops automatic saves and removes the model's save-memory
tool. Existing memories remain available for recall, and manual saving still
works.

Puddle learns useful facts and preferences from the current user message. A
short direct introduction can be recognized locally. Messages with a name and
additional facts also go through extraction for the remaining facts. Extraction
is skipped for ordinary messages without a recognizable personal-fact cue.

Automatically saved content must be an extract from an exact supporting quote.
The full user message is checked for credential terms and supported token
patterns. Messages containing those patterns are excluded from learning, even
when a proposed quote omits the sensitive label. This is conservative text
validation, not a guarantee that every secret format or ambiguous statement can
be recognized.

Requests such as “don't remember this”, “do not memorize this”, “keep this between
us”, and “off the record” suppress learning from that message. They do not erase
the message from conversation history. The model is instructed to exclude
fictional examples, quoted statements, and facts about other people.

Memory supports:

- Reviewing facts, update times, and automatic-learning source quotes.
- Adding a fact manually or updating it by saving the same title.
- Forgetting individual memories.
- Updating common equivalent titles, such as Profession and Job, under the same
  existing memory ID. Other titles match after case and punctuation normalization.
- Carrying memories across conversations and restarts. Automatic evidence also
  retains the originating message ID.

Learning reads user messages, not assistant answers, email bodies, or calendar
descriptions. Up to five model-extracted candidates are considered per extraction.
The name recognized locally can be retained alongside those candidates. Memory
extraction can fail without preventing the conversation response.

## Tasks and reminders

Tasks are stored locally and are separate from Google Calendar events.

- Add an undated task or a dated reminder directly in **Tasks**.
- Ask Puddle to propose one in chat. The exact title and local date/time appear
  for **Allow** or **Decline** before creation.
- Mark tasks complete or incomplete.
- Edit titles, add or remove due dates, and reschedule reminders.
- Snooze a task for ten minutes or delete it from its menu.
- Read saved tasks through the assistant.

Enable desktop notifications in Settings → Assistant. Puddle schedules future
reminders with macOS using stable task IDs. Completion, deletion, rescheduling,
snoozing, and disabling notifications reconcile pending requests. macOS can
deliver scheduled notifications while Puddle is closed, subject to system
notification permissions and delivery settings.

While running, Puddle checks due tasks every ten seconds. Each due reminder also
appears in chat once, including overdue tasks after restart. This chat entry is
separate from the system notification; restarting does not intentionally send a
second desktop alert. Recurring reminders and editing tasks through chat are
not implemented.

## Gmail

Connect through **Connections → Connect Google** or Settings → Connections.
Puddle can search Gmail using Gmail query syntax and return up to ten matching
messages. For example, ask about unread messages, a sender, or a date range.
General questions do not automatically retrieve mail.

Optional background checks run while Puddle is open, at intervals of one, two,
five, or ten minutes. The inbox cache contains up to fifty recent messages.
The first check establishes a baseline. Later checks use Gmail history and reuse
unchanged message bodies; changed messages are refreshed. Expired history cursors
or very large backlogs establish a new baseline without repeat arrival alerts.

Connections displays five recent cached messages with expandable bodies and a
**Summarize** action. Optional automatic summarization handles up to three new
messages per check. Summaries remain attached to cached messages. Optional mail
notifications report arrival counts without including message bodies.

HTML is converted to plain text without loading remote images. Missing bodies
are marked as previews; large bodies are shortened. Attachment names can be
decoded, but attachment contents are not fetched or analyzed. The bounded inbox
cache is not a complete mailbox history.

## Google Calendar

The assistant reads upcoming events from the primary calendar over a window of
one to fourteen days, starting now. It supports timed and all-day events,
expands recurring instances, and excludes canceled events. Connections displays
up to eight cached events from a seven-day refresh.

Calendar retrieval follows up to five pages and returns at most fifty events.
If further results exist, the tool result and Connections indicate that the
window is incomplete. Ask for a shorter window to narrow the result. Source
links are included when Google supplies a supported Calendar URL.

Historical calendar search, secondary calendars, and event creation or editing
are not implemented.

## Meeting access

**Meetings** lists cached Calendar events with recognized Google Meet, Zoom,
Microsoft Teams, or Webex join links. Links are read from conference entry points,
Google Meet metadata, locations, and invitation descriptions. You can also paste
a join link without connecting Google.

**Open join screen** hands the validated HTTPS link to your browser or installed
meeting app. Complete joining, account selection, and microphone/camera choices
there. Puddle does not claim that opening a link means the meeting was joined,
and the Google Meet attendance assistant below has separate automation
controls. Unsupported domains, lookalike domains,
embedded URL credentials, and non-HTTPS links are rejected. Demo mode cannot open
real meeting links.

### Google Meet attendance assistant

**Google Meet attendance · Experimental** automates a local browser join flow.
Choose a Meet-linked note, or paste a Google Meet link in Meetings, enter the
guest name if needed, and choose **Join Google Meet**. A standalone join creates
a local note with the link. Each session is started explicitly; Calendar refresh
does not schedule or start attendance.

The assistant launches Chrome with a dedicated profile under Puddle's local
data directory, using a random loopback-only control port. It does not reuse
your ordinary Chrome profile or Puddle's Gmail/Calendar OAuth session. Sign in
manually in that Chrome window when required; the assistant continues after
sign-in. The meeting uses the Google account signed into that browser or, when
allowed by the organizer, the guest name. Passwords, sign-in challenges, and
Google permissions are handled by you in Chrome.

Camera and microphone permissions are denied before opening the managed Meet
tab. The helper can dismiss the continue-without-media prompt, fill the guest
name, and select **Join now** or **Ask to join**. It distinguishes sign-in,
waiting for admission, in-call controls, and ended/denied states. **Joined**
means the Meet page exposes in-call controls; it is not a server attendance
receipt. English page labels are requested; unrecognized layouts require manual
attention. This integration needs interactive validation against the current
Meet website and your account's guest/admission rules.

A global status banner remains visible while attendance is active. **Leave
meeting** closes only the tab created by that session. A previous Meet tab in
the dedicated profile must be finished or closed before another session. Sign-in
and admission waits stop after ten minutes; calls stop after two hours. Closing
the main window does not itself end attendance. Quitting Puddle first attempts
to close its managed tab; if closure cannot be verified, a dialog asks you to
close it manually or explicitly quit anyway. An unverified leave is never
reported as successful. Demo mode cannot launch the attendance browser. If
Puddle crashes or is force-quit, close the dedicated Meet tab manually; the
browser runs in a separate process.

After admission, start **Live transcription** and select Chrome through the
macOS sharing picker. Audio capture is a separate explicit action. Browser
application capture can include other Chrome profiles or tabs that are playing
audio. When attendance ends, a linked note's active transcription is stopped
for review. Transcripts still need to be applied and saved, and summaries are
generated on request.

Google's official Meet Media API is discontinued, closed to new apps, and
scheduled to shut down on 15 January 2027. This integration therefore uses the
browser join flow selected for this project. See [Google's Meet developer
notice](https://developers.google.com/workspace/meet) and
[Chrome's dedicated-profile debugging guidance](https://developer.chrome.com/blog/remote-debugging-port).

## Meeting notes

Choose **Meetings → New notes** to create local notes without a connected
account. A calendar meeting's **Notes** button opens its existing note or creates
one with the event title, date, and join link. Repeated use of Notes on the same
event keeps a single note.

The meeting search field matches all query words across titles, participants,
agendas, notes, transcripts, summary quotes, and action items. Search ignores
case, accents, and character width. Results show a matching passage and mark
unsaved drafts; draft text replaces its saved version in search. Searches run
off the main UI thread with cancellation, and filtering never discards a draft
or changes the selected note. Previous summaries remain searchable and labeled.

Notes include an editable title, meeting date, participants, agenda, personal
notes, and a separate transcript field. Choose **Save** to keep edits across
restarts. Unsaved drafts remain available when switching between notes in the
running app; failed saves retain those drafts and leave the saved version intact.
Save before quitting. **Discard changes** restores the saved version.

**Import transcript…** accepts UTF-8 or BOM-marked UTF-16 text and Markdown,
WebVTT (`.vtt`), and SubRip (`.srt`) files. Subtitle imports retain cue timestamps
and speaker labels. Review the preview, then choose **Append** or **Replace
transcript**; the result remains a draft until Save. Imports are limited to 2 MB
and 200,000 characters. Invalid or oversized files leave existing text intact.

Meeting text is separate from personal memory and does not trigger automatic
memory learning. Notes survive New Conversation and Google disconnect. They use
the same private state and backup files as other local data. The meeting-capable
state format prevents older Puddle builds from overwriting these new records.

### Export

Choose **Export…** in a note to save Markdown, plain text, structured JSON, or
the transcript alone. Exports use the current draft and label unsaved edits;
exporting does not save or change the original note. Structured exports include
an export version and ISO 8601 dates. Exports retain source quotes and indicate
when a summary is out of date.

For full-note exports, you can exclude the full transcript. Summary quotes
remain included. Meeting join links are excluded by default and require an
explicit option. Markdown escapes reference text and fences the transcript so
embedded Markdown is displayed as text. The native save dialog chooses the
destination and handles overwrite confirmation; writes are atomic and use
owner-only file permissions. Puddle does not upload or send the export. JSON
re-import and audio-file export are not implemented.

### Live meeting transcription

On macOS 26 or later, **Live transcription** uses Apple's on-device
SpeechAnalyzer for long-form speech. It does not require Splash. Choose a voice
language in Settings → Assistant. **Install speech language…** explicitly
downloads Apple's model when necessary; audio is processed on this Mac.
Unsupported devices or languages show an error; there is no cloud fallback.

Choose **Microphone**, **Meeting app audio**, or **Meeting app + microphone**,
then **Start transcription**. Microphone modes request microphone permission.
Meeting-app modes open the macOS content-sharing picker, limited to a single
application. Select the meeting application there. Selecting a browser can
include its other tabs' audio. Puddle registers audio outputs only and does not
save screen frames or raw audio. Audio capture starts separately from joining.

Capture shows an active indicator, elapsed time, and recent recognized text.
**Stop and review**, switching notes, or leaving Meetings ends capture. Review
the preview and choose **Append** or **Replace transcript**, then **Save** to
retain it across restarts. Existing notes remain intact until you apply changes.
The channel labels **Microphone** and **Meeting audio** identify sources, not
individual speakers; use headphones to reduce duplicate audio. Provisional
passages that could not be finalized remain labeled for review.

Sessions are limited to two hours, 5,000 passages, and 200,000 characters.
Bounded audio queues stop capture with a visible error if recognition cannot
keep up. Cancellation, device errors, and finalization timeouts retain captured
text for review. Deleting an active note or switching Demo mode cancels its
capture. Spoken replies and chat dictation are blocked during meeting capture.
Tell participants before transcribing. Hardware, permissions, and recognition
accuracy still require interactive verification on the target Mac.

### Local summaries

After saving, choose **Generate summary** to process the notes and transcript
with the configured local Splash model. Puddle groups exact source quotes into
key points, decisions, action items, and open questions. Owners and timing appear
only when quoted in the action itself; relative dates remain as stated.
Classification is an AI draft and needs review against the full transcript.
Tasks, reminders, and personal memories are not created by summary generation.

Large sources are split into sections that fit the configured and advertised
model context limits. A progress indicator and **Cancel summary** control remain
available. The limit is 64 sections and 500 extracts; exceeding a limit asks you
to split the source instead of silently omitting text. Quotes must match their
source exactly. Unsupported or incomplete model responses, cancellation, changed
source text, and failed saves retain the previous summary. Editing notes or the
transcript marks the existing summary as out of date. Summaries are saved
separately and never replace your written notes.

Choose **Review and add task…** under an action to edit its title and optionally
pick a reminder time. Tasks are undated by default; Puddle does not guess dates
from phrases such as “Friday.” Adding saves the task and its meeting link
atomically. Repeated clicks and summary regeneration reuse the existing task
for the same source quote. Tasks retain their source quote even if the meeting
note is deleted. Deleting a task allows you to explicitly add that action again.
The Tasks screen links back to the meeting and includes its source quote.

## Connections and credentials

Google sign-in uses an external browser, a random loopback callback port, PKCE,
and random state verification. Choose Safari or the default browser in Settings.
Puddle accepts Gmail-only or Calendar-only consent and displays the verified
Google account email. **Manage Google Permissions** reconnects with the selected
services. Disconnect clears local tokens and connection caches while retaining
conversation, memory, and tasks.

Gmail and Calendar are read only. They cannot send mail, delete or mark messages
read, or change events. Account changes and disconnect invalidate active work;
shared refresh callers cannot return tokens after disconnect. Google reads use
bounded retries for rate limiting and selected server errors. Automatic mail
checks back off after failures and honor longer `Retry-After` delays.

OAuth tokens, the Desktop client configuration, and an optional Splash API key
use macOS Keychain without iCloud synchronization. The build can bundle a Desktop
client configuration; it never bundles user account tokens.

## Local storage and recovery

Live data is stored in `~/Library/Application Support/Puddle/state.json`. It
contains current and archived conversations, receipts and timings, memory and
evidence, tasks, meeting notes and transcripts, settings, activity, and connection caches. The directory has
owner-only permissions, as do state and backup files. JSON is not separately
encrypted.

Saves are atomic and preserve the previous valid state as `state.backup.json`.
State has a schema version, and older settings receive defaults for new fields.
If the primary file is unreadable and the backup is valid, Puddle restores the
backup, displays a recovery notice, and preserves the unreadable original under
a unique filename. Recovery can lose changes made after that backup. Newer,
unsupported state versions are never downgraded automatically.

If recovery is unavailable, edits are blocked. Restore the state file, then use
Settings → Assistant → **Retry Loading State**. Failed writes roll back visible
state instead of acknowledging unsaved changes.

Forgetting a memory, deleting an archive, or disconnecting a service does not
erase facts already present in other conversations. The previous-state backup
and preserved recovery files can also retain older data. These actions are not
secure erasure.

## Demo and desktop access

`make demo` or **Explore the demo** opens fixture conversations, sample
connections, and in-memory state. Demo data is not saved to the live cache, and
fixture replies do not contact Google or perform model inference. Creating a
demo reminder still exercises the app's approval logic, without scheduling a real
desktop notification. Exit demo to return to live state.

The menu bar provides access to conversation, tasks, connections, settings, and
Quit. Closing a window leaves the menu bar app available. The app refreshes due
reminders and connected data when the Mac wakes. `--data-dir PATH` selects a
different state directory; credentials still use the app's Keychain service.

## Runtime boundaries

Inference accepts only loopback HTTP or HTTPS addresses, and redirects are
rejected. Google requests go directly to fixed HTTPS API endpoints. External
email and calendar text is treated as untrusted reference data. The model can
request only implemented tools, with a maximum of six response steps and twelve
tool calls per turn.

Puddle does not implement general-purpose browser automation, arbitrary command execution, file
tools, web browsing, continuous voice listening, cloud inference, autonomous background projects,
multi-account Gmail/Calendar sessions, or cross-device sync. Google Meet browser
attendance is the scoped exception described above. It does not manage the Splash
server process. Local builds are ad hoc signed; distribution signing,
notarization, automatic updates, and Google OAuth verification remain app-owner
work.

See [testing](testing.md) for automated and manual verification.
