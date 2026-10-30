# Puddle

Your personal AI assistant, running locally on your Mac.

Explore the [product website and interactive demo](https://linson007.github.io/puddle/).

Puddle opens to **Today**: your priorities, commitments, follow-ups and agenda.
Keep your role and objectives in a local work profile, prepare for meetings,
or open a persistent conversation to think through decisions and plans. Gmail,
Outlook and Google Calendar are optional. You can organize work without an account or
running model; conversations use your local Splash server.

Puddle is a native SwiftUI app using a local Splash inference server, with guided
setup and optional managed launch. Open source under [Apache 2.0](LICENSE), with no third-party package
dependencies.

See the [complete supported features guide](docs/features.md) for capabilities,
controls, storage recovery, and current limits.
The [production roadmap](docs/production-roadmap.md) records the executive
assistant requirements, implementation order, and outstanding release gates.

Choose **Personal** or **Developer**
from the sidebar profile menu. Each has role guidance and relevant conversation
starters. **Manage Profiles** lets you edit work context and guidance, create
custom profiles, or duplicate an existing one. Profiles share your conversations,
memory, tasks, meetings and connections. Switching stops an unfinished reply;
it keeps your current chat. Developer source tools additionally require a
project folder you explicitly connect. The Developer sidebar and menu bar entry
appear only for Developer profiles. Switching away while viewing Developer
returns to Today.

## Build and run

Requirements: macOS 14 or later and Swift 6 command line tools or Xcode. Splash
retains its own Apple silicon and macOS requirements.

    make build
    open build/Puddle.app

Choose **Set Up Local AI** from Today, chat, or Settings for hardware checks,
Splash discovery/installation, model selection, managed start/stop and synthetic
chat/tool verification. Installation and initial model download need internet.
Splash requires a supported Apple silicon Mac and macOS 26.4+; Puddle's local
workspace works on macOS 14+. The compact preset needs at least 24 GB memory.
You can also start your existing server separately, for example:

    cd ../splash
    ./splash serve --model unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M

In Puddle, choose **Connect Splash**, enter its address (default
http://127.0.0.1:8000), and select **Save and Test Connection**. An API key is
needed only if your Splash server requires one. Then start a conversation.

## The assistant

- **Today:** three daily priorities, overdue and due-today work, waiting-on
  counts, cached agenda conflicts, flagged unread mail, and local model setup.
  **Brief me on today** and **End-of-day review** open a conversation with your
  saved work context.
- **Puddle:** general conversation, planning, writing, and relevant tool use.
- **History:** see the current chat immediately; search, reopen, and delete saved conversations.
  Chat opens the latest 200 messages; load earlier messages in batches without losing history.
- **Calendar:** agenda, week and month views, selected secondary calendars,
  working-hour/buffer preferences, candidate slots and focus-time proposals.
  Review event creation/editing and undo with provider revision checks.
- **Mail:** search and filter up to 50 recent inbox messages, read messages,
  summarize, ask Puddle, and review an email as a local task. Compose/reply/forward,
  review exact sends and organization, track follow-ups, snooze locally, maintain
  VIPs, review newsletter unsubscribe, and inspect threads and attachments.
  Reading does not mark mail read. Gmail and Outlook accounts are optional.
- **Developer:** connect a project folder, browse/search numbered source,
  inspect Git status and working/staged text diffs, and keep debugging,
  implementation and review sessions. The local assistant can read this context
  through scoped tools. Project files stay read-only; verification notes are
  user-recorded. [Developer implementation and next steps](docs/developer-assistant-plan.md).
  Search GitHub issues/PRs, Jira work and Confluence documentation, read details
  with source links, and ask the local assistant about them.
  [Connect your work sources](docs/work-connectors.md).
- **Meetings:** open supported join links; automate Google Meet admission in a dedicated Chrome profile (experimental); keep and search notes; import/export transcripts; transcribe microphone and selected-app audio on macOS 26+; extract local summaries, decisions, and action items with source quotes. A floating companion keeps notes/transcription visible; saved capture checkpoints can be recovered after interruption.
- **Memory:** preferences and facts you choose to save, available across
  conversations. Search, inspect, update, or forget them here.
- **Tasks:** track owners, waiting-on follow-ups, priority, notes and daily
  focus; search, filter, edit, complete, delete, reschedule and snooze local work.
  Daily/weekly/monthly commitments create their next occurrence once after completion.
  Chat can propose reviewed creation, completion, renaming and rescheduling.
  With notifications enabled, macOS schedules reminders while Puddle is closed.
  Due reminders also appear in chat, including after the next launch.
- **Connections:** GitHub, Jira/Confluence, optional email/calendar context and local model settings.
- **Actions:** editable proposals and exact-content review, durable dispatch intent,
  provider receipts, and an uncertain state that prevents automatic replay.
- **Work Context:** project goals, linked commitments/meetings, explicit people/VIP
  records and decision owners/options/rationale/evidence/review dates/outcomes.
- **Knowledge:** incremental local search over selected text, PDF and DOCX sources,
  with cited extracted passages and deletion propagation on refresh.
- **Routines:** scheduled read-only briefs/reviews with persisted execution history,
  missed/interrupted-run handling, pause and optional launch at login.
- **Browser:** use Cua Driver to open a separate Chrome or Edge window and let
  your local assistant read pages, navigate, click, type and scroll. Start a
  session explicitly; assistant actions wait for your review in chat. See
  [Cua browser setup](docs/browser-use.md). Errands retain goals/progress across
  turns; Continue inspects fresh state and completion requires observed evidence.
- **Settings → Backups:** export saved work and all profiles, then review a merge into another
  workspace. Current work is preserved; account caches and Keychain secrets
  are excluded. Passphrase encryption is the default; restore never executes
  actions, reconnects browser sessions, or enables imported routines.

Puddle automatically learns useful personal facts, preferences, and ongoing
projects from what you say. Introduce yourself with “My name is…” or say “I
prefer short, practical answers.” No save command or approval dialog is needed.
Learned information appears in **Memory** and carries into new conversations.
You can review its source quote or forget it there. Saying “don’t remember this”
prevents learning from that message. Automatic saves require extracts from your
own words and exclude messages containing recognized credential patterns.
Disable automatic learning in Settings → Assistant at any time.

Learning uses your messages, not assistant replies, email, or calendar content.
Local reminders still show their exact contents for **Allow** or **Decline**
before creation. You can also add memories and tasks directly from the sidebar.

**New Conversation** (⌘N) archives the conversation while retaining saved memory,
tasks, and connections. Replies stream into chat; messages support copying,
reuse as a draft, and retries with durable tool receipts. Settings → Assistant
controls response preferences and notifications. The menu bar item keeps Puddle
available after its window closes.

Use the microphone or Command-Shift-M to dictate on this Mac, then review and
send the draft. **Read aloud** plays a reply using a macOS voice. Settings →
Assistant offers automatic reply playback, voice language, and speed; automatic
playback is off by default. Voice input requires microphone permission and a
supported installed on-device recognition language, with no cloud fallback.
Opt into **System Dictation** in Settings for hold-to-talk ⌘⇧Space, vocabulary
corrections, optional punctuation and insertion into the original accessible
text field. Unsupported/changed targets retain the transcript for manual copy.
⌘K searches saved work and commands; ⌘⇧N captures a commitment and ⌘⇧L opens
the assistant beside the current workspace.

## Optional connections

Choose **Connections → Connect Google** to add Gmail, Calendar, or both.
Google opens in your browser for account selection and consent, then Puddle
loads the services you approved. Use **Manage Google Permissions** to change
access later. Google sign-in is separate from the local model connection.
Multiple Google accounts can be retained in Keychain and explicitly switched;
caches clear on switching. Sending, organization and calendar writing each need
their optional grants and a fresh exact-content review. Outlook uses a separate
Microsoft public-client registration: see [release and connection setup](docs/releases.md).

The app owner provisions one Desktop OAuth client when building Puddle.
`make build` includes a single gitignored `client_secret*.json` from the project
root, or the file selected with `PUDDLE_GOOGLE_CLIENT_FILE`. Puddle imports it
into Keychain on first launch. End users do not create Cloud projects or import
credentials. [Google setup instructions](docs/gmail-setup.md).

The model receives tool descriptions and decides when a tool is relevant. A
general conversation does not automatically load your inbox or calendar.

| Tool | Capability |
| --- | --- |
| Search mail | Read up to 10 messages from the selected Gmail/Outlook provider |
| Read calendar | Read up to 50 primary-calendar events from the start of today within 1–14 days |
| Recall memory | Search locally saved preferences and facts |
| Learn a memory | Automatically save or update a personal fact supported by your message |
| Read tasks | List local tasks and reminders |
| Read daily brief | Saved priorities, overdue/waiting work, cached agenda conflicts and flagged mail, with freshness and scope limits |
| Create/update a reminder | Review a new task or completion, reopening, title or due-date change |
| Prepare email/event | Save a local editable proposal; sending/booking requires separate exact-content review |
| Read work context/documents | Bounded user-maintained project/people/decision context or cited indexed passages |
| Read browser | Read page text and current element refs from an explicitly started Cua browser |
| Use browser | Review navigation, clicks, typing and scrolling in a dedicated browser session |

Connections start with read permissions. Reviewed sends, organization and calendar
writes require optional grants. The model cannot directly dispatch them.
Optional mail polling checks the 50 most recent inbox messages; the
first sync establishes a baseline, and subsequent checks reuse unchanged bodies
through Gmail history. Failed checks back off before retrying.

Disconnecting Google clears its tokens and cached connection data, retaining
your conversation, memory, and tasks. Previously retrieved data can remain in
conversation archives and local backups; see [storage and recovery](docs/features.md#local-storage-and-recovery).

## Demo

    make demo

The demo uses labeled fixture responses, sample connections, and in-memory
state. It accesses neither your Google account nor your real app cache.
Explore general chat, automatically save a memory, create a demo reminder,
and inspect Tasks, Memory, and Connections. Demo replies are not model inference.

## Data and runtime boundaries

Puddle uses Splash’s HTTP API without importing its internals or modifying its
repository. AI requests accept only loopback addresses and reject redirects.
Google calls go directly to its HTTPS APIs.

Tokens, OAuth client configuration, and an optional Splash key use macOS
Keychain without iCloud synchronization. Conversation, memories, tasks,
preferences, and connection cache use AES-GCM encrypted storage under
`~/Library/Application Support/Puddle/`, with owner-only permissions
and a separate workspace key in Keychain. `workspace.vault` and its rolling backup
reference encrypted transcript pages and recovery copies in `transcripts/`.
Keep the complete directory for device-bound recovery; use Settings → Backups
to transfer work. Existing JSON is migrated into encrypted
recovery copies before plaintext originals are removed. Versioned state has atomic saves, a previous-state backup, and recovery that
preserves unreadable files. Failed writes roll back unsaved changes.
Private sessions keep changes only in memory. Optional app lock uses macOS
authentication; retention controls remove selected old conversation archives.
External API pause allows loopback inference and stops managed browser/capture
work. It does not firewall other apps or independently running Splash processes.

External emails and calendar descriptions are untrusted reference data. Email
HTML becomes plain text without loading remote images. The model cannot execute
arbitrary commands or tools outside the implemented tool set.

The current runtime supports conversation, the listed tools, reminder scheduling,
optional Cua browser errands, scoped read-only document/project tools, reviewed
mail/calendar actions, routines and mail polling. Routines run while Puddle or
its menu-bar process is open; after Quit, catch-up happens at the next launch.
General native desktop control, cross-device sync and automatic scheduled meeting
attendance remain outside this implementation. Inference history and
tool results are bounded; archived conversations remain available in History.
Context budgets respect the model's reported capacity and use text token estimates.

## Test

    make test
    make build

Tests cover chat without accounts, tool-call round trips, unavailable tools,
declined actions, incomplete calls, execution limits, memory/state migration,
reminders, OAuth/PKCE, incremental Gmail, paginated Calendar, streamed replies,
storage recovery, failed writes, cancellation, and local inference boundaries. They use
HTTP fixtures, not real accounts or model inference.
[Manual verification](docs/testing.md) covers native UI and live integration.
The [native Cua acceptance report](docs/cua-end-to-end-2026-10-30.md) records the
guided Splash walkthrough, tested feature flows, fixes and remaining checks.
The [six-month load report](docs/load-testing-2026-10-30.md) records tests with
108,000 messages, 5,001 memories, native UI checks and a 1,000-save endurance run.
The [security and guardrail report](docs/security-testing-2026-10-30.md) records
the security fixes, adversarial tests and remaining public-release gates.
The [live browser/OS follow-up](docs/live-browser-os-acceptance-2026-10-30.md)
records additional fixes, macOS unlock, browser acceptance and confirmed
browser-write blockers requiring a release-scope decision.

Build scripts default to an ad hoc signed local app. Release scripts support
Developer ID signing/notarization and a pinned signed update feed, but require
owner credentials, hosting and OAuth verification. General-public
production readiness also requires clean-Mac onboarding and live integration,
hardware, accessibility and supported-model validation; see the roadmap.
See [implementation and verification status](docs/improvement-implementation.md)
for the feature-by-feature record and [release instructions](docs/releases.md).

## Source layout

    Sources/Puddle/          Native app, conversation UI, approvals, workers
    Sources/PuddleCore/      Local agent loop, Splash, memory/tasks, connectors
    Tests/PuddleCoreTests/   Isolated core and integration tests
    app/                    App metadata
    scripts/                Build and icon generation
    docs/                   Connection setup and verification

