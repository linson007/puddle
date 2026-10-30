# Puddle supported features

Puddle is a native macOS personal assistant using a local
Splash server. Today brings together priorities, commitments, follow-ups,
meeting preparation and optional Gmail/Calendar context. Personal memory,
conversation history and portable workspace backups stay local. Organizing
work needs no account or model; conversation needs only Splash.

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

## Guided setup, privacy and additional workspaces

**Set Up Local AI** checks chip/OS/RAM/free disk, discovers or installs Splash,
offers two resource presets, starts/stops its own process and tests a real answer
plus a synthetic required tool call. It never executes personal tools during
setup. Installation/first model download need internet; cached models can start
with external APIs paused. Existing independently managed servers remain usable.

**Actions** holds editable mail/calendar proposals and exact reviewed writes.
Dispatch intent must save before a request leaves the app. A lost response is
uncertain, requires provider inspection and is never automatically retried.
Restoring backups does not dispatch proposals. Newsletter review supports only
public HTTPS one-click headers, showing the destination and fixed POST content;
unsupported senders must be managed at the provider. Mail snooze is local to
Puddle, with a local follow-up reminder and Bring Back.

**Work Context** contains projects/goals, people/VIPs and a decision register.
Link commitments and meetings to projects. People fields are manual, editable
and removable; they do not contact anyone or infer sensitive facts. Decision
records include owner/options/rationale/evidence/review/outcome. The assistant
reads bounded saved records; they are reference data, not execution evidence.

**Knowledge** indexes explicitly selected files/folders on this Mac. Supports
text/Markdown/CSV/TSV/JSON/log/HTML/XML, selectable-text PDF and DOCX. Per source:
200 files/5,000 traversed entries/10M extracted characters; per document:
25MB/200,000 characters/200 PDF pages. Text files cap2MB. Symlinks and private/
generated folders are excluded. Refresh updates changed files/removes deleted
ones; Remove forgets source grants and text. Search returns up to20 cited
passages. No OCR or XLSX/legacy Office parsing. Indexes/grants stay out of portable backups.

**Routines** run scoped read-only local-model briefs/reviews at saved weekday/
time/timezone schedules. Results and missed/failed/interrupted runs are visible.
The next date and intent save before execution; interrupted work is not replayed.
The app/menu bar must be running. After Quit, a recent missed run can catch up
once at next launch; older runs are marked missed. Launch at Login is optional.
They cannot send, book, create tasks, learn memories or operate browsers.

**System Dictation** is opt-in: hold CmdShiftSpace, speak, then release. On-device
recognition inserts into the original accessible text field only if it still
belongs to the same focused application/element. Password fields are excluded.
Changed/unsupported targets retain text for Copy; nothing is automatically sent.
Vocabulary corrections and punctuation are configurable. Accessibility and
microphone/speech grants require explicit native setup.

**Privacy** offers temporary in-memory sessions (no persistence/automatic learning/
external writes), app lock using macOS authentication, archive retention and
external API pause. Private sessions restore the saved workspace on exit.
API pause permits loopback inference and stops managed browser/Meet work; it is
not a firewall for other applications/independent servers. Workspace encryption
and portable backup behavior are described below.

CmdK opens commands/global search across saved work and the selected provider's
cached mail. CmdShiftN captures work, CmdShiftL opens a contextual assistant
panel, and CmdShiftA opens action review. Assistant activity has text labels and
respects Reduce Motion. See [implementation/acceptance status](improvement-implementation.md).

## Today and work context

The sidebar groups **Today** and **Puddle** under Main; **Tasks**, **Calendar**,
**Mail** and **Meetings** under Work; and **History** and **Memory** under
Workspace alongside **Browser**. **Developer** appears under Workspace only for Developer profiles.
Navigation scrolls at shorter window heights.
**Connections** and **Settings** stay at the bottom. Mail and Calendar remain
visible when disconnected and offer Google sign-in in their own views.

The app opens to **Today**, which works without an account or running model.
Choose a role profile using the sidebar menu. Use **Manage Profiles**, Today →
**Profiles**, or Settings → Assistant → **Manage Profiles** to edit its optional
name, role, organization, goals and additional guidance. Saved work context is
reference data for local conversations. Failed saves keep the editor open.

### Role profiles in one workspace

Two presets are included: **Personal** and **Developer**.
Each changes the assistant's approach, chat starters, and daily planning prompt.
The Developer profile, for example, offers
debugging and technical design prompts and **Plan my focus** in Today. Built-in
guidance can be inspected in the profile editor. **Custom** supports your own
role guidance. You can save up to fifty uniquely named profiles, duplicate one,
rename it or remove an inactive profile after confirmation.

Each profile retains its own work context and guidance. Conversations, history,
memories, commitments, meeting notes, daily priorities, connections, global
response preferences and voice settings are shared. These are roles for one
person, not separate user accounts or privacy boundaries. Developer source tools
require a project folder you explicitly connect; role guidance cannot grant
access to additional folders or project command execution.

Switching profiles or saving active-profile guidance cancels an unfinished
reply and any pending reminder approval. It preserves the composer, current
conversation and completed actions. New replies show the profile name used;
older replies without a saved profile label remain readable. Selection and
configuration persist across restarts. Existing single-profile state migrates
without losing its saved work context. Profiles can also be switched from the
menu bar.

The former CXO, Product Manager and Researcher options provided only prompts and
have been removed. Empty presets are removed when loading an older workspace
or backup; profiles with saved context, guidance or custom names become Custom
profiles with their saved data intact. An empty retired selection falls back to
Personal, or another remaining profile.
Daily briefs, decisions, commitments and meeting preparation remain available
to every profile.

The Developer sidebar and menu bar entry follow the selected profile's approach,
including custom-named Developer profiles. Switching away from the Developer
page opens Today; other shared pages stay selected.

### Daily workspace

- Star up to three open commitments in Tasks to choose today's priorities.
  Stars expire at the next local day; unfinished commitments stay saved.
- See overdue commitments, due-today work, waiting-on count and today's cached
  primary-calendar events. Calendar reads begin at the start of the local day.
- Known overlapping timed events name each other. Adjacent events and all-day
  events are not marked as conflicts. Missing end times are not guessed.
- Calendar/mail refresh timestamps remain visible. Data older than fifteen
  minutes is labeled **Cached**. Incomplete calendar responses are labeled.
- Flagged mail means unread messages carrying Gmail's Important label, within
  the bounded recent inbox. It is not AI triage or a full-mailbox guarantee.
- **Brief me on today** and **End-of-day review** open chat. The read-only daily
  brief tool shares saved commitments and cached sources with counts, timestamps
  and scope limits. No tool silently changes priorities or contacts owners.

## Developer workspace

**Connected work sources** bring GitHub.com issues/PRs, Jira Cloud work and
Confluence Cloud pages into a shared search and detail view. Connect accounts
in **Connections**, select repositories/an Atlassian site, and search from
Developer or Connections. GitHub PRs include bounded patches and reported CI
checks. **Ask Puddle about this** passes a source locator to local chat for a
fresh read and cited response. These read/search tools work across profiles;
project source tools still require the Developer profile and a chosen folder.
See [work connector setup, storage boundaries and limits](work-connectors.md).

Select a Developer profile, then open **Developer**. **Choose Folder** explicitly
connects one local project; its bookmark stays on this Mac. Name the project and
save stack, architecture, goals and constraints in **Edit Project Context**.
Switch between up to 25 connected projects. Removing a connection leaves files
untouched and retains saved sessions and unsaved session evidence.

- **Find Files** filters source paths; **Search Code** searches literal text.
  Results identify paths and lines. Open a result for a numbered excerpt and
  navigate to later lines. Limits and incomplete results are labeled.
- **Git Status** shows branch/commit and readable changed paths. **Working Diff**
  compares captured index/working text; **Staged Diff** compares HEAD/index.
  Mode, rename and binary changes are outside these text comparisons.
- **Explain this project** and **Review current changes** open local chat with
  scoped project tools. Tools inspect fresh source only in the selected project;
  receipts link to source files. Other role profiles cannot invoke these tools.
- **New Session** creates a debugging, implementation or review record. Keep
  expected/observed behavior, reproduction steps, findings and user-recorded
  verification. Drafts survive navigation; failed saves do not clear them.
  **Save & Ask Puddle** saves evidence and opens a source-aware conversation.
- Developer sessions are backed up; project grants and source browsing caches
  are excluded. Restore retains the former project name and requires choosing
  and linking a folder again before source access.

Source tools accept regular UTF-8 source up to 512 KB; excerpts are bounded to
120 lines / 14,000 characters. Inventory returns up to 200 files with traversal
limits; search examines up to 2,000 files / 8 MB and returns 30 lines. Common
private/generated paths, symlinks, binaries and recognized credentials are
excluded. This is a heuristic source policy: gitignore rules are not applied,
and secrets that do not match known patterns can still be present in source.
Source content goes only to the configured local model, but snippets may remain
in conversation archives.

Git uses fixed read operations with hooks/fsmonitor/external diff/textconv
disabled, a five-second timeout and bounded output. No project scripts, tests,
patches, staging, commits or remote Git actions execute. Verification fields
are notes from the user, not test-run receipts. See the [developer improvement
plan](developer-assistant-plan.md) for implementation status and the next stages.

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

Chat initially renders the latest 200 messages. **Load earlier messages** adds
200 at a time; the full saved transcript remains available. History searches
run off the main thread and cancel superseded queries.

## Voice chat

Choose the microphone in the composer, or press Command-Shift-M, to dictate a
message. The app requests microphone permission only when you start input.
On macOS 26+, supported Macs and languages use SpeechAnalyzer independently of
Siri and macOS Dictation. Install the selected model from **Settings → Assistant
→ Voice → Install speech language** (or the meeting transcription controls).
Installation is an explicit download; recognition then works offline. Older
Macs and other languages use the on-device legacy recognizer, which also
requests speech recognition permission and may require enabling **System
Settings → Keyboard → Dictation**. Puddle refuses a cloud transcription fallback.

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
- Searching saved titles, content and source quotes in a lazily rendered list.
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

Model context includes a bounded selection of saved memory. The memory tool
can search older facts and returns at most twenty matches with explicit
partial-result metadata. Its JSON fits the remaining model context; large
conversation histories leave room for tool results.

## Tasks and reminders

Tasks are stored locally and are separate from Google Calendar events.

**Tasks** is a commitment list with **Open**, **Waiting on**, and **Completed**
filters. Search titles, owners and notes. Quick capture adds an undated action;
**New Commitment** or **Edit** also sets priority, owner, active/waiting status,
notes, and a due/follow-up date. Waiting items require a named owner. Owner
assignment records context locally; it sends no message or delegation.
Delete asks for confirmation. A failed save retains the editor draft.

Stars select today's three priorities. Completing a priority clears its star;
reopening it does not silently reprioritize it. Snooze options move its reminder
ten minutes or twenty-four hours from now.

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
second desktop alert. Daily, weekly and monthly commitments create one next
occurrence on completion, preserving the local wall-clock time and monthly day
where possible. Reopening an occurrence cannot create another successor.
Chat can propose exact reviewed creation, completion, reopening, renaming and
rescheduling. Read-only routines cannot change commitments.

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

**Mail** displays the cached inbox in a searchable message list and reading
pane. **All**, **Unread** and **Important** filters apply to cached messages;
search includes sender, recipient, subject, body and attachment names. Reading
does not change Gmail read status. **Summarize** attaches a local summary;
**Ask Puddle** shares the selected email as reference material with personal
memory learning disabled for that turn and retries. **Create task…** opens an
editable, undated local draft with its source link; only saving creates a task.
**Open in Gmail** opens the original message. **Thread & Attachments** loads
the conversation, lets you choose a message, previews supported attachments and
can ask the local model about extracted PDF/plain text. File downloads are
explicit and limited to 10 MB. Gmail threads cap at 250 messages; Outlook follows
pages up to 500 messages/10 million body characters. Partial results are labeled.
Gmail and Outlook response envelopes cap at 16 MiB before parsing, including
through read retries. Saved attachments retain macOS quarantine and source
metadata before publication; a metadata failure preserves the existing file.
The view shows refresh progress and its last update, without a full-inbox badge.

Optional automatic summarization handles up to three new
messages per check. Summaries remain attached to cached messages. Optional mail
notifications report arrival counts without including message bodies.

HTML is converted to plain text without loading remote images. Missing bodies
are marked as previews; large bodies are shortened. Attachment names can be
decoded. Attachment contents are fetched only when selected. The bounded inbox
cache is not a complete mailbox history.

## Google Calendar

The assistant reads events from the start of the current local day on the primary calendar over a window of
one to fourteen days, starting now. It supports timed and all-day events,
expands recurring instances, and excludes canceled events. **Calendar** provides
**Today** and **Next 7 days** agendas, search across cached titles, locations and
descriptions, and a detail pane. Multi-day events appear on each applicable day;
all-day end dates are treated as exclusive. Events with missing dates remain
visible under **Date unavailable**. Times use the Mac's local timezone.

Refresh loads a seven-day window and shows progress and the last update.
Select an event to **Join meeting**, **Prepare**, or open **Meeting notes**.
Preparation and notes are local; they do not edit the Google event. Supported
source links open the original event in Google Calendar. Meetings remains the
workspace for notes, recordings and transcripts.

Calendar retrieval follows up to five pages and returns at most fifty events.
If further results exist, the tool result and Calendar indicate that the
window is incomplete. Ask for a shorter window to narrow the result. Source
links are included when Google supplies a supported Calendar URL.

**Week & Month** loads the chosen month independently of the Today cache, with
up to ten explicitly selected calendars and bounded results. Working hours,
meeting buffers and duration produce candidate slots; incomplete calendar data
cannot be booked from suggestions. Focus-time proposals use the same review.
New/edit proposals show title, attendees, timezone, location, notes and times.
Writes require an optional Google grant and exact-content review in Actions.
ETags protect edits; undo creates a new reviewed removal or restoration and
checks the revision returned by the original write. Cancellation/restoration
may notify attendees. Arbitrary historical full-account search is not included.

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

## Meeting preparation

Choose **Prepare** on a calendar event in Today or Meetings. Review the calendar
description, join/source links, saved agendas, extracted decisions/questions
and open tasks linked to the matching notes. Matches use a calendar event ID
or normalized full meeting title; relationships are not guessed from keywords.
The dates and matching rule are shown so unrelated same-title meetings can be
recognized. Extracts whose notes/transcript have changed are labeled stale
instead of being presented as current decisions. This view reads saved notes;
unsaved drafts remain in the meeting workspace. **Open meeting workspace**
opens the event's note or creates one atomically.

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

Connections start with read permissions. Optional send/organization/calendar-write
grants enable exact reviewed actions in the Actions workspace. A proposal alone
does not dispatch anything. Account changes and disconnect invalidate active work;
shared refresh callers cannot return tokens after disconnect. Google reads use
bounded retries for rate limiting and selected server errors. Automatic mail
checks back off after failures and honor longer `Retry-After` delays.

OAuth tokens, the Desktop client configuration, and an optional Splash API key
use macOS Keychain without iCloud synchronization. The build can bundle a Desktop
client configuration; it never bundles user account tokens.

## Local storage and recovery

Live data is stored under `~/Library/Application Support/Puddle/`. It
contains current and archived conversations, receipts and timings, memory and
evidence, tasks, meeting notes and transcripts, settings, activity, and connection caches. The directory has
owner-only permissions, as do state and backup files. AES-256-GCM encrypts the
workspace; its random key is stored separately in this Mac's Keychain. Legacy
JSON state/recovery files are encrypted and verified before their plaintext
originals are removed. Existing filesystem snapshots can retain older copies.

Saves are atomic and preserve the previous valid state as `workspace.backup.vault`.
Schema 8 uses `workspace.vault` and that backup as indexes referencing immutable,
encrypted transcript pages under `transcripts/`, with encrypted page copies under
`transcripts/recovery/`. Only changed pages are rewritten. Pages needed by the
current or previous index remain; obsolete pages are removed after both indexes
release them. Damaged recovery evidence is preserved. A damaged page can be
repaired from its validated copy without losing the latest messages.

Keep the complete workspace directory and its Keychain key for device-bound
recovery. Copying only `workspace.vault` is insufficient. Use portable backups
for transfers. Older single-file encrypted workspaces migrate on save. Older
schema-7 apps cannot read schema 8; keep a pre-upgrade portable backup if a
previous-version rollback is needed. The workspace has a 120 MiB logical size
limit, including transcript pages and the index.

State has a schema version, and older settings receive defaults for new fields.
If the primary file is unreadable and the backup is valid, Puddle restores the
backup, displays a recovery notice, and preserves the unreadable original under
a unique filename. Recovery can lose changes made after that backup. Newer,
unsupported state versions are never downgraded automatically.

If recovery is unavailable, edits are blocked. Restore the complete workspace, then use
Settings → Assistant → **Retry Loading State**. Failed writes roll back visible
state instead of acknowledging unsaved changes.

Forgetting a memory, deleting an archive, or disconnecting a service does not
erase facts already present in other conversations. The previous-state backup
and preserved recovery files can also retain older data. These actions are not
secure erasure.

## Portable workspace backups

Settings → **Backups** exports saved conversations (including the active chat),
memories, commitments, meeting notes, profiles, instructions, actions, projects,
people, decisions, routines, errand records and development sessions.
Unsaved drafts, cached mail/calendar, model connection settings, indexed document
text/folder grants, browser sessions and Keychain credentials are excluded.
Action drafts include their bound account and exact contents. Text that you
entered in conversations or notes is included and may itself be sensitive.

Passphrase encryption is enabled by default (PBKDF2-HMAC-SHA256, 600,000 iterations,
random salt, AES-GCM). Keep the passphrase independently; it cannot be recovered.
Optional unencrypted exports use a SHA-256 envelope and owner-only permissions.
The checksum is not proof of authorship. Version 2 compresses the logical content
with LZFSE before optional passphrase encryption. Logical content is limited to
120 MiB, the compressed portable file to 64 MiB, and the protected file to
128 MiB. Decompression is bounded by the validated declared size. Original
version-1 backups remain readable; old apps cannot read version-2 exports.

**Review Backup** validates the file and shows counts before **Merge Workspace**.
Missing items are added atomically; current IDs and equivalent memory titles
take precedence. Your active chat stays open and restored chats go to History.
Current settings and account connections remain in place. Missing profiles are
added; current edited profiles take precedence and empty presets can receive
saved context. Conflicting names and profiles beyond the fifty-profile limit
are skipped and counted in the preview. A backup's active profile is selected
only if current work context is empty. Shared assistant instructions are
imported only when the current value is default. Older single-profile backups
remain readable. Repeating an import does not duplicate entries. Imported tasks have no
daily stars, past reminders do not replay, and future reminders use your current
notification preference. Failed writes leave the existing workspace intact.
Imported routines are disabled, running jobs become interrupted/paused, and
dispatching actions become uncertain. Restore never executes them or reconnects
accounts/browser sessions. Current project links are preserved when possible.

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

Puddle supports scoped [Cua browser control](browser-use.md) in a separate
Chrome or Edge session. Page text and current element refs support reading,
navigation, reviewed clicks, typing and scrolling with the local model.
Live testing found that the current driver's changed-target and sensitive-field
protection is insufficient for public browser writes. These remain development
features behind an open release gate; see the
[live acceptance report](live-browser-os-acceptance-2026-10-30.md).
Native desktop control, arbitrary command execution, continuous voice listening,
cloud inference and cross-device sync are not implemented. Multiple Google and
Outlook accounts can be explicitly switched; only the active provider/account
is used for a mail read or action. Google Meet retains its separate attendance
controls. Guided Splash setup manages only a process launched by Puddle.
Local builds default to ad hoc signing. Developer ID/notarization scripts and
signed-manifest manual updates require owner configuration; see [release setup](releases.md).

See [testing](testing.md) for automated and manual verification.
The [security and guardrail record](security-testing-2026-10-30.md) documents
the source review, corrections, adversarial tests and remaining release gates.
